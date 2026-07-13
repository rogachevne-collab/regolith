class_name ToolController
extends Node

signal state_changed(
	action: StringName,
	state: ActionState,
	progress: float
)
signal command_requested(command: Dictionary)
signal construction_selection_changed(
	archetype_id: String,
	orientation_index: int
)
signal active_tool_changed(active_tool: StringName)
## Emitted when a toolbar slot is remapped at runtime (BlockPalette drag-drop).
## Presentation state only — the layout override does not touch the const
## TOOLBAR_PAGES nor the way construction commands are issued.
signal toolbar_layout_changed(page: int, slot: int, archetype_id: String)

enum ActionState {
	IDLE,
	PRESSED,
	HOLDING,
	COMPLETED,
	CANCELLED,
}

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var gateway_path: NodePath = NodePath("../../WorldCommandGateway")
@export var preview_path: NodePath = NodePath("../ConstructionPreview")

const ACTIONS := {
	&"tool_primary": {
		"command": &"voxel_remove",
		"max_range": 2.2,
		"interval": 0.05,
		"continuous": true,
	},
	&"tool_secondary": {
		"command": &"construction_apply",
		"max_range": 4.0,
		"interval": 0.22,
		"continuous": true,
	},
	&"tool_weld": {
		"command": &"weld_element",
		"max_range": 4.0,
		"interval": 0.18,
		"continuous": true,
	},
	&"interact": {
		"command": &"toggle_control_seat",
		"max_range": 4.5,
		"interval": 0.0,
		"continuous": false,
	},
}

const CONSTRUCTION_ARCHETYPES: PackedStringArray = [
	"frame",
	"large_frame",
	"frame_beam",
	"frame_basalt",
	"power_source",
	"power_distributor",
	"power_battery",
	"stationary_drill",
	"cargo_store",
	"cargo_pipe",
	"processor",
	"fabricator",
]

const TOOLBAR_SLOTS_PER_PAGE := 9
## Continuous demolition rate when drilling construction blocks (integrity/s).
const DRILL_DPS := 5.0
const DRILL_INTERVAL := 0.05
## Continuous demolition rate for the grinder (integrity units per second).
const GRINDER_DPS := 20.0
const GRINDER_INTERVAL := 0.05
## Material refund when grinder destroys a block (same as dismantle).
const GRINDER_REFUND_FRACTION := 0.5

const TOOLBAR_PAGES: Array = [
	[
		{"type": &"drill"},
		{"type": &"weld"},
		{"type": &"grinder"},
		{"type": &"block", "archetype_id": "frame"},
		{"type": &"block", "archetype_id": "frame_beam"},
		{"type": &"block", "archetype_id": "power_source"},
		{"type": &"block", "archetype_id": "stationary_drill"},
		{"type": &"block", "archetype_id": "cargo_store"},
		{"type": &"connect"},
		{},
	],
	[
		{"type": &"block", "archetype_id": "processor"},
		{"type": &"block", "archetype_id": "fabricator"},
		{"type": &"block", "archetype_id": "cargo_pipe"},
		{"type": &"block", "archetype_id": "power_distributor"},
		{"type": &"block", "archetype_id": "power_battery"},
		{"type": &"block", "archetype_id": "frame_basalt"},
		{"type": &"block", "archetype_id": "large_frame"},
		{"type": &"block", "archetype_id": "frame_beam"},
		{"type": &"block", "archetype_id": "power_source"},
	],
]

var state := ActionState.IDLE
var active_action := StringName()
var progress := 0.0
var selected_archetype_id := "frame"
var selected_orientation_index := 0
var active_tool := &"drill"
var toolbar_page := 0
var toolbar_slot := 0
## Bumped on every runtime remap so presentation widgets can detect that the
## slot layout changed and rebuild.
var toolbar_layout_revision := 0

