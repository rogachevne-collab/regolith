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
## Presentation-only rejection of a connect-tool click (скоба сквозь стену,
## финальный пролёт перекрыт) — HUD shows the toast, no command is issued.
signal connect_rejected(reason: StringName)
## Emitted when a toolbar slot is remapped at runtime (BlockPalette drag-drop).
## Presentation state only — the layout override does not touch the const
## TOOLBAR_PAGES nor the way construction commands are issued.
signal toolbar_layout_changed(page: int, slot: int, archetype_id: String)
## How much the hand scoop is carrying, for a readout.
signal scoop_load_changed(load_m3: float, capacity_m3: float)

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
@export var terminal_path: NodePath = NodePath("../HUDRoot/Screen/Terminal")
@export var actuator_panel_path: NodePath = NodePath("../HUDRoot/Screen/ActuatorPanel")
@export var wheel_panel_path: NodePath = NodePath("../HUDRoot/Screen/WheelPanel")
@export var control_terminal_path: NodePath = NodePath(
	"../HUDRoot/Screen/ControlTerminal"
)

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

## Built-in parts. Wizard-baked parts are discovered automatically — use
## construction_archetype_ids(), not this constant, for "what can I build".
const CONSTRUCTION_ARCHETYPES: PackedStringArray = [
	"frame",
	"large_frame",
	"frame_beam",
	"frame_basalt",
	"power_source",
	"power_distributor",
	"power_battery",
	"stationary_drill",
	"dozer_blade",
	"cargo_store",
	"cargo_pipe",
	"processor",
	"fabricator",
	"piston_base",
	"piston_base_large",
	"rotor_base",
	"rotor_base_large",
	"hinge_base",
	"rover_frame",
	"wheel_suspension",
	"drive_wheel",
	"suspension_small",
	"wheel_med",
	"cockpit",
	"power_battery_small",
	"power_distributor_small",
	"thruster",
	"gyro",
	"landing_leg",
]

static var _construction_ids_cache: PackedStringArray = PackedStringArray()


## Everything the player can build: the built-in list plus every part baked
## by the Part Wizard (resources/archetypes/authored/). Cached per run.
static func construction_archetype_ids() -> PackedStringArray:
	if not _construction_ids_cache.is_empty():
		return _construction_ids_cache
	var ids := CONSTRUCTION_ARCHETYPES.duplicate()
	for authored_id: String in Slice01Archetypes.authored_ids():
		if not ids.has(authored_id):
			ids.append(authored_id)
	_construction_ids_cache = ids
	return _construction_ids_cache

const TOOLBAR_SLOTS_PER_PAGE := 9
## Continuous demolition rate when drilling construction blocks (integrity/s).
## Authoritative values: Game Balance `construction.block_drill_*`.
static var DRILL_DPS: float:
	get:
		return GameBalance.construction_float("block_drill_dps", 5.0)
static var DRILL_INTERVAL: float:
	get:
		return GameBalance.construction_float("block_drill_interval_s", 0.05)
## Continuous demolition rate for the grinder (integrity units per second).
static var GRINDER_DPS: float:
	get:
		return GameBalance.construction_float("grinder_dps", 200.0)
static var GRINDER_INTERVAL: float:
	get:
		return GameBalance.construction_float("grinder_interval_s", 0.05)
