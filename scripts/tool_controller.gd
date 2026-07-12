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

enum ActionState {
	IDLE,
	PRESSED,
	HOLDING,
	COMPLETED,
	CANCELLED,
}

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var gateway_path: NodePath = NodePath("../../WorldCommandGateway")

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
	&"interact": {
		"command": &"toggle_control_seat",
		"max_range": 4.5,
		"interval": 0.0,
		"continuous": false,
	},
	&"construction_dismantle": {
		"command": &"dismantle_element",
		"max_range": 4.0,
		"interval": 0.0,
		"continuous": false,
	},
}

const CONSTRUCTION_ARCHETYPES: PackedStringArray = [
	"foundation",
	"frame",
	"frame_beam",
	"power_source",
	"stationary_drill",
	"cargo_store",
	"processor",
	"fabricator",
]

var state := ActionState.IDLE
var active_action := StringName()
var progress := 0.0
var selected_archetype_id := "frame"
var selected_orientation_index := 0

var _query: InteractionQuery
var _gateway: WorldCommandGateway
var _cooldown := 0.0
var _issued_for_press := false
var _construction_yaw_step := 0
var _locked_hit: InteractionHit
var _construction_mode := &"context"


func _ready() -> void:
	_query = get_node(query_path)
	_gateway = get_node(gateway_path)
	command_requested.connect(_gateway.submit)


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
		_update_construction_selection()
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
			_query.current_hit
			if requested_action == &"tool_secondary"
			or requested_action == &"construction_dismantle"
			else null
		)
		_construction_mode = _resolve_construction_mode(
			_locked_hit
		)
		_transition(ActionState.PRESSED)

	var profile: Dictionary = ACTIONS[active_action]
	var hit := (
		_locked_hit
		if _locked_hit != null
		else _target_for_action(active_action)
	)
	if (
		_locked_hit != null
		and _issued_for_press
		and not _live_target_matches_lock(profile)
	):
		_transition(ActionState.CANCELLED)
		progress = 0.0
		return
	if not hit.valid or hit.distance > float(profile["max_range"]):
		_transition(ActionState.CANCELLED)
		progress = 0.0
		return
	var continuous := bool(profile["continuous"])
	if (
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

	command_requested.emit({
		"kind": profile["command"],
		"source": get_parent(),
		"target": hit.snapshot(),
		"parameters": {
			"archetype_id": selected_archetype_id,
			"orientation_index": selected_orientation_index,
			"construction_mode": _construction_mode,
		},
	})
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


func _pressed_action() -> StringName:
	for action: StringName in ACTIONS:
		if (
			action != &"interact"
			and get_parent().has_method("is_in_vehicle")
			and get_parent().call("is_in_vehicle")
		):
			continue
		if Input.is_action_pressed(action):
			return action
	return StringName()


func _update_construction_selection() -> void:
	for index: int in range(CONSTRUCTION_ARCHETYPES.size()):
		var action := StringName("construction_slot_%d" % [index + 1])
		if Input.is_action_just_pressed(action):
			selected_archetype_id = CONSTRUCTION_ARCHETYPES[index]
			construction_selection_changed.emit(
				selected_archetype_id,
				selected_orientation_index
			)
	if Input.is_action_just_pressed(&"construction_rotate"):
		_construction_yaw_step = (_construction_yaw_step + 1) % 4
		selected_orientation_index = _yaw_orientation_index(
			_construction_yaw_step
		)
		construction_selection_changed.emit(
			selected_archetype_id,
			selected_orientation_index
		)


func _yaw_orientation_index(step: int) -> int:
	var target := Basis(Vector3.UP, float(step) * PI * 0.5)
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.orientation_basis(index).is_equal_approx(target):
			return index
	return 0


func _resolve_construction_mode(hit: InteractionHit) -> StringName:
	if hit == null or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		return &"place"
	var status := StringName(
		hit.metadata.get("status_reason", &"element_incomplete")
	)
	if status == &"element_incomplete":
		return &"weld"
	if status == &"element_broken" or status == &"damaged":
		return &"repair"
	return &"place"


func _live_target_matches_lock(profile: Dictionary) -> bool:
	var live := _query.current_hit
	return (
		live.valid
		and live.distance <= float(profile["max_range"])
		and live.target_kind == _locked_hit.target_kind
		and live.target_id == _locked_hit.target_id
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


func _transition(next_state: ActionState) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(active_action, state, progress)
