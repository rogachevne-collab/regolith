extends Node

@export var terrain_path: NodePath
@export var head_path: NodePath = NodePath("../Camera")
@export var drill_visual_path: NodePath = NodePath("../Camera/DrillVisual")
@export var sparks_path: NodePath = NodePath("../Camera/DrillVisual/Sparks")
@export var drill_audio_path: NodePath = NodePath("../Camera/DrillAudio")
@export var drill_radius := 0.68
@export var reach := 2.2
@export var tick_interval := 0.05
@export var drill_spin_speed := 28.0

var _terrain: VoxelTerrain
var _head: Camera3D
var _tool: VoxelTool
var _cooldown := 0.0
var _player: Node3D
var _drill_visual: Node3D
var _drill_bit: Node3D
var _sparks: GPUParticles3D
var _audio: AudioStreamPlayer3D
var _drilling := false


func _ready() -> void:
	_terrain = get_node(terrain_path)
	_head = get_node(head_path)
	_player = get_parent()
	_drill_visual = get_node(drill_visual_path)
	_drill_bit = _drill_visual.get_node("Bit")
	_sparks = get_node(sparks_path)
	_audio = get_node(drill_audio_path)
	_tool = _terrain.get_voxel_tool()
	_tool.channel = VoxelBuffer.CHANNEL_SDF
	_sparks.emitting = false
	var stream := _audio.stream as AudioStreamWAV
	if stream:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD


func _physics_process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)

	if _player.has_method("is_spawn_ready") and not _player.is_spawn_ready():
		_set_drilling(false)
		return

	var origin: Vector3 = _head.global_position
	var direction: Vector3 = -_head.global_transform.basis.z.normalized()
	var contact_info := _find_contact(origin, direction)
	var has_hit := not contact_info.is_empty()
	var contact: Vector3 = contact_info.get("point", origin + direction * reach)

	_update_drill_pose(direction, contact, has_hit)

	if not has_hit or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_set_drilling(false)
		return

	_set_drilling(true)
	if _cooldown > 0.0:
		return

	_tool.mode = VoxelTool.MODE_REMOVE
	var center: Vector3 = contact - direction * drill_radius * 0.25
	_tool.do_sphere(center, drill_radius)
	_cooldown = tick_interval
	_sparks.global_position = contact
	_sparks.look_at(contact + direction, Vector3.UP)
	if not _sparks.emitting:
		_sparks.restart()
		_sparks.emitting = true


func _process(delta: float) -> void:
	if _drilling:
		_drill_bit.rotate_object_local(Vector3.FORWARD, drill_spin_speed * delta)


func _find_contact(origin: Vector3, direction: Vector3) -> Dictionary:
	# Visible mesh collider first — voxel SDF raycast often misses at short FP distances.
	var space := _terrain.get_world_3d().direct_space_state
	var end: Vector3 = origin + direction * reach
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.exclude = [_player.get_rid()]
	query.collision_mask = 3
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var phys_hit := space.intersect_ray(query)
	if not phys_hit.is_empty():
		var point: Vector3 = phys_hit["position"]
		return {
			"point": point,
			"distance": origin.distance_to(point),
		}

	var voxel_hit: VoxelRaycastResult = _tool.raycast(origin, direction, reach)
	if voxel_hit != null:
		var point := origin + direction * voxel_hit.distance
		return {
			"point": point,
			"distance": voxel_hit.distance,
		}

	return {}


func _update_drill_pose(direction: Vector3, contact: Vector3, has_hit: bool) -> void:
	var rest: Vector3 = _head.global_position + _head.global_transform.basis * Vector3(0.28, -0.22, -0.45)
	if has_hit:
		var tip: Vector3 = contact - direction * 0.08
		_drill_visual.global_position = rest.lerp(tip, 0.55)
		_drill_visual.look_at(tip + direction, Vector3.UP)
	else:
		_drill_visual.global_position = rest
		_drill_visual.rotation = _head.global_rotation


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