## Material refund when grinder destroys a block (same as dismantle).
static var GRINDER_REFUND_FRACTION: float:
	get:
		return GameBalance.construction_float("grinder_refund_fraction", 0.5)

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
		{"type": &"block", "archetype_id": "piston_base"},
	],
	[
		{"type": &"block", "archetype_id": "processor"},
		{"type": &"block", "archetype_id": "fabricator"},
		{"type": &"block", "archetype_id": "cargo_pipe"},
		{"type": &"block", "archetype_id": "power_distributor"},
		{"type": &"block", "archetype_id": "power_battery"},
		{"type": &"block", "archetype_id": "frame_basalt"},
		{"type": &"block", "archetype_id": "large_frame"},
		{"type": &"block", "archetype_id": "dozer_blade"},
		{"type": &"scoop"},
	],
	[
		{"type": &"block", "archetype_id": "rover_frame"},
		{"type": &"block", "archetype_id": "wheel_suspension"},
		{"type": &"block", "archetype_id": "drive_wheel"},
		{"type": &"block", "archetype_id": "cockpit"},
		{"type": &"block", "archetype_id": "power_battery_small"},
		{"type": &"block", "archetype_id": "power_distributor_small"},
		{"type": &"block", "archetype_id": "rotor_base"},
		{"type": &"block", "archetype_id": "rotor_base_large"},
		{"type": &"block", "archetype_id": "hinge_base"},
		{"type": &"block", "archetype_id": "piston_base_large"},
	],
	[
		{"type": &"block", "archetype_id": "thruster"},
		{"type": &"block", "archetype_id": "gyro"},
		{"type": &"block", "archetype_id": "landing_leg"},
		{"type": &"block", "archetype_id": "cockpit"},
		{"type": &"block", "archetype_id": "rover_frame"},
		{"type": &"block", "archetype_id": "power_battery_small"},
		{"type": &"block", "archetype_id": "power_distributor_small"},
		{"type": &"block", "archetype_id": "frame"},
		{"type": &"connect"},
	],
	[
		{"type": &"block", "archetype_id": "rover_frame"},
		{"type": &"block", "archetype_id": "suspension_small"},
		{"type": &"block", "archetype_id": "wheel_med"},
		{"type": &"block", "archetype_id": "cockpit"},
		{"type": &"block", "archetype_id": "power_battery_small"},
		{"type": &"block", "archetype_id": "power_distributor_small"},
		{"type": &"connect"},
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
var _terminal: Node
var _actuator_panel: Node
var _wheel_panel: Node
var _control_terminal: Node
var _cooldown := 0.0
var _issued_for_press := false
var _locked_hit: InteractionHit
var _construction_mode := &"context"
var _toolbar_slot_by_page: Array[int] = []
## Mutable runtime copy of TOOLBAR_PAGES. Slot remaps write here, never into the
## const layout. Lazily built so the remap API is usable without a full scene
## (e.g. in headless logic tests).
var _toolbar_layout: Array = []
## Rope being pulled: the first click's end. `_rope_anchor_local` lives in the
## frame of `_rope_anchor_element_id` (block-local), or in world space when the
## end is nailed to terrain — so the rope stays tied to a machine that moves
## while the player walks the other end away.
var _rope_pending := false
var _rope_anchor_element_id := 0
var _rope_anchor_local := Vector3.ZERO
## Wheel knob: 0 внатяг … 1 болтается. Kept between ropes, like a tool setting.
var _rope_slack := CableAnchorUtil.DEFAULT_SLACK
var _recipe_cursor_by_element: Dictionary = {}
var _inventory_revision := -1
var _last_drill_excavation_msec := -1
## When true, +/- / Y apply the same command to every piston in the assembly.
var actuator_chain_sync := false

## Hand scoop. A bucket's worth, not a truck's: small enough that carrying spoil
## by hand stays a way to check how the material behaves rather than a way to
## move a heap.
const SCOOP_CAPACITY_M3 := 0.15
const SCOOP_RADIUS_M := 0.5
const SCOOP_REACH_M := 2.6
## Slower than the drill's 0.05 s. Collecting has to cost more than cutting, or
## clearing your own spoil becomes the cheapest way to mine.
const SCOOP_INTERVAL_S := 0.35
## What the scoop is carrying, in cubic metres. Lives on the tool because the
## player is the carrier; the world has no record of it once it is scooped, so
## losing this number loses the material.
var scoop_load_m3 := 0.0

## Debug spoil hose (O). Loose material only exists where something dug or
## dumped, so testing anything that works it — the dozer blade, the scoop, the
## angle of repose — starts with standing around drilling a heap. Hold O to pour
## one at the crosshair instead. A dose per tick large enough to build a
## blade-height pile in a few seconds, not so large that a tap buries the player.
const DEBUG_SPOIL_VOLUME_M3 := 0.25
const DEBUG_SPOIL_INTERVAL_S := 0.1
var _debug_spoil_cooldown := 0.0

## Tying the first end is hand work — you have to reach what you tie to.
const CONNECT_RANGE := 4.0
## The far end is thrown, not placed by hand: that is what makes it possible to
## anchor a moving machine to the ground you are driving past. Walking a rope
## out still works and is the way to get anything longer than this.
const CONNECT_THROW_RANGE := 18.0
## Lift the rope end slightly off the clicked surface so it does not z-fight.
const CONNECT_SURFACE_OFFSET := 0.06


func _ready() -> void:
	_query = get_node(query_path)
	_gateway = get_node(gateway_path)
	_preview = get_node_or_null(preview_path) as ConstructionPreview
	_terminal = get_node_or_null(terminal_path)
	_actuator_panel = get_node_or_null(actuator_panel_path)
	_wheel_panel = get_node_or_null(wheel_panel_path)
	_control_terminal = get_node_or_null(control_terminal_path)
	_ensure_runtime_state()
	command_requested.connect(_gateway.submit)
	_gateway.command_completed.connect(_on_gateway_command_completed)
	_apply_toolbar_slot(toolbar_page, toolbar_slot, false)


func _physics_process(delta: float) -> void:
	_sync_inventory_toolbar_if_needed()
	_cooldown = maxf(_cooldown - delta, 0.0)
	if _ui_modal_blocks_world_interact():
		if Input.is_action_just_pressed(&"interact"):
			if _actuator_panel_is_open():
				if _actuator_panel.has_method("close_for_interact"):
					_actuator_panel.call("close_for_interact")
				else:
					_actuator_panel.call("close")
			elif _wheel_panel_is_open():
				if _wheel_panel.has_method("close_for_interact"):
					_wheel_panel.call("close_for_interact")
				else:
					_wheel_panel.call("close")
			elif _terminal_is_open():
				if _terminal.has_method("close_for_interact"):
					_terminal.call("close_for_interact")
				else:
					_terminal.call("close")
			elif _control_terminal_is_open():
				if _control_terminal.has_method("close_for_interact"):
					_control_terminal.call("close_for_interact")
				else:
					_control_terminal.call("close")
		return
	if _query == null:
		return
	var player := get_parent()
	var in_vehicle: bool = (
		player.has_method("is_in_vehicle")
		and player.call("is_in_vehicle")
	)
	if (
		not in_vehicle
		and player.has_method("is_gameplay_input_enabled")
		and not player.call("is_gameplay_input_enabled")
	):
		cancel()
		return
	if not in_vehicle:
		_update_toolbar_input()
	_update_debug_spoil_input(delta)
	if active_tool == &"connect":
		if Input.is_action_just_pressed(&"tool_primary"):
			_handle_connect_click(_query.current_hit)
		if Input.is_action_just_pressed(&"tool_secondary"):
			_cancel_rope_routing()
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
		# Place must use the same reach as InteractionQuery.build_max_distance
		# (preview aim); tool_secondary's 4m was rejecting valid ghosts past that.
		profile = ACTIONS[&"tool_secondary"].duplicate()
		if _query != null:
			profile["max_range"] = _query.build_max_distance
	elif active_action == &"tool_primary" and active_tool == &"grinder":
		profile = profile.duplicate()
		profile["interval"] = GRINDER_INTERVAL
	elif active_action == &"tool_primary" and active_tool == &"drill":
		profile = profile.duplicate()
		profile["interval"] = IndustryArchetypeProfile.hand_drill_interval_s()
		profile["max_range"] = IndustryArchetypeProfile.hand_drill_reach_m()
	elif active_action == &"tool_secondary" and active_tool == &"drill":
		# Excavation mode: reuse the drill's reach, carve on a faster cadence,
		# and stay continuous while the button is held.
		profile = profile.duplicate()
		profile["command"] = &"voxel_remove"
		profile["interval"] = IndustryArchetypeProfile.hand_drill_extract_interval_s()
		profile["max_range"] = IndustryArchetypeProfile.hand_drill_reach_m()
		profile["continuous"] = true
	elif active_action == &"tool_primary" and active_tool == &"weld":
		profile = ACTIONS[&"tool_weld"].duplicate()
	elif active_tool == &"scoop" and (
		active_action == &"tool_primary"
		or active_action == &"tool_secondary"
	):
		profile = profile.duplicate()
		profile["interval"] = SCOOP_INTERVAL_S
		profile["max_range"] = SCOOP_REACH_M
		profile["continuous"] = true
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
	if not _active_tool_is_equipped():
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


func is_drill_excavating() -> bool:
	if _last_drill_excavation_msec < 0:
		return false
	return (
		Time.get_ticks_msec() - _last_drill_excavation_msec
		<= int(IndustryArchetypeProfile.hand_drill_interval_s() * 2000.0)
	)


func _on_gateway_command_completed(
	_command_id: int,
	result: Dictionary
) -> void:
	# A gateway result is `{status, reason, data, command_kind}` — everything a
	# command reports back lives under `data`, never at the top level.
	var data: Dictionary = result.get("data", {})
	match StringName(result.get("command_kind", &"")):
		&"voxel_remove":
			if float(data.get("removed_volume_m3", 0.0)) <= 0.000001:
				return
			_last_drill_excavation_msec = Time.get_ticks_msec()
		&"scoop_spoil":
			# Only what the world reports as taken. Assuming a full scoop would
			# conjure material the field never gave up.
			scoop_load_m3 = clampf(
				scoop_load_m3 + float(data.get("scooped_volume_m3", 0.0)),
				0.0,
				SCOOP_CAPACITY_M3
			)
			scoop_load_changed.emit(scoop_load_m3, SCOOP_CAPACITY_M3)
		&"dump_scoop":
			# Only what the world accepted. A region too full to take the whole
			# load leaves the rest in the scoop, where it still exists.
			scoop_load_m3 = maxf(
				scoop_load_m3 - float(data.get("dumped_volume_m3", 0.0)),
				0.0
			)
			scoop_load_changed.emit(scoop_load_m3, SCOOP_CAPACITY_M3)


func toolbar_page_count() -> int:
	return TOOLBAR_PAGES.size()


func toolbar_slot_label(page: int, slot: int) -> String:
	var entry := _toolbar_entry(page, slot)
	return PlayerHotbarBridge.slot_label(entry, _player_inventory())


func _player_inventory() -> PlayerInventoryRegistry:
	if _gateway == null:
		return null
	return _gateway.player_inventory()


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
	if action == &"interact":
		if _try_emit_context_interaction(hit):
			return
		# Cargo/machines use the terminal, not toggle_control_seat.
		if _is_terminal_target_hit(hit):
			return
	# Ahead of the build-preview block: the scoop has nothing to do with
	# placement, and must not pick up a `placement_plan` on its way out.
	if active_tool == &"scoop" and (
		action == &"tool_primary" or action == &"tool_secondary"
	):
		if action == &"tool_primary":
			command_kind = &"scoop_spoil"
			parameters = {
				"radius": SCOOP_RADIUS_M,
				"max_volume_m3": SCOOP_CAPACITY_M3 - scoop_load_m3,
			}
		else:
			command_kind = &"dump_scoop"
			parameters = {"volume_m3": scoop_load_m3}
		command_requested.emit({
			"kind": command_kind,
			"source": get_parent(),
			"target": hit.snapshot(),
			"parameters": parameters,
		})
		return
	# Drill excavation mode (ПКМ): carve rock like voxel_remove but discard the
	# yield — nothing is credited to the player, this only clears material.
	if active_tool == &"drill" and action == &"tool_secondary":
		var extract_parameters := {"discard_yield": true}
		var extract_radius := (
			IndustryArchetypeProfile.hand_drill_extract_carve_radius_m()
		)
		if extract_radius > 0.0:
			extract_parameters["radius"] = extract_radius
		command_requested.emit({
			"kind": &"voxel_remove",
			"source": get_parent(),
			"target": hit.snapshot(),
			"parameters": extract_parameters,
		})
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
					"refund_to_actor": true,
				}
		elif hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
			command_kind = &"damage_element"
			parameters = {"damage": _drill_damage_per_tick()}
		elif hit.target_kind == InteractionHit.KIND_TERRAIN_DEBRIS:
			command_kind = &"dig_terrain_debris"
			parameters = {}
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
		# The scoop tips its load out and the drill carves in excavation mode;
		# both do something of their own on the right button. Everything else
		# treats a held right button as "no action", and for the scoop that
		# would leave a full load with no way to empty.
		and active_tool != &"scoop"
		and active_tool != &"drill"
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
				and active_tool != &"scoop"
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