var _query: InteractionQuery
var _gateway: WorldCommandGateway
var _preview: ConstructionPreview
var _cooldown := 0.0
var _issued_for_press := false
var _locked_hit: InteractionHit
var _construction_mode := &"context"
var _toolbar_slot_by_page: Array[int] = []
## Mutable runtime copy of TOOLBAR_PAGES. Slot remaps write here, never into the
## const layout. Lazily built so the remap API is usable without a full scene
## (e.g. in headless logic tests).
var _toolbar_layout: Array = []
var _connect_pending_element_id := 0
## Freeform cable routing: world-space скобы clicked between the first port
## element and the final one. Sent with connect_network as `waypoints`.
var _connect_waypoints: PackedVector3Array = PackedVector3Array()
var _recipe_cursor_by_element: Dictionary = {}

const CONNECT_RANGE := 4.0
const CONNECT_MAX_WAYPOINTS := 16
## Lift the скоба slightly off the clicked surface so the wire does not z-fight.
const CONNECT_WAYPOINT_SURFACE_OFFSET := 0.06


func _ready() -> void:
	_query = get_node(query_path)
	_gateway = get_node(gateway_path)
	_preview = get_node_or_null(preview_path) as ConstructionPreview
	_ensure_runtime_state()
	command_requested.connect(_gateway.submit)
	_apply_toolbar_slot(toolbar_page, toolbar_slot, false)


func _physics_process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	var player := get_parent()
	if (
		player.has_method("is_gameplay_input_enabled")
		and not player.call("is_gameplay_input_enabled")
	):
		cancel()
		return
	if not (
		player.has_method("is_in_vehicle")
		and player.call("is_in_vehicle")
	):
		_update_toolbar_input()
	if active_tool == &"connect":
		if Input.is_action_just_pressed(&"tool_primary"):
			_handle_connect_click(_query.current_hit)
		if Input.is_action_just_pressed(&"tool_secondary"):
			_undo_connect_waypoint()
		if Input.is_action_just_pressed(&"interact"):
			_try_emit_context_interaction(_query.current_hit)
		return
	var requested_action := _pressed_action()
	if requested_action.is_empty():
		if state == ActionState.PRESSED or state == ActionState.HOLDING:
			_transition(ActionState.CANCELLED)
		else:
			_transition(ActionState.IDLE)
		active_action = StringName()
		progress = 0.0
		_issued_for_press = false
		_locked_hit = null
		_construction_mode = &"context"
		return

	if active_action != requested_action:
		active_action = requested_action
		progress = 0.0
		_cooldown = 0.0
		_issued_for_press = false
		_locked_hit = (
			_build_action_hit()
			if active_tool == &"build" and requested_action == &"tool_primary"
			else null
		)
		if requested_action == &"tool_primary" and active_tool == &"build":
			_construction_mode = &"place"
		_transition(ActionState.PRESSED)

	var profile: Dictionary = ACTIONS[active_action]
	if active_action == &"tool_primary" and active_tool == &"build":
		profile = ACTIONS[&"tool_secondary"].duplicate()
	elif active_action == &"tool_primary" and active_tool == &"grinder":
		profile = profile.duplicate()
		profile["interval"] = GRINDER_INTERVAL
	elif active_action == &"tool_primary" and active_tool == &"drill":
		profile = profile.duplicate()
		profile["interval"] = IndustryArchetypeProfile.hand_drill_interval_s()
	elif active_action == &"tool_primary" and active_tool == &"weld":
		profile = ACTIONS[&"tool_weld"].duplicate()
	var hit := _action_hit(active_action, profile)
	if (
		_locked_hit != null
		and _issued_for_press
		and not _live_target_matches_lock(profile, active_action)
	):
		_transition(ActionState.CANCELLED)
		progress = 0.0
		return
	if not _hit_accepts_action(hit, profile, active_action):
		if _tracks_live_target_while_holding(active_action):
			_transition(ActionState.HOLDING)
			progress = 0.0
			state_changed.emit(active_action, state, progress)
			return
		_transition(ActionState.CANCELLED)
		progress = 0.0
		return
	var continuous := bool(profile["continuous"])
	if active_action == &"tool_primary" and active_tool == &"build":
		continuous = false
	elif (
		active_action == &"tool_secondary"
		and _construction_mode == &"place"
	):
		continuous = false
	if _issued_for_press and not continuous:
		return

	_transition(ActionState.HOLDING)
	var interval: float = profile["interval"]
	progress = (
		1.0
		if interval <= 0.0
		else clampf(1.0 - _cooldown / interval, 0.0, 1.0)
	)
	if _cooldown > 0.0:
		state_changed.emit(active_action, state, progress)
		return

	_emit_command_for_action(active_action, profile, hit)
	_issued_for_press = true
	_transition(ActionState.COMPLETED)
	progress = 1.0
	_cooldown = interval


