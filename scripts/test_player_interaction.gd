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
@onready var _preview: ConstructionPreview = $ConstructionPreview
@onready var _camera: Camera3D = $Camera

var _completed_commands := 0
var _last_command_kind := StringName()
var _last_command_target: Dictionary = {}
var _last_command_parameters: Dictionary = {}


func _ready() -> void:
	_gateway.command_completed.connect(_on_command_completed)
	_tools.command_requested.connect(_on_command_requested)
	call_deferred("_run_test")


func aim_transform() -> Transform3D:
	return _camera.global_transform


func _run_test() -> void:
	await get_tree().process_frame
	if _tools.active_tool != &"drill":
		_fail("default toolbar slot must be drill")
		return
	if _tools.toolbar_page_count() <= 1:
		_fail("toolbar must expose multiple pages")
		return

	await _select_toolbar_slot(4)
	if _tools.active_tool != &"build":
		_fail("slot 4 must select build mode")
		return
	if _tools.selected_archetype_id != "frame":
		_fail("slot 4 must select frame archetype")
		return

	_query.current_hit = InteractionHit.create(
		Vector3(2.2, 0.0, 0.0),
		Vector3.UP,
		2.2,
		InteractionHit.KIND_BODY
	)
	_preview._physics_process(0.016)
	Input.action_press("tool_primary")
	_tools._physics_process(0.016)
	await get_tree().process_frame
	if _completed_commands != 1:
		_fail("place dispatched %d commands" % _completed_commands)
		return
	if not _placed_blocks.call("has_block", Vector3i(2, 0, 0)):
		_fail("primary did not place block")
		return

	_tools._physics_process(0.05)
	await get_tree().process_frame
	if _completed_commands != 1:
		_fail("place repeated before its action interval")
		return
	Input.action_release("tool_primary")
	_tools._physics_process(0.016)

	_completed_commands = 0
	Input.action_press("tool_secondary")
	_tools._physics_process(0.016)
	await get_tree().process_frame
	if _completed_commands != 0:
		_fail("secondary must not place blocks")
		return
	Input.action_release("tool_secondary")

	var orientation_before := _tools.selected_orientation_index
	Input.action_press("construction_rotate_yaw")
	_tools._physics_process(0.016)
	if _tools.selected_orientation_index == orientation_before:
		_fail("yaw rotation did not change orientation in build mode")
		return
	if (
		_tools.selected_orientation_index < 0
		or _tools.selected_orientation_index >= OrientationUtil.ORIENTATION_COUNT
	):
		_fail("orientation index out of range after yaw")
		return
	Input.action_release("construction_rotate_yaw")
	await get_tree().process_frame

	await _select_toolbar_slot(1)
	if _tools.active_tool != &"drill":
		_fail("slot 1 must select drill")
		return
	var drill_orientation := _tools.selected_orientation_index
	Input.action_press("construction_rotate_yaw")
	_tools._physics_process(0.016)
	if _tools.selected_orientation_index != drill_orientation:
		_fail("yaw rotation must not change orientation outside build mode")
		return
	if _tools.active_tool != &"drill":
		_fail("yaw rotation must not force build mode")
		return
	Input.action_release("construction_rotate_yaw")
	await get_tree().process_frame

	_completed_commands = 0
	_query.current_hit = InteractionHit.create(
		Vector3(1.0, 0.0, 0.0),
		Vector3.UP,
		1.0,
		InteractionHit.KIND_VOXEL
	)
	Input.action_press("tool_primary")
	_tools._physics_process(0.016)
	await get_tree().process_frame
	if _completed_commands != 1 or _last_command_kind != &"voxel_remove":
		_fail("drill slot must dispatch voxel_remove")
		return
	Input.action_release("tool_primary")
	_tools._physics_process(0.016)
	await get_tree().process_frame

	_completed_commands = 0
	_last_command_kind = StringName()
	_last_command_parameters = {}
	_query.current_hit = InteractionHit.create(
		Vector3(1.0, 0.0, 0.0),
		Vector3.UP,
		1.0,
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		"element_1",
		{"archetype_id": "frame", "status_reason": &"ok"}
	)
	Input.action_press("tool_primary")
	_tools._physics_process(0.016)
	await get_tree().process_frame
	if _completed_commands != 1 or _last_command_kind != &"damage_element":
		_fail("drill slot must dispatch damage_element on construction")
		return
	var drill_damage := ToolController.DRILL_DPS * ToolController.DRILL_INTERVAL
	if absf(float(_last_command_parameters.get("damage", 0.0)) - drill_damage) > 0.001:
		_fail(
			"drill damage expected %.4f, got %s"
			% [drill_damage, str(_last_command_parameters.get("damage", 0.0))]
		)
		return
	Input.action_release("tool_primary")
	_tools._physics_process(0.016)
	await get_tree().process_frame

	await _select_toolbar_slot(3)
	if _tools.active_tool != &"grinder":
		_fail("slot 3 must select grinder")
		return
	_completed_commands = 0
	_last_command_kind = StringName()
	_query.current_hit = InteractionHit.create(
		Vector3(1.0, 0.0, 0.0),
		Vector3.UP,
		1.0,
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		"element_1",
		{"archetype_id": "frame", "status_reason": &"ok"}
	)
	Input.action_press("tool_primary")
	_tools._physics_process(0.016)
	await get_tree().process_frame
	if _completed_commands != 1 or _last_command_kind != &"damage_element":
		_fail("grinder slot must dispatch damage_element")
		return
	var expected_damage := ToolController.GRINDER_DPS * ToolController.GRINDER_INTERVAL
	if absf(float(_last_command_parameters.get("damage", 0.0)) - expected_damage) > 0.001:
		_fail(
			"grinder damage expected %.4f, got %s"
			% [expected_damage, str(_last_command_parameters.get("damage", 0.0))]
		)
		return
	Input.action_release("tool_primary")
	_tools._physics_process(0.016)
	await get_tree().process_frame

	await _select_toolbar_slot(4)
	await get_tree().process_frame
	_query.current_hit = InteractionHit.empty()
	_completed_commands = 0
	_last_command_kind = StringName()
	Input.action_press("tool_primary")
	_tools._physics_process(0.016)
	await get_tree().process_frame
	if _completed_commands != 0 or _last_command_kind == &"voxel_remove":
		_fail("build slot without preview must not dispatch drill/voxel commands")
		return
	Input.action_release("tool_primary")

	Input.action_press("toolbar_page_next")
	_tools._physics_process(0.016)
	if _tools.toolbar_page != 1:
		_fail("toolbar page next did not switch page")
		return
	if _tools.selected_archetype_id != "processor":
		_fail("page 2 should select first non-empty slot (processor)")
		return
	Input.action_release("toolbar_page_next")
	await get_tree().process_frame

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

	while _tools.toolbar_page != 0:
		Input.action_press("toolbar_page_prev")
		_tools._physics_process(0.016)
		Input.action_release("toolbar_page_prev")
	await get_tree().process_frame
	await _select_toolbar_slot(1)
	_query.current_hit = InteractionHit.empty()
	Input.action_press("tool_primary")
	_tools._physics_process(0.016)
	if _tools.state != ToolController.ActionState.HOLDING:
		_fail("drill hold without target should stay holding")
		return
	Input.action_release("tool_primary")
	_tools._physics_process(0.016)
	if (
		_tools.state != ToolController.ActionState.IDLE
		and _tools.state != ToolController.ActionState.CANCELLED
	):
		_fail("released drill hold should end the action")
		return

	_completed_commands = 0
	_last_command_target = {}
	Input.action_press("tool_primary")
	_query.current_hit = InteractionHit.create(
		Vector3(1.0, 0.0, 0.0),
		Vector3.UP,
		1.0,
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		"element_a",
		{"archetype_id": "frame", "status_reason": &"ok"}
	)
	_tools._physics_process(0.016)
	await get_tree().process_frame
	_query.current_hit = InteractionHit.create(
		Vector3(1.2, 0.0, 0.0),
		Vector3.UP,
		1.1,
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		"element_b",
		{"archetype_id": "frame", "status_reason": &"ok"}
	)
	_tools._physics_process(0.06)
	await get_tree().process_frame
	if _completed_commands < 2:
		_fail("live drill hold expected ticks on swept targets")
		return
	if String(_last_command_target.get("target_id", "")) != "element_b":
		_fail("live drill hold should track the current target")
		return
	Input.action_release("tool_primary")
	_tools._physics_process(0.016)

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


func _on_command_requested(command: Dictionary) -> void:
	_last_command_kind = StringName(command.get("kind", &""))
	_last_command_target = command.get("target", {})
	_last_command_parameters = command.get("parameters", {})


func _select_toolbar_slot(slot: int) -> void:
	for index: int in range(1, 10):
		Input.action_release("toolbar_slot_%d" % index)
	await get_tree().process_frame
	Input.action_press("toolbar_slot_%d" % slot)
	_tools._physics_process(0.016)


func _fail(reason: String) -> void:
	Input.action_release("tool_primary")
	Input.action_release("tool_secondary")
	Input.action_release("interact")
	print("PLAYER1: FAIL %s" % reason)
	get_tree().quit(1)