## Hold O to pour loose material at the crosshair. Bypasses the action state
## machine on purpose: it is a world fixture, not a tool, and holding it must not
## cancel or interleave with whatever the player has equipped.
func _update_debug_spoil_input(delta: float) -> void:
	if not Input.is_action_pressed(&"debug_spawn_spoil"):
		_debug_spoil_cooldown = 0.0
		return
	_debug_spoil_cooldown = maxf(_debug_spoil_cooldown - delta, 0.0)
	if _debug_spoil_cooldown > 0.0:
		return
	_debug_spoil_cooldown = DEBUG_SPOIL_INTERVAL_S
	var hit: InteractionHit = _query.current_hit
	if hit == null or not hit.valid:
		return
	command_requested.emit({
		"kind": &"debug_spawn_spoil",
		"source": get_parent(),
		"target": hit.snapshot(),
		"parameters": {"volume_m3": DEBUG_SPOIL_VOLUME_M3},
	})


func _update_toolbar_input() -> void:
	if _query == null:
		return
	if Input.is_action_just_pressed(&"toolbar_page_prev"):
		_change_toolbar_page(-1)
	if Input.is_action_just_pressed(&"toolbar_page_next"):
		_change_toolbar_page(1)
	for slot_index: int in range(TOOLBAR_SLOTS_PER_PAGE):
		var action := StringName("toolbar_slot_%d" % [slot_index + 1])
		if Input.is_action_just_pressed(action):
			_apply_toolbar_slot(toolbar_page, slot_index)
	var hit := _query.current_hit
	var terminal_target := _is_terminal_target_hit(hit)
	if not terminal_target:
		if Input.is_action_just_pressed(&"capture_mouse"):
			_try_enqueue_target_recipe(hit)
	if Input.is_action_just_pressed(&"construction_rotate_yaw"):
		if not terminal_target and _cycle_target_recipe(hit, 1):
			pass
		elif active_tool == &"build":
			_rotate_orientation(Vector3.UP)
	if Input.is_action_just_pressed(&"construction_rotate_pitch"):
		if not terminal_target and _cycle_target_recipe(hit, -1):
			pass
		elif active_tool == &"build":
			_rotate_orientation(Vector3.RIGHT)
	if Input.is_action_just_pressed(&"construction_rotate_roll"):
		if active_tool == &"build":
			_rotate_orientation(Vector3.BACK)
	if Input.is_action_just_pressed(&"actuator_extend"):
		_try_actuator_extend(hit)
	elif Input.is_action_just_pressed(&"actuator_retract"):
		_try_actuator_retract(hit)
	elif Input.is_action_just_pressed(&"actuator_stop"):
		_try_actuator_stop(hit)


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
	var resolved := PlayerHotbarBridge.resolve_slot_entry(
		_player_inventory(),
		entry
	)
	if resolved.is_empty():
		return
	var previous_tool := active_tool
	# Picking any slot — another tool or another build block — drops the rope
	# currently being pulled. Built ropes are untouched.
	_reset_connect_route()
	match StringName(resolved.get("kind", &"")):
		&"tool_instance":
			active_tool = StringName(resolved.get("active_tool", &""))
		&"block":
			active_tool = &"build"
			var next_archetype_id := str(resolved.get("archetype_id", "frame"))
			if next_archetype_id != selected_archetype_id:
				selected_orientation_index = _default_orientation_for(
					next_archetype_id
				)
			selected_archetype_id = next_archetype_id
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