func cancel() -> void:
	if state != ActionState.IDLE:
		_transition(ActionState.CANCELLED)
	active_action = StringName()
	progress = 0.0
	_cooldown = 0.0
	_issued_for_press = false
	_locked_hit = null
	_construction_mode = &"context"


func toolbar_page_count() -> int:
	return TOOLBAR_PAGES.size()


func toolbar_slot_label(page: int, slot: int) -> String:
	var entry := _toolbar_entry(page, slot)
	if entry.is_empty():
		return "—"
	match StringName(entry.get("type", &"")):
		&"drill":
			return "бур"
		&"weld":
			return "сварка"
		&"grinder":
			return "болгарка"
		&"connect":
			return "соединение"
		&"block":
			return str(entry.get("archetype_id", ""))
		_:
			return "—"


func _emit_command_for_action(
	action: StringName,
	profile: Dictionary,
	hit: InteractionHit
) -> void:
	var command_kind: StringName = profile["command"]
	var parameters := {
		"archetype_id": selected_archetype_id,
		"orientation_index": selected_orientation_index,
		"construction_mode": _construction_mode,
	}
	if action == &"interact" and _try_emit_context_interaction(hit):
		return
	if (
		_construction_mode == &"place"
		and _preview != null
		and _preview.has_resolved_placement()
		and active_tool == &"build"
		and (
			action == &"tool_primary"
			or action == &"tool_secondary"
		)
	):
		parameters["placement_plan"] = _preview.resolved_plan.duplicate(true)
	if action == &"tool_primary":
		if active_tool == &"build":
			command_kind = &"construction_apply"
		elif active_tool == &"weld":
			command_kind = &"weld_element"
			parameters = {}
		elif active_tool == &"grinder":
			if hit.target_kind == InteractionHit.KIND_ELECTRIC_CABLE:
				command_kind = &"disconnect_network"
				parameters = {
					"link_id": int(hit.metadata.get("electric_link_id", 0)),
				}
			else:
				command_kind = &"damage_element"
				parameters = {
					"damage": _grinder_damage_per_tick(),
					"refund_fraction_on_destroy": GRINDER_REFUND_FRACTION,
					"store_id": "player",
				}
		elif hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
			command_kind = &"damage_element"
			parameters = {"damage": _drill_damage_per_tick()}
		else:
			command_kind = &"voxel_remove"
			parameters = {}
	command_requested.emit({
		"kind": command_kind,
		"source": get_parent(),
		"target": (
			_preview.resolved_target.duplicate(true)
			if (
				_construction_mode == &"place"
				and active_tool == &"build"
				and _preview != null
				and _preview.has_resolved_placement()
				and (
					action == &"tool_primary"
					or action == &"tool_secondary"
				)
			)
			else hit.snapshot()
		),
		"parameters": parameters,
	})


func _pressed_action() -> StringName:
	var player := get_parent()
	var in_vehicle: bool = (
		player.has_method("is_in_vehicle")
		and player.call("is_in_vehicle")
	)
	if (
		not in_vehicle
		and Input.is_action_pressed(&"tool_secondary")
	):
		return StringName()
	for action: StringName in ACTIONS:
		if action == &"tool_weld":
			continue
		if action == &"tool_primary":
			if in_vehicle:
				continue
			if (
				active_tool != &"drill"
				and active_tool != &"grinder"
				and active_tool != &"build"
				and active_tool != &"weld"
				and active_tool != &"connect"
			):
				continue
		if (
			action != &"interact"
			and in_vehicle
		):
			continue
		if Input.is_action_pressed(action):
			return action
	return StringName()


