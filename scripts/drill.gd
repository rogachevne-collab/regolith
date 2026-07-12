extends Node

@export var head_path: NodePath = NodePath("../Camera")
@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")
@export var drill_visual_path: NodePath = NodePath("../Camera/DrillVisual")
@export var drill_bit_path: NodePath = NodePath(
	"Mount/Model/Sketchfab_model/Drill_Low_fbx/RootNode/Body_Low/Cone"
)
@export var sparks_path: NodePath = NodePath("../Camera/DrillVisual/Sparks")
@export var drill_audio_path: NodePath = NodePath("../Camera/DrillAudio")
@export var reach := 2.2
@export var drill_spin_speed := 28.0
@export var rest_offset := Vector3(0.28, -0.22, -0.05)

var _head: Camera3D
var _query: InteractionQuery
var _tool_controller: ToolController
var _drill_visual: Node3D
var _drill_bit: Node3D
var _sparks: GPUParticles3D
var _audio: AudioStreamPlayer3D
var _drilling := false


func _ready() -> void:
	_head = get_node(head_path)
	_query = get_node(query_path)
	_tool_controller = get_node(tool_controller_path)
	_drill_visual = get_node(drill_visual_path)
	_drill_bit = _drill_visual.get_node(drill_bit_path)
	_sparks = get_node(sparks_path)
	_audio = get_node(drill_audio_path)
	_sparks.emitting = false
	var stream := _audio.stream as AudioStreamWAV
	if stream:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD


func _physics_process(_delta: float) -> void:
	var aim: Transform3D = _head.call("aim_transform")
	var direction := -aim.basis.z.normalized()
	var hit: InteractionHit = _query.current_hit
	var has_hit := (
		hit.valid
		and hit.target_kind == InteractionHit.KIND_VOXEL
		and hit.distance <= reach
	)
	var contact := hit.point if has_hit else aim.origin + direction * reach
	_update_drill_pose()
	var action_active := (
		_tool_controller.active_action == &"tool_primary"
		and (
			_tool_controller.state == ToolController.ActionState.HOLDING
			or _tool_controller.state == ToolController.ActionState.COMPLETED
		)
	)
	_set_drilling(has_hit and action_active)
	if _drilling:
		_sparks.global_position = contact
		_sparks.look_at(contact + direction, Vector3.UP)


func _process(delta: float) -> void:
	if _drilling:
		var spin_axis := _drill_bit.global_transform.basis.y.normalized()
		_drill_bit.global_rotate(spin_axis, drill_spin_speed * delta)


func _update_drill_pose() -> void:
	var rest: Vector3 = (
		_head.global_position
		+ _head.global_transform.basis * rest_offset
	)
	_drill_visual.global_rotation = _head.global_rotation
	_drill_visual.global_position = rest


func _set_drilling(active: bool) -> void:
	if _drilling == active:
		return
	_drilling = active
	if active:
		if not _audio.playing:
			_audio.play()
	else:
		_audio.stop()
		_sparks.emitting = false