func _canonical_toolbar_entry(page: int, slot: int) -> Dictionary:
	if page < 0 or page >= TOOLBAR_PAGES.size():
		return {}
	var slots: Array = TOOLBAR_PAGES[page]
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
		_sync_toolbar_from_inventory()
	if _toolbar_slot_by_page.size() != _toolbar_layout.size():
		_toolbar_slot_by_page.resize(_toolbar_layout.size())
		for page_index: int in range(_toolbar_slot_by_page.size()):
			_toolbar_slot_by_page[page_index] = 0


## Latin/archetype id shown by a slot: "drill" / "weld" / archetype_id / "" for
## empty. Reads the runtime layout so presentation reflects live remaps.
func toolbar_slot_archetype_id(page: int, slot: int) -> String:
	var entry := _toolbar_entry(page, slot)
	return PlayerHotbarBridge.slot_archetype_id(entry, _player_inventory())


## Whether a slot may be reassigned to a construction archetype. Empty and
## block slots accept a remap; the drill/weld/grinder tool slots stay fixed.
func toolbar_slot_accepts_block(page: int, slot: int) -> bool:
	if page < 0 or slot < 0 or slot >= TOOLBAR_SLOTS_PER_PAGE:
		return false
	var canonical := _canonical_toolbar_entry(page, slot)
	if canonical.is_empty():
		return true
	return StringName(canonical.get("type", &"")) == &"block"