func _update_toolbar_input() -> void:
	if Input.is_action_just_pressed(&"toolbar_page_prev"):
		_change_toolbar_page(-1)
	if Input.is_action_just_pressed(&"toolbar_page_next"):
		_change_toolbar_page(1)
	for slot_index: int in range(TOOLBAR_SLOTS_PER_PAGE):
		var action := StringName("toolbar_slot_%d" % [slot_index + 1])
		if Input.is_action_just_pressed(action):
			_apply_toolbar_slot(toolbar_page, slot_index)
	if Input.is_action_just_pressed(&"construction_rotate_yaw"):
		if active_tool == &"build":
			_rotate_orientation(Vector3.UP)
		else:
			_try_enqueue_target_recipe(_query.current_hit)
	if Input.is_action_just_pressed(&"construction_rotate_pitch"):
		if active_tool == &"build":
			_rotate_orientation(Vector3.RIGHT)
	if Input.is_action_just_pressed(&"construction_rotate_roll"):
		if active_tool == &"build":
			_rotate_orientation(Vector3.BACK)


func _change_toolbar_page(delta: int) -> void:
	var page_count := toolbar_page_count()
	if page_count <= 0:
		return
	_toolbar_slot_by_page[toolbar_page] = toolbar_slot
	var next_page := wrapi(toolbar_page + delta, 0, page_count)
	if next_page == toolbar_page:
		return
	toolbar_page = next_page
	var saved_slot: int = _toolbar_slot_by_page[toolbar_page]
	_apply_toolbar_slot_or_first_nonempty(toolbar_page, saved_slot, false)


func _apply_toolbar_slot(
	page: int,
	slot: int,
	emit_tool_change: bool = true
) -> void:
	var entry := _toolbar_entry(page, slot)
	if entry.is_empty():
		return
	toolbar_page = page
	toolbar_slot = slot
	_toolbar_slot_by_page[page] = slot
	var previous_tool := active_tool
	match StringName(entry.get("type", &"")):
		&"drill":
			active_tool = &"drill"
		&"weld":
			active_tool = &"weld"
		&"grinder":
			active_tool = &"grinder"
		&"connect":
			active_tool = &"connect"
			_connect_pending_element_id = 0
			_connect_waypoints = PackedVector3Array()
		&"block":
			active_tool = &"build"
			selected_archetype_id = str(entry.get("archetype_id", "frame"))
			construction_selection_changed.emit(
				selected_archetype_id,
				selected_orientation_index
			)
	if emit_tool_change and previous_tool != active_tool:
		active_tool_changed.emit(active_tool)


func _apply_toolbar_slot_or_first_nonempty(
	page: int,
	preferred_slot: int,
	emit_tool_change: bool = true
) -> void:
	var slot := clampi(preferred_slot, 0, TOOLBAR_SLOTS_PER_PAGE - 1)
	if not _toolbar_entry(page, slot).is_empty():
		_apply_toolbar_slot(page, slot, emit_tool_change)
		return
	for index: int in range(TOOLBAR_SLOTS_PER_PAGE):
		if not _toolbar_entry(page, index).is_empty():
			_apply_toolbar_slot(page, index, emit_tool_change)
			return


func _toolbar_entry(page: int, slot: int) -> Dictionary:
	_ensure_runtime_state()
	if page < 0 or page >= _toolbar_layout.size():
		return {}
	var slots: Array = _toolbar_layout[page]
	if slot < 0 or slot >= slots.size():
		return {}
	var entry: Variant = slots[slot]
	return entry if entry is Dictionary else {}


## Lazily builds the mutable runtime layout (a deep copy of TOOLBAR_PAGES) and
## the per-page selected-slot memory. Safe to call repeatedly; idempotent.
func _ensure_runtime_state() -> void:
	if _toolbar_layout.is_empty():
		for page: Array in TOOLBAR_PAGES:
			var page_copy: Array = []
			for entry: Variant in page:
				page_copy.append(
					(entry as Dictionary).duplicate(true)
					if entry is Dictionary
					else {}
				)
			_toolbar_layout.append(page_copy)
	if _toolbar_slot_by_page.size() != _toolbar_layout.size():
		_toolbar_slot_by_page.resize(_toolbar_layout.size())
		for page_index: int in range(_toolbar_slot_by_page.size()):
			_toolbar_slot_by_page[page_index] = 0


