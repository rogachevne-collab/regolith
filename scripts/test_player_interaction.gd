extends CharacterBody3D

class SeatProbe:
	extends Node3D

	var interaction_count := 0

	func handle_interact(_source: Node3D) -> bool:
		interaction_count += 1
		return true


@onready var _query: InteractionQuery = $InteractionQuery
@onready var _tools: ToolController = $ToolController
@onready var _gateway: WorldCommandGateway = $WorldCommandGateway
@onready var _placed_blocks: Node = $PlacedBlocks

var _completed_commands := 0


func _ready() -> void:
	_gateway.command_completed.connect(_on_command_completed)
	call_deferred("_run_test")


func _run_test() -> void:
	await get_tree().process_frame
	_query.current_hit = InteractionHit.create(
		Vector3(2.2, 0.0, 0.0),
		Vector3.UP,
		2.2,
		InteractionHit.KIND_BODY
	)
	Input.action_press("tool_primary")
	Input.action_press("tool_secondary")
	_tools._physics_process(0.016)
	await get_tree().process_frame
	if _completed_commands != 1:
		_fail("place dispatched %d commands" % _completed_commands)
		return
	if not _placed_blocks.call("has_block", Vector3i(2, 0, 0)):
		_fail("secondary did not override simultaneous primary")
		return

	_tools._physics_process(0.05)
	await get_tree().process_frame
	if _completed_commands != 1:
		_fail("place repeated before its action interval")
		return
	Input.action_release("tool_secondary")
	Input.action_release("tool_primary")
	_tools._physics_process(0.016)

	var seat := SeatProbe.new()
	add_child(seat)
	_query.current_hit = InteractionHit.create(
		Vector3.ZERO,
		Vector3.UP,
		1.0,
		InteractionHit.KIND_CONTROL_SEAT,
		seat
	)
	Input.action_press("interact")
	_tools._physics_process(0.016)
	await get_tree().process_frame
	_tools._physics_process(1.0)
	await get_tree().process_frame
	if seat.interaction_count != 1:
		_fail("tap interaction dispatched %d times" % seat.interaction_count)
		return
	Input.action_release("interact")
	_tools._physics_process(0.016)

	_query.current_hit = InteractionHit.empty()
	Input.action_press("tool_primary")
	_tools._physics_process(0.016)
	Input.action_release("tool_primary")
	if _tools.state != ToolController.ActionState.CANCELLED:
		_fail("lost target did not cancel the action")
		return

	print("PLAYER1: PASS")
	get_tree().quit(0)


func is_gameplay_input_enabled() -> bool:
	return true


func is_in_vehicle() -> bool:
	return false


func _on_command_completed(
	_command_id: int,
	_result: Dictionary
) -> void:
	_completed_commands += 1


func _fail(reason: String) -> void:
	Input.action_release("tool_primary")
	Input.action_release("tool_secondary")
	Input.action_release("interact")
	print("PLAYER1: FAIL %s" % reason)
	get_tree().quit(1)