## Fixed tool slots accept only an instance of their original tool type. This
## retains the existing toolbar roles while binding each slot to an owned item.
func toolbar_slot_accepts_tool_instance(
	page: int,
	slot: int,
	instance_id: String
) -> bool:
	var registry := _player_inventory()
	if registry == null or not registry.has_instance(instance_id):
		return false
	var canonical := _canonical_toolbar_entry(page, slot)
	var expected_type := StringName(canonical.get("type", &""))
	if not PlayerHotbarBridge.LEGACY_TOOL_TYPES.has(expected_type):
		return false
	return (
		PlayerHotbarBridge.active_tool_for_instance(registry, instance_id)
		== expected_type
	)


## Binds an owned tool instance to its matching fixed toolbar slot. The
## authoritative registry clears any prior binding for this instance first.
func assign_slot_tool_instance(
	page: int,
	slot: int,
	instance_id: String
) -> bool:
	if (
		_gateway == null
		or not toolbar_slot_accepts_tool_instance(page, slot, instance_id)
		or not _gateway.assign_player_hotbar_instance(page, slot, instance_id)
	):
		return false
	_inventory_revision = _gateway.player_inventory_revision()
	_sync_toolbar_from_inventory()
	toolbar_layout_revision += 1
	if page == toolbar_page and slot == toolbar_slot:
		_apply_toolbar_slot(page, slot, true)
	return true


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
	if not construction_archetype_ids().has(archetype_id):
		return false
	if not toolbar_slot_accepts_block(page, slot):
		return false
	slots[slot] = {"type": &"block", "archetype_id": archetype_id}
	toolbar_layout_revision += 1
	toolbar_layout_changed.emit(page, slot, archetype_id)
	if page == toolbar_page and slot == toolbar_slot:
		_apply_toolbar_slot(page, slot, true)
	return true


func _default_orientation_for(archetype_id: String) -> int:
	if _gateway == null:
		return 0
	var archetype := _gateway.construction_archetype(archetype_id)
	if archetype == null:
		return 0
	return clampi(
		archetype.default_orientation_index,
		0,
		OrientationUtil.ORIENTATION_COUNT - 1
	)


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


func _action_hit(action: StringName, _profile: Dictionary) -> InteractionHit:
	if _tracks_live_target_while_holding(action):
		return _query.current_hit
	if _locked_hit != null:
		return _locked_hit
	return _target_for_action(action)