## Latin/archetype id shown by a slot: "drill" / "weld" / archetype_id / "" for
## empty. Reads the runtime layout so presentation reflects live remaps.
func toolbar_slot_archetype_id(page: int, slot: int) -> String:
	var entry := _toolbar_entry(page, slot)
	if entry.is_empty():
		return ""
	match StringName(entry.get("type", &"")):
		&"drill":
			return "drill"
		&"weld":
			return "weld"
		&"grinder":
			return "grinder"
		&"connect":
			return "connect"
		&"block":
			return str(entry.get("archetype_id", ""))
		_:
			return ""


## Whether a slot may be reassigned to a construction archetype. Empty and
## block slots accept a remap; the drill/weld/grinder tool slots stay fixed.
func toolbar_slot_accepts_block(page: int, slot: int) -> bool:
	if page < 0 or slot < 0 or slot >= TOOLBAR_SLOTS_PER_PAGE:
		return false
	var entry := _toolbar_entry(page, slot)
	if entry.is_empty():
		return true
	var slot_type := StringName(entry.get("type", &""))
	return slot_type == &"block"


## Runtime slot remap (BlockPalette drag-drop target). Reassigns page/slot to a
## construction archetype in the mutable layout copy. Refuses to overwrite the
## fixed tool slots and unknown archetypes, so paging and the three tool slots
## stay intact. Emits toolbar_layout_changed and, when the reassigned slot
## is the currently selected one, re-drives selection through the SAME path used
## by keyboard slot selection — the construction command path is unchanged.
func assign_slot_archetype(page: int, slot: int, archetype_id: String) -> bool:
	_ensure_runtime_state()
	if page < 0 or page >= _toolbar_layout.size():
		return false
	var slots: Array = _toolbar_layout[page]
	if slot < 0 or slot >= slots.size():
		return false
	if not CONSTRUCTION_ARCHETYPES.has(archetype_id):
		return false
	if not toolbar_slot_accepts_block(page, slot):
		return false
	slots[slot] = {"type": &"block", "archetype_id": archetype_id}
	toolbar_layout_revision += 1
	toolbar_layout_changed.emit(page, slot, archetype_id)
	if page == toolbar_page and slot == toolbar_slot:
		_apply_toolbar_slot(page, slot, true)
	return true


func _rotate_orientation(local_axis: Vector3) -> void:
	if active_tool != &"build":
		return
	var current := OrientationUtil.orientation_basis(selected_orientation_index)
	var rotated := current * Basis(local_axis.normalized(), PI * 0.5)
	selected_orientation_index = _basis_orientation_index(rotated)
	construction_selection_changed.emit(
		selected_archetype_id,
		selected_orientation_index
	)


func _basis_orientation_index(basis: Basis) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.orientation_basis(index).is_equal_approx(basis):
			return index
	return selected_orientation_index


func _action_hit(action: StringName, profile: Dictionary) -> InteractionHit:
	if _tracks_live_target_while_holding(action):
		return _query.current_hit
	if _locked_hit != null:
		return _locked_hit
	return _target_for_action(action)


func _tracks_live_target_while_holding(action: StringName) -> bool:
	return (
		action == &"tool_primary"
		and (
			active_tool == &"drill"
			or active_tool == &"grinder"
			or active_tool == &"weld"
		)
	)


func _hit_accepts_action(
	hit: InteractionHit,
	profile: Dictionary,
	action: StringName
) -> bool:
	if not hit.valid or hit.distance > float(profile["max_range"]):
		return false
	if action == &"tool_primary" and active_tool == &"build":
		return _can_place_block()
	if action == &"tool_primary" and active_tool == &"weld":
		_construction_mode = _resolve_welder_mode(hit)
		return (
			hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
			and _construction_mode != &"none"
		)
	if action == &"tool_primary" and active_tool == &"grinder":
		return (
			hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
			or hit.target_kind == InteractionHit.KIND_ELECTRIC_CABLE
		)
	if action == &"tool_primary" and active_tool == &"drill":
		return (
			hit.target_kind == InteractionHit.KIND_VOXEL
			or hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
		)
	return true


