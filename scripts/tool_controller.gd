class_name ToolController
extends Node

signal state_changed(
	action: StringName,
	state: ActionState,
	progress: float
)
signal command_requested(command: Dictionary)

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
		"command": &"place_block",
		"max_range": 4.0,
		"interval": 0.12,
		"continuous": true,
	},
	&"interact": {
		"command": &"toggle_control_seat",
		"max_range": 4.5,
		"interval": 0.0,
		"continuous": false,
	},
}

var state := ActionState.IDLE
var active_action := StringName()
var progress := 0.0

var _query: InteractionQuery
var _gateway: WorldCommandGateway
var _cooldown := 0.0
var _issued_for_press := false


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
	var requested_action := _pressed_action()
	if requested_action.is_empty():
		if state == ActionState.PRESSED or state == ActionState.HOLDING:
			_transition(ActionState.CANCELLED)
		else:
			_transition(ActionState.IDLE)
		active_action = StringName()
		progress = 0.0
		_issued_for_press = false
		return

	if active_action != requested_action:
		active_action = requested_action
		progress = 0.0
		_cooldown = 0.0
		_issued_for_press = false
		_transition(ActionState.PRESSED)

	var profile: Dictionary = ACTIONS[active_action]
	var hit := _target_for_action(active_action)
	if not hit.valid or hit.distance > float(profile["max_range"]):
		_transition(ActionState.CANCELLED)
		progress = 0.0
		return
	if _issued_for_press and not bool(profile["continuous"]):
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
		"parameters": {},
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