func _tracks_live_target_while_holding(action: StringName) -> bool:
	# Excavation (drill ПКМ) sweeps through rock, so it tracks live aim too.
	if action == &"tool_secondary" and active_tool == &"drill":
		return true
	return (
		action == &"tool_primary"
		and (
			active_tool == &"drill"
			or active_tool == &"grinder"
			or active_tool == &"weld"
			# Scooping is a sweep through a heap, so it follows the aim rather
			# than the spot the button was pressed on.
			or active_tool == &"scoop"
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
	if active_tool == &"scoop":
		# Scooping needs loose material under the aim; tipping out only needs
		# somewhere to put it, and any solid surface will do.
		if action == &"tool_primary":
			return (
				scoop_load_m3 < SCOOP_CAPACITY_M3 - 0.000001
				and hit.target_kind == InteractionHit.KIND_GRANULAR
			)
		if action == &"tool_secondary":
			return scoop_load_m3 > 0.000001
	if action == &"tool_primary" and active_tool == &"drill":
		return (
			hit.target_kind == InteractionHit.KIND_VOXEL
			or hit.target_kind == InteractionHit.KIND_GRANULAR
			or hit.target_kind == InteractionHit.KIND_TERRAIN_DEBRIS
			or hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
		)
	if action == &"tool_secondary" and active_tool == &"drill":
		# Excavation only carves terrain — solid rock or its own loose spoil.
		# It never damages built elements; that stays a болгарка/бур primary job.
		return (
			hit.target_kind == InteractionHit.KIND_VOXEL
			or hit.target_kind == InteractionHit.KIND_GRANULAR
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
	return _preview != null and _preview.has_resolved_placement()


func _resolved_placement_hit() -> InteractionHit:
	if _preview != null and _preview.has_resolved_placement():
		return _preview.resolved_hit()
	return _query.current_hit


func _live_target_matches_lock(
	profile: Dictionary,
	_action: StringName
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


## Connect tool click (CABLE-ROPE-V0): the first click ties the rope end to
## whatever is under the cursor — any block, or a point on terrain — and the
## rope then trails the cursor live. The second click ties the far end and the
## rope is built. ПКМ отменяет только текущую протяжку. Колесо — слабина.
func _handle_connect_click(hit: InteractionHit) -> void:
	if hit == null or not hit.valid or hit.distance > rope_click_range():
		return
	var element_id := _rope_target_element_id(hit)
	var world_point := hit.point + hit.normal * CONNECT_SURFACE_OFFSET
	if not _rope_pending:
		_reset_connect_route()
		_rope_pending = true
		_rope_anchor_element_id = element_id
		_rope_anchor_local = _localize_rope_point(element_id, world_point)
		return
	var anchor_world := rope_anchor_world_position()
	if not anchor_world.is_finite():
		_reset_connect_route()
		return
	if anchor_world.distance_to(world_point) < CableAnchorUtil.MIN_SPAN_M:
		# Same spot twice — the player is fumbling, not building a rope.
		return
	command_requested.emit({
		"kind": &"connect_network",
		"source": get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"rope": true,
			"element_a_id": _rope_anchor_element_id,
			"attach_a": anchor_world,
			"element_b_id": element_id,
			"attach_b": world_point,
			"slack": _rope_slack,
		},
	})
	_reset_connect_route()


## Blocks carry their rope end; terrain, boulders and everything else nail it
## to the world.
func _rope_target_element_id(hit: InteractionHit) -> int:
	if hit == null or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		return 0
	return maxi(int(hit.metadata.get("element_id", 0)), 0)


func _localize_rope_point(element_id: int, world_point: Vector3) -> Vector3:
	if element_id <= 0:
		return world_point
	return CableAnchorUtil.localize(
		_simulation_world(),
		element_id,
		world_point
	)


## Live world position of the rope end already tied down — recomputed every
## frame so the rope stays attached to a machine that is driving away.
func rope_anchor_world_position() -> Vector3:
	if not _rope_pending:
		return Vector3(INF, INF, INF)
	return CableAnchorUtil.endpoint_world_position(
		_simulation_world(),
		_rope_anchor_element_id,
		"",
		_rope_anchor_local
	)


func rope_routing_active() -> bool:
	return _rope_pending


## How far the current click reaches: arm's length for the first end, a throw
## for the second. InteractionQuery stretches the aim ray to match.
func rope_click_range() -> float:
	return CONNECT_THROW_RANGE if _rope_pending else CONNECT_RANGE


func rope_slack() -> float:
	return _rope_slack


## Wheel while a rope is being pulled: tight ↔ loose. Nothing else in gameplay
## uses the wheel, so it needs no modifier.
func _unhandled_input(event: InputEvent) -> void:
	if not _rope_pending or active_tool != &"connect":
		return
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	var steps := 0
	if button.button_index == MOUSE_BUTTON_WHEEL_UP:
		steps = 1
	elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		steps = -1
	if steps == 0:
		return
	if button.shift_pressed:
		steps *= CableAnchorUtil.SLACK_COARSE_MULTIPLIER
	_rope_slack = CableAnchorUtil.step_slack(_rope_slack, steps)
	get_viewport().set_input_as_handled()


## ПКМ — отмена только текущей протяжки: ropes already built stay where they
## are, and the tool stays in connect mode ready for the next one.
func _cancel_rope_routing() -> void:
	_reset_connect_route()


func _reset_connect_route() -> void:
	_rope_pending = false
	_rope_anchor_element_id = 0
	_rope_anchor_local = Vector3.ZERO


func _simulation_world() -> SimulationWorld:
	if _gateway == null:
		return null
	var session := _gateway.get_node_or_null(
		_gateway.simulation_session_path
	) as SimulationSession
	if session == null:
		return null
	return session.world


## The block the pending rope starts on, 0 when it starts on terrain (or when
## no rope is being pulled). Presentation uses it to highlight that block.
func connect_pending_element_id() -> int:
	return _rope_anchor_element_id if _rope_pending else 0


func selected_recipe_for_element(element_id: int, archetype_id: String) -> String:
	if element_id <= 0 or archetype_id.is_empty():
		return ""
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return ""
	_ensure_recipe_cursor(element_id, archetype_id)
	var cursor := int(_recipe_cursor_by_element.get(element_id, 0))
	return recipe_ids[wrapi(cursor, 0, recipe_ids.size())]


func next_recipe_for_target(hit: InteractionHit) -> String:
	if not _is_recipe_machine_hit(hit):
		return ""
	var archetype_id := str(hit.metadata.get("archetype_id", ""))
	var element_id := int(hit.metadata.get("element_id", 0))
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return ""
	_ensure_recipe_cursor(element_id, archetype_id)
	var cursor := int(_recipe_cursor_by_element.get(element_id, 0))
	return recipe_ids[wrapi(cursor, 0, recipe_ids.size())]


func recipe_ids_for_target(hit: InteractionHit) -> PackedStringArray:
	if not _is_recipe_machine_hit(hit):
		return PackedStringArray()
	return RecipeCatalog.recipe_ids_for_machine(
		str(hit.metadata.get("archetype_id", ""))
	)


func _ensure_recipe_cursor(element_id: int, archetype_id: String) -> void:
	if _recipe_cursor_by_element.has(element_id):
		return
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return
	var default_id := RecipeCatalog.default_recipe_for_machine(archetype_id)
	var default_index := recipe_ids.find(default_id)
	_recipe_cursor_by_element[element_id] = (
		default_index if default_index >= 0 else 0
	)


func _cycle_target_recipe(hit: InteractionHit, delta: int) -> bool:
	if not _is_recipe_machine_hit(hit) or delta == 0:
		return false
	var archetype_id := str(hit.metadata.get("archetype_id", ""))
	var element_id := int(hit.metadata.get("element_id", 0))
	var recipe_ids := RecipeCatalog.recipe_ids_for_machine(archetype_id)
	if recipe_ids.is_empty():
		return false
	_ensure_recipe_cursor(element_id, archetype_id)
	var cursor := int(_recipe_cursor_by_element.get(element_id, 0))
	_recipe_cursor_by_element[element_id] = wrapi(
		cursor + delta,
		0,
		recipe_ids.size()
	)
	return true


func _is_recipe_machine_hit(hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
		or hit.distance > 4.0
	):
		return false
	return str(hit.metadata.get("archetype_id", "")) in ["processor", "fabricator"]


func _try_emit_context_interaction(hit: InteractionHit) -> bool:
	if _try_collect_world_loot(hit):
		return true
	if active_tool != &"connect" and _try_open_wheel_panel(hit):
		return true
	if active_tool != &"connect" and _try_open_actuator_panel(hit):
		return true
	if active_tool != &"connect" and _try_open_terminal(hit):
		return true
	return false


func _ui_modal_blocks_world_interact() -> bool:
	return (
		_terminal_blocks_world_interact()
		or _actuator_panel_blocks_world_interact()
		or _wheel_panel_blocks_world_interact()
		or _control_terminal_blocks_world_interact()
	)


func _control_terminal_is_open() -> bool:
	return (
		_control_terminal != null
		and _control_terminal.has_method("is_open")
		and bool(_control_terminal.call("is_open"))
	)


func _control_terminal_blocks_world_interact() -> bool:
	return (
		_control_terminal != null
		and _control_terminal.has_method("blocks_world_interact")
		and bool(_control_terminal.call("blocks_world_interact"))
	)


func _actuator_panel_is_open() -> bool:
	return (
		_actuator_panel != null
		and _actuator_panel.has_method("is_open")
		and bool(_actuator_panel.call("is_open"))
	)


func _actuator_panel_blocks_world_interact() -> bool:
	return (
		_actuator_panel != null
		and _actuator_panel.has_method("blocks_world_interact")
		and bool(_actuator_panel.call("blocks_world_interact"))
	)


func _try_open_actuator_panel(hit: InteractionHit) -> bool:
	if _actuator_panel == null or not _actuator_panel.has_method("try_open_on_target"):
		return false
	if _ui_modal_blocks_world_interact():
		return false
	if _actuator_panel.has_method("is_open") and bool(_actuator_panel.call("is_open")):
		return false
	return bool(_actuator_panel.call("try_open_on_target", hit))


func _wheel_panel_is_open() -> bool:
	return (
		_wheel_panel != null
		and _wheel_panel.has_method("is_open")
		and bool(_wheel_panel.call("is_open"))
	)


func _wheel_panel_blocks_world_interact() -> bool:
	return (
		_wheel_panel != null
		and _wheel_panel.has_method("blocks_world_interact")
		and bool(_wheel_panel.call("blocks_world_interact"))
	)


func _try_open_wheel_panel(hit: InteractionHit) -> bool:
	if _wheel_panel == null or not _wheel_panel.has_method("try_open_on_target"):
		return false
	if _ui_modal_blocks_world_interact():
		return false
	if _wheel_panel.has_method("is_open") and bool(_wheel_panel.call("is_open")):
		return false
	return bool(_wheel_panel.call("try_open_on_target", hit))


func _terminal_is_open() -> bool:
	return (
		_terminal != null
		and _terminal.has_method("is_open")
		and bool(_terminal.call("is_open"))
	)


func _terminal_blocks_world_interact() -> bool:
	return (
		_terminal != null
		and _terminal.has_method("blocks_world_interact")
		and bool(_terminal.call("blocks_world_interact"))
	)


func _try_open_terminal(hit: InteractionHit) -> bool:
	if _terminal == null or not _terminal.has_method("try_open_on_target"):
		return false
	if (
		_terminal.has_method("blocks_world_interact")
		and bool(_terminal.call("blocks_world_interact"))
	):
		return false
	if _terminal.has_method("is_open") and bool(_terminal.call("is_open")):
		return false
	return bool(_terminal.call("try_open_on_target", hit))


func _is_terminal_target_hit(hit: InteractionHit) -> bool:
	return not IndustryTransferUtil.terminal_store_id_for_hit(hit, _gateway).is_empty()


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
			"to_store_id": PlayerIdentity.local_store_id(),
		},
	})
	return true