func _resolve_welder_mode(hit: InteractionHit) -> StringName:
	if hit == null or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		return &"none"
	if StringName(hit.metadata.get("status_reason", &"element_incomplete")) == &"ok":
		return &"none"
	return &"weld"


func _build_action_hit() -> InteractionHit:
	if _preview != null and _preview.has_resolved_placement():
		return _resolved_placement_hit()
	return _query.current_hit


func _can_place_block() -> bool:
	if _preview != null and _preview.has_resolved_placement():
		return true
	return _query.current_hit.valid


func _resolved_placement_hit() -> InteractionHit:
	if _preview != null and _preview.has_resolved_placement():
		return _preview.resolved_hit()
	return _query.current_hit


func _live_target_matches_lock(
	profile: Dictionary,
	action: StringName
) -> bool:
	if active_tool == &"build" and _construction_mode == &"place":
		return true
	var live := _query.current_hit
	return (
		live.valid
		and live.distance <= float(profile["max_range"])
		and live.target_kind == _locked_hit.target_kind
		and live.target_id == _locked_hit.target_id
	)


func _drill_damage_per_tick() -> float:
	return DRILL_DPS * DRILL_INTERVAL


func _grinder_damage_per_tick() -> float:
	return GRINDER_DPS * GRINDER_INTERVAL


## Connect tool click: first click on an element with electric ports starts a
## cable; further clicks on surfaces (terrain, blocks without electric ports)
## drop routing скобы; a click on another electric-port element completes the
## link with the routed polyline. RMB undoes the last скоба / cancels.
func _handle_connect_click(hit: InteractionHit) -> void:
	if hit == null or not hit.valid or hit.distance > CONNECT_RANGE:
		return
	if hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
		var element_id := int(hit.metadata.get("element_id", 0))
		if element_id <= 0:
			return
		if _connect_pending_element_id <= 0:
			if _target_has_electric_port(hit):
				_connect_pending_element_id = element_id
				_connect_waypoints = PackedVector3Array()
			return
		if element_id == _connect_pending_element_id:
			return
		if not _target_has_electric_port(hit):
			_append_connect_waypoint(hit)
			return
		command_requested.emit({
			"kind": &"connect_network",
			"source": get_parent(),
			"target": hit.snapshot(),
			"parameters": {
				"element_a_id": _connect_pending_element_id,
				"element_b_id": element_id,
				"waypoints": _connect_waypoints.duplicate(),
			},
		})
		_connect_pending_element_id = 0
		_connect_waypoints = PackedVector3Array()
		return
	if (
		_connect_pending_element_id > 0
		and hit.target_kind == InteractionHit.KIND_VOXEL
	):
		_append_connect_waypoint(hit)


func _append_connect_waypoint(hit: InteractionHit) -> void:
	if _connect_waypoints.size() >= CONNECT_MAX_WAYPOINTS:
		return
	_connect_waypoints.append(
		hit.point + hit.normal * CONNECT_WAYPOINT_SURFACE_OFFSET
	)


func _undo_connect_waypoint() -> void:
	if not _connect_waypoints.is_empty():
		_connect_waypoints.remove_at(_connect_waypoints.size() - 1)
		return
	_connect_pending_element_id = 0


func _target_has_electric_port(hit: InteractionHit) -> bool:
	if _gateway == null:
		return false
	var session := _gateway.get_node_or_null(
		_gateway.simulation_session_path
	) as SimulationSession
	if session == null:
		return false
	var element := session.world.get_element(
		int(hit.metadata.get("element_id", 0))
	)
	if element == null:
		return false
	var archetype := element.get_archetype()
	if archetype == null:
		return false
	for port: PortDefinition in archetype.ports:
		if port.kind == PortDefinition.Kind.ELECTRIC:
			return true
	return false


func connect_pending_element_id() -> int:
	return _connect_pending_element_id


func connect_waypoints() -> PackedVector3Array:
	return _connect_waypoints.duplicate()


func connect_waypoint_count() -> int:
	return _connect_waypoints.size()


func next_recipe_for_target(hit: InteractionHit) -> String:
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return ""
	var archetype_id := str(hit.metadata.get("archetype_id", ""))
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return ""
	var element_id := int(hit.metadata.get("element_id", 0))
	var cursor := int(_recipe_cursor_by_element.get(element_id, 0))
	return recipe_ids[wrapi(cursor, 0, recipe_ids.size())]


func _try_emit_context_interaction(hit: InteractionHit) -> bool:
	if _try_collect_world_loot(hit):
		return true
	if _try_toggle_target_machine(hit):
		return true
	return _try_emit_industry_transfer(hit)


func _try_collect_world_loot(hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_WORLD_LOOT
		or hit.distance > 4.0
	):
		return false
	var pile_id := int(hit.metadata.get("loot_pile_id", 0))
	if pile_id <= 0:
		return false
	command_requested.emit({
		"kind": &"collect_world_loot",
		"source": get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"pile_id": pile_id,
			"to_store_id": IndustryStoreService.PLAYER_STORE_ID,
		},
	})
	return true


func _try_toggle_target_machine(hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
		or hit.distance > 4.0
	):
		return false
	var archetype_id := str(hit.metadata.get("archetype_id", ""))
	if archetype_id not in ["stationary_drill", "processor", "fabricator"]:
		return false
	command_requested.emit({
		"kind": &"set_machine_enabled",
		"source": get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"element_id": int(hit.metadata.get("element_id", 0)),
			"enabled": not bool(hit.metadata.get("machine_enabled", true)),
		},
	})
	return true


func _try_enqueue_target_recipe(hit: InteractionHit) -> bool:
	var recipe_id := next_recipe_for_target(hit)
	if recipe_id.is_empty() or hit.distance > 4.0:
		return false
	var element_id := int(hit.metadata.get("element_id", 0))
	command_requested.emit({
		"kind": &"enqueue_recipe",
		"source": get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"element_id": element_id,
			"recipe_id": recipe_id,
		},
	})
	var count := RecipeCatalog.recipe_ids_for_machine(
		str(hit.metadata.get("archetype_id", ""))
	).size()
	_recipe_cursor_by_element[element_id] = wrapi(
		int(_recipe_cursor_by_element.get(element_id, 0)) + 1,
		0,
		count
	)
	return true


func _try_emit_industry_transfer(hit: InteractionHit) -> bool:
	if _gateway == null:
		return false
	if (
		not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
		or hit.distance > 4.0
	):
		return false
	var session := _gateway.get_node_or_null(
		_gateway.simulation_session_path
	) as SimulationSession
	if session == null:
		return false
	var element := session.world.get_element(int(hit.metadata.get("element_id", 0)))
	if not IndustryTransferUtil.is_transfer_target(element):
		return false
	var parameters := IndustryTransferUtil.pickup_parameters(session.world, element)
	if parameters.is_empty():
		parameters = IndustryTransferUtil.deposit_parameters(session.world, element)
	if parameters.is_empty():
		return false
	command_requested.emit({
		"kind": &"transfer_resource",
		"source": get_parent(),
		"target": hit.snapshot(),
		"parameters": parameters,
	})
	return true


func _target_for_action(action: StringName) -> InteractionHit:
	var player := get_parent()
	if (
		action == &"interact"
		and player.has_method("is_in_vehicle")
		and player.call("is_in_vehicle")
	):
		var vehicle: Node3D = player.call("current_vehicle")
		if vehicle != null:
			return InteractionHit.create(
				vehicle.global_position,
				Vector3.UP,
				0.0,
				InteractionHit.KIND_CONTROL_SEAT,
				vehicle,
				StringName(str(vehicle.get_instance_id()))
			)
	return _query.current_hit


func _transition(next_state: ActionState) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(active_action, state, progress)