func _try_enqueue_target_recipe(hit: InteractionHit) -> bool:
	if not _is_recipe_machine_hit(hit):
		return false
	if Input.is_key_pressed(KEY_SHIFT):
		return _try_dequeue_target_recipe(hit)
	var recipe_id := next_recipe_for_target(hit)
	if recipe_id.is_empty():
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
	return true


func _try_dequeue_target_recipe(hit: InteractionHit) -> bool:
	if not _is_recipe_machine_hit(hit):
		return false
	var element_id := int(hit.metadata.get("element_id", 0))
	command_requested.emit({
		"kind": &"dequeue_recipe",
		"source": get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"element_id": element_id,
		},
	})
	return true


func _is_actuator_target_hit(hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
		or hit.distance > 4.5
	):
		return false
	return (
		hit.metadata.has("piston_joint_id")
		or hit.metadata.has("rotor_joint_id")
		or hit.metadata.has("hinge_joint_id")
	)


func _actuator_hit_joint_id(hit: InteractionHit) -> int:
	var joint_id := int(hit.metadata.get("piston_joint_id", 0))
	if joint_id > 0:
		return joint_id
	joint_id = int(hit.metadata.get("rotor_joint_id", 0))
	if joint_id > 0:
		return joint_id
	return int(hit.metadata.get("hinge_joint_id", 0))


func _actuator_hit_forward_velocity(hit: InteractionHit) -> float:
	if hit.metadata.has("rotor_joint_id"):
		return float(hit.metadata.get("rotor_forward_velocity_rad_s", 0.5))
	if hit.metadata.has("hinge_joint_id"):
		return float(hit.metadata.get("hinge_forward_velocity_rad_s", 0.5))
	return float(hit.metadata.get("piston_extend_velocity_mps", 0.25))


func _actuator_hit_reverse_velocity(hit: InteractionHit) -> float:
	if hit.metadata.has("rotor_joint_id"):
		return float(hit.metadata.get("rotor_reverse_velocity_rad_s", 0.5))
	if hit.metadata.has("hinge_joint_id"):
		return float(hit.metadata.get("hinge_reverse_velocity_rad_s", 0.5))
	return float(hit.metadata.get("piston_retract_velocity_mps", 0.25))


func _try_actuator_extend(hit: InteractionHit) -> bool:
	return _emit_actuator_target(
		hit,
		SimulationMotorState.ControlMode.VELOCITY,
		_actuator_hit_forward_velocity(hit),
		true
	)


func _try_actuator_retract(hit: InteractionHit) -> bool:
	return _emit_actuator_target(
		hit,
		SimulationMotorState.ControlMode.VELOCITY,
		-_actuator_hit_reverse_velocity(hit),
		true
	)


func _try_actuator_stop(hit: InteractionHit) -> bool:
	return _emit_actuator_target(
		hit,
		SimulationMotorState.ControlMode.STOP,
		0.0,
		true
	)


func _emit_actuator_target(
	hit: InteractionHit,
	mode: SimulationMotorState.ControlMode,
	target_velocity_mps: float,
	enabled: bool
) -> bool:
	if not _is_actuator_target_hit(hit):
		return false
	var joint_id := _actuator_hit_joint_id(hit)
	if joint_id <= 0:
		return false
	var joint_ids: Array[int] = [joint_id]
	if (
		actuator_chain_sync
		and hit.metadata.has("piston_joint_id")
		and not hit.metadata.has("rotor_joint_id")
		and not hit.metadata.has("hinge_joint_id")
	):
		var assembly_id := int(hit.metadata.get("assembly_id", 0))
		var world := _simulation_world()
		if world != null and assembly_id > 0:
			joint_ids = PistonPlacementUtil.piston_joint_ids_in_assembly(
				world,
				assembly_id
			)
			if joint_ids.is_empty():
				joint_ids = [joint_id]
	for target_joint_id: int in joint_ids:
		command_requested.emit({
			"kind": &"set_actuator_target",
			"source": get_parent(),
			"target": hit.snapshot(),
			"parameters": {
				"joint_id": target_joint_id,
				"mode": mode,
				"target_velocity_mps": target_velocity_mps,
				"enabled": enabled,
			},
		})
	return true


func toggle_actuator_motor(hit: InteractionHit) -> bool:
	if not _is_actuator_target_hit(hit):
		return false
	var joint_id := _actuator_hit_joint_id(hit)
	if joint_id <= 0:
		return false
	var enabled_now := true
	if hit.metadata.has("piston_joint_id"):
		enabled_now = bool(hit.metadata.get("piston_motor_enabled", true))
	elif hit.metadata.has("rotor_joint_id"):
		enabled_now = bool(hit.metadata.get("rotor_motor_enabled", true))
	elif hit.metadata.has("hinge_joint_id"):
		enabled_now = bool(hit.metadata.get("hinge_motor_enabled", true))
	return _emit_actuator_target(
		hit,
		SimulationMotorState.ControlMode.STOP,
		0.0,
		not enabled_now
	)


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


func _sync_inventory_toolbar_if_needed() -> void:
	if _gateway == null:
		return
	var revision := _gateway.player_inventory_revision()
	if revision == _inventory_revision:
		return
	_inventory_revision = revision
	_sync_toolbar_from_inventory()
	toolbar_layout_revision += 1
	_apply_toolbar_slot_or_first_nonempty(
		toolbar_page,
		toolbar_slot,
		true
	)


func _sync_toolbar_from_inventory() -> void:
	_ensure_runtime_state()
	var registry := _player_inventory()
	if registry == null:
		return
	PlayerHotbarBridge.apply_registry_to_layout(
		registry,
		_toolbar_layout,
		TOOLBAR_PAGES
	)


func _active_slot_resolved() -> Dictionary:
	return PlayerHotbarBridge.resolve_slot_entry(
		_player_inventory(),
		_toolbar_entry(toolbar_page, toolbar_slot)
	)


func _active_tool_is_equipped() -> bool:
	match active_tool:
		&"drill", &"weld", &"grinder", &"connect":
			var resolved := _active_slot_resolved()
			if StringName(resolved.get("kind", &"")) != &"tool_instance":
				return false
			var instance_id := str(resolved.get("instance_id", ""))
			if instance_id.is_empty():
				return bool(resolved.get("legacy", false))
			var registry := _player_inventory()
			return (
				registry != null
				and registry.has_instance(instance_id)
				and PlayerHotbarBridge.slot_owns_instance(
					registry,
					toolbar_page,
					toolbar_slot,
					instance_id
				)
			)
		_:
			return true


func _transition(next_state: ActionState) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(active_action, state, progress)
