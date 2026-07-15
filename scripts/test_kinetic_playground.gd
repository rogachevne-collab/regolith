extends Node3D

const SKY_PROBE_Y := 120.0
const GROUND_PROBE_MAX_DISTANCE := 200.0
const FLAT_SURFACE_Y := 0.0
const FLAT_HALF_EXTENT := 40.0
const TERRAIN_RESET_HALF_EXTENT := FLAT_HALF_EXTENT
const SLAM_SPEED_MPS := 2.5
const SLOW_SPEED_MPS := 0.2

const PISTON_BASE := preload(
	"res://resources/archetypes/slice01/piston_base.tres"
)
const PISTON_HEAD := preload(
	"res://resources/archetypes/slice01/piston_head.tres"
)

@onready var _terrain: VoxelTerrain = $VoxelTerrain
@onready var _player: Node3D = $Player
@onready var _session: SimulationSession = $SimulationSession
@onready var _base_spawn: Node3D = $BaseSpawn
@onready var _loading: Label = $CanvasLayer/Loading
@onready var _overlay: Label = $CanvasLayer/PlaygroundOverlay
@onready var _status: Label = $CanvasLayer/PlaygroundStatus

var _marker_root: Node3D
var _world_ready := false
var _overlay_visible := false
var _selected_stand := 0
var _stands: Array[Dictionary] = []
var _terrain_surface_y := 0.0
var _respawn_busy := false
var _status_hint := ""
var _status_hint_until_msec := 0


func _ready() -> void:
	_marker_root = Node3D.new()
	_marker_root.name = "StandMarkers"
	add_child(_marker_root)
	process_physics_priority = 1
	_session.projection.process_physics_priority = 2
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	_session.world.ensure_resource_store("player")
	_session.world.set_resource_amount("player", "construction_component", 500.0)
	_loading.visible = true
	_overlay.visible = false
	_status.visible = false
	if _player.has_method("set_spawn_locked"):
		_player.set_spawn_locked(true)
	_player.global_position = Vector3(
		_base_spawn.global_position.x + 4.0,
		SKY_PROBE_Y,
		_base_spawn.global_position.z + 6.0
	)
	call_deferred("_boot_playground")


func _boot_playground() -> void:
	await _ensure_flat_playground()
	var spawn_pos := await _settle_player_near_spawn()
	_loading.visible = false
	_world_ready = true
	_player.call("set_spawn_ready", spawn_pos)
	_session.get_industry_simulation().bind_world(_session.world)
	await _spawn_all_stands()
	_place_player_near_stands()
	_show_spawn_banner()
	_refresh_status()


func _show_spawn_banner() -> void:
	if _stands.is_empty():
		_loading.text = "Стенды не заспавнились — см. Output. P — повтор."
		_loading.visible = true
		push_error("Kinetic playground: all stand spawns failed")
		return
	_loading.text = (
		"Стенды: %d. F1 — пистон, L — удар. H — подсказки."
		% _stands.size()
	)
	_loading.visible = true
	await get_tree().create_timer(4.0).timeout
	_loading.visible = false
	_overlay_visible = true
	_overlay.visible = true
	_status.visible = true


func _physics_process(_delta: float) -> void:
	if not _world_ready:
		return
	_keep_piston_stands_powered()


func _process(_delta: float) -> void:
	if not _world_ready or not _overlay_visible:
		return
	_refresh_status()


func _keep_piston_stands_powered() -> void:
	for stand: Dictionary in _stands:
		if stand.get("kind") != "piston":
			continue
		var base_id := int(stand.get("base_element_id", 0))
		if base_id <= 0:
			continue
		var runtime := _session.world.ensure_industry_element_runtime(base_id)
		runtime.machine_enabled = true
		runtime.powered = true
		runtime.power_reason = &"playground_override"


func _unhandled_input(event: InputEvent) -> void:
	if not _world_ready or not event.is_pressed() or event.is_echo():
		return
	if Input.is_action_just_pressed("playground_toggle_help"):
		_overlay_visible = not _overlay_visible
		_overlay.visible = _overlay_visible
		_status.visible = _overlay_visible
		return
	if Input.is_action_just_pressed("playground_respawn_stands"):
		if not _respawn_busy:
			_respawn_stands()
		return
	if Input.is_action_just_pressed("playground_reset_terrain"):
		_reset_terrain_patch()
		return
	if Input.is_action_just_pressed("playground_drop_frame"):
		_drop_falling_frame()
		return
	if Input.is_action_just_pressed("playground_ram_launch"):
		_launch_ram_assemblies()
		return
	for index: int in range(5):
		if Input.is_action_just_pressed("playground_select_%d" % (index + 1)):
			_selected_stand = index
			_refresh_status()
			return
	if Input.is_action_just_pressed("actuator_extend"):
		_drive_selected_piston(SLOW_SPEED_MPS)
	elif Input.is_action_just_pressed("actuator_retract"):
		_drive_selected_piston(-SLOW_SPEED_MPS)
	elif Input.is_action_just_pressed("playground_piston_slam"):
		_drive_selected_piston(SLAM_SPEED_MPS)
	elif Input.is_action_just_pressed("actuator_stop"):
		_stop_selected_piston()


func _ensure_flat_playground() -> void:
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = FLAT_SURFACE_Y
	_terrain.generator = generator
	await _seed_flat_plateau(FLAT_SURFACE_Y)
	_terrain_surface_y = FLAT_SURFACE_Y
	_loading.text = "Ровная площадка..."
	for _frame: int in range(12):
		await get_tree().physics_frame


func _seed_flat_plateau(surface_y: float) -> void:
	var block_size := _terrain.get_data_block_size()
	var blocks_span := int(ceil(FLAT_HALF_EXTENT / float(block_size))) + 1
	for bx: int in range(-blocks_span, blocks_span + 1):
		for bz: int in range(-blocks_span, blocks_span + 1):
			for by: int in range(-1, 2):
				_seed_flat_block(Vector3i(bx, by, bz), surface_y)


func _seed_flat_block(block_pos: Vector3i, surface_y: float) -> void:
	var block_size := _terrain.get_data_block_size()
	var buffer := VoxelBuffer.new()
	buffer.create(block_size, block_size, block_size)
	var block_origin := _terrain.data_block_to_voxel(block_pos)
	for z: int in range(block_size):
		for x: int in range(block_size):
			for y: int in range(block_size):
				var world_y := float(block_origin.y + y)
				buffer.set_voxel_f(
					world_y - surface_y,
					x,
					y,
					z,
					VoxelBuffer.CHANNEL_SDF
				)
	_terrain.try_set_block_data(block_pos, buffer)


func _ground_point_at(xz: Vector2, _tool: VoxelTool = null) -> Vector3:
	return Vector3(xz.x, FLAT_SURFACE_Y, xz.y)


func _spawn_transform_at(world_offset: Vector3) -> Transform3D:
	var pos := _base_spawn.global_position + world_offset
	pos.y = FLAT_SURFACE_Y
	return Transform3D(Basis.IDENTITY, pos)


func _place_player_near_stands() -> void:
	var xz := Vector2(
		_base_spawn.global_position.x + 6.0,
		_base_spawn.global_position.z + 4.0
	)
	var target := _ground_point_at(xz) + Vector3.UP * 1.8
	if _player.has_method("set_spawn_ready"):
		_player.call("set_spawn_ready", target)
	else:
		_player.global_position = target


func _settle_player_near_spawn() -> Vector3:
	var xz := Vector2(
		_base_spawn.global_position.x + 4.0,
		_base_spawn.global_position.z + 6.0
	)
	var target := _ground_point_at(xz) + Vector3.UP * 1.8
	_player.global_position = target + Vector3.UP * 2.0
	_player.call("begin_spawn_settle", target)
	while _player.has_method("is_spawn_settled") and not _player.is_spawn_settled():
		await get_tree().physics_frame
	return target


func _respawn_stands() -> void:
	if _respawn_busy:
		return
	_respawn_busy = true
	_clear_markers()
	await _clear_playground_assemblies()
	_stands.clear()
	await _spawn_all_stands()
	_place_player_near_stands()
	_show_spawn_banner()
	_respawn_busy = false
	_refresh_status()


func _clear_playground_assemblies() -> void:
	var guard := 0
	while guard < 128:
		guard += 1
		var pending := false
		for assembly: SimulationAssembly in _session.world.list_assemblies():
			if assembly.tombstoned or assembly.element_ids.is_empty():
				continue
			pending = true
			_dismantle_element(int(assembly.element_ids[0]))
			break
		if not pending:
			break
	for _frame: int in range(8):
		await get_tree().physics_frame


func _dismantle_element(element_id: int) -> bool:
	var element := _session.world.get_element(element_id)
	if element == null:
		return false
	var assembly := _session.world.get_assembly_raw(element.assembly_id)
	if assembly == null or assembly.tombstoned:
		return false
	var command := DismantleElementCommand.new()
	command.element_id = element_id
	command.expected_assembly_revision = assembly.topology_revision
	command.store_id = "player"
	var result := _session.world.apply_structural_command_now(command)
	return result.is_ok()


func _spawn_all_stands() -> void:
	var origin := _base_spawn.global_position
	_append_stand(
		await _spawn_piston_drill_stand(
			"Piston+drill",
			origin + Vector3(0.0, 0.0, 0.0)
		)
	)
	_append_stand(
		await _spawn_piston_wall_stand(
			"Piston→wall",
			origin + Vector3(12.0, 0.0, 0.0)
		)
	)
	_append_stand(
		await _spawn_falling_frame_stand(
			"Fall frame",
			origin + Vector3(24.0, 0.0, 0.0)
		)
	)
	var ram := await _spawn_ram_stands(origin + Vector3(0.0, 0.0, 14.0))
	_append_stand(ram.get("a", {}))
	_append_stand(ram.get("b", {}))
	_append_stand(
		await _spawn_anchor_stand(
			"Anchor base",
			origin + Vector3(14.0, 0.0, 14.0)
		)
	)
	_select_first_piston_stand()


func _select_first_piston_stand() -> void:
	for index: int in range(_stands.size()):
		if _stands[index].get("kind") == "piston":
			_selected_stand = index
			return
	if _stands.size() > 0:
		_selected_stand = 0


func _append_stand(stand: Dictionary) -> void:
	if stand.is_empty():
		push_warning("Kinetic playground: stand spawn failed")
		return
	_stands.append(stand)
	_add_stand_marker(stand)


func _add_stand_marker(stand: Dictionary) -> void:
	var assembly_id := int(stand.get("assembly_id", 0))
	var body := _session.projection.get_physics_body(assembly_id)
	var marker_pos := _base_spawn.global_position
	if body != null:
		marker_pos = body.global_position
	var pillar := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.height = 8.0
	mesh.top_radius = 0.2
	mesh.bottom_radius = 0.2
	pillar.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.35, 0.1)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.45, 0.1)
	material.emission_energy_multiplier = 2.0
	pillar.material_override = material
	pillar.position = marker_pos + Vector3.UP * 4.0
	_marker_root.add_child(pillar)


func _clear_markers() -> void:
	if _marker_root == null:
		return
	for child: Node in _marker_root.get_children():
		child.queue_free()


func _spawn_piston_drill_stand(
	label: String,
	world_origin: Vector3
) -> Dictionary:
	const TOWER_FRAMES := 3
	var assembly := await _spawn_anchored_stack(world_origin, TOWER_FRAMES)
	if assembly.is_empty():
		return {}
	var assembly_id := int(assembly["assembly_id"])
	var piston_cell := Vector3i(4, TOWER_FRAMES, 0)
	var prior := StructuralCommandResult.ok({
		"topology_revision": _latest_revision(assembly_id),
	})
	var piston := _place_piston(assembly_id, piston_cell, prior)
	if not piston.is_ok():
		return {}
	_power_piston(
		int(piston.data["element_id"]),
		int(piston.data["head_element_id"])
	)
	var head_cell := PistonPlacementUtil.head_origin_cell(
		piston_cell,
		0,
		PISTON_BASE.piston_definition
	)
	var drill := _place_drill_on_head(assembly_id, piston, head_cell)
	if not drill.is_ok():
		push_warning(
			"Kinetic playground: drill placement failed: %s"
			% drill.reason
		)
	_project_assembly(assembly_id)
	return _stand_from_piston(label, assembly_id, piston, assembly)


func _spawn_piston_wall_stand(label: String, world_origin: Vector3) -> Dictionary:
	var assembly := await _spawn_anchored_stack(world_origin, 1)
	if assembly.is_empty():
		return {}
	var assembly_id := int(assembly["assembly_id"])
	for cell_y: int in range(1, 5):
		var wall := _place_frame(
			assembly_id,
			Vector3i(6, cell_y, 0),
			_latest_revision(assembly_id)
		)
		if not wall.is_ok():
			break
	var prior := _place_frame(assembly_id, Vector3i(4, 0, 0), _latest_revision(assembly_id))
	if not prior.is_ok():
		return {}
	var piston := _place_piston(assembly_id, Vector3i(5, 1, 0), prior)
	if not piston.is_ok():
		return {}
	_power_piston(
		int(piston.data["element_id"]),
		int(piston.data["head_element_id"])
	)
	_project_assembly(assembly_id)
	return _stand_from_piston(label, assembly_id, piston, assembly)


func _spawn_falling_frame_stand(label: String, world_origin: Vector3) -> Dictionary:
	var spawn_transform := _spawn_transform_at(world_origin)
	spawn_transform.origin += Vector3.UP * 4.0
	var motion := GridSpawnUtil.motion_from_transform(spawn_transform, false)
	motion.linear_velocity = Vector3.ZERO
	motion.sleeping = true
	var spawn := _spawn_blueprint(
		_single_frame_blueprint(),
		GridSpawnUtil.grid_frame_from_transform(motion.transform)
	)
	if not spawn.is_ok():
		return {}
	var assembly_id := int(spawn.data["assembly_id"])
	_session.projection.project_assembly_now(assembly_id, motion)
	var body := _session.projection.get_physics_body(assembly_id) as RigidBody3D
	if body != null:
		body.freeze = true
	return {
		"label": label,
		"kind": "falling",
		"assembly_id": assembly_id,
		"foundation_element_id": int(spawn.data["element_ids"][0]),
		"released": false,
	}


func _spawn_ram_stands(origin: Vector3) -> Dictionary:
	var left_transform := _spawn_transform_at(origin + Vector3(-3.0, 0.0, 0.0))
	left_transform.origin += Vector3.UP * 1.0
	var right_transform := _spawn_transform_at(origin + Vector3(3.0, 0.0, 0.0))
	right_transform.origin += Vector3.UP * 1.0
	var left_motion := GridSpawnUtil.motion_from_transform(left_transform, false)
	left_motion.sleeping = true
	var right_motion := GridSpawnUtil.motion_from_transform(right_transform, false)
	right_motion.sleeping = true
	var left_spawn := _spawn_blueprint(
		_single_frame_blueprint(),
		GridSpawnUtil.grid_frame_from_transform(left_motion.transform)
	)
	var right_spawn := _spawn_blueprint(
		_single_frame_blueprint(),
		GridSpawnUtil.grid_frame_from_transform(right_motion.transform)
	)
	if not left_spawn.is_ok() or not right_spawn.is_ok():
		return {"a": {}, "b": {}}
	var left_id := int(left_spawn.data["assembly_id"])
	var right_id := int(right_spawn.data["assembly_id"])
	_session.projection.project_assembly_now(left_id, left_motion)
	_session.projection.project_assembly_now(right_id, right_motion)
	for body_id: int in [left_id, right_id]:
		var body := _session.projection.get_physics_body(body_id) as RigidBody3D
		if body != null:
			body.freeze = true
	return {
		"a": {
			"label": "Ram A",
			"kind": "ram",
			"assembly_id": left_id,
			"foundation_element_id": int(left_spawn.data["element_ids"][0]),
			"launch_dir": Vector3.RIGHT,
		},
		"b": {
			"label": "Ram B",
			"kind": "ram",
			"assembly_id": right_id,
			"foundation_element_id": int(right_spawn.data["element_ids"][0]),
			"launch_dir": Vector3.LEFT,
		},
	}


func _spawn_anchor_stand(label: String, world_origin: Vector3) -> Dictionary:
	var assembly := await _spawn_anchored_stack(world_origin, 1)
	if assembly.is_empty():
		return {}
	return {
		"label": label,
		"kind": "anchor",
		"assembly_id": int(assembly["assembly_id"]),
		"foundation_element_id": int(assembly["foundation_element_id"]),
	}


func _spawn_anchored_stack(
	world_origin: Vector3,
	frame_count: int
) -> Dictionary:
	var transform := _spawn_transform_at(world_origin)
	var spawn := _spawn_blueprint(
		_foundation_blueprint(),
		GridSpawnUtil.grid_frame_from_transform(transform)
	)
	if not spawn.is_ok():
		return {}
	var assembly_id := int(spawn.data["assembly_id"])
	var foundation_id := int(spawn.data["element_ids"][0])
	var revision := int(spawn.data["topology_revision"])
	for index: int in range(frame_count):
		var frame := _place_frame(
			assembly_id,
			Vector3i(4, index, 0),
			revision
		)
		if not frame.is_ok():
			break
		revision = int(frame.data["topology_revision"])
	_project_assembly(assembly_id)
	return {
		"assembly_id": assembly_id,
		"foundation_element_id": foundation_id,
		"topology_revision": revision,
	}


func _stand_from_piston(
	label: String,
	assembly_id: int,
	piston: StructuralCommandResult,
	assembly: Dictionary
) -> Dictionary:
	return {
		"label": label,
		"kind": "piston",
		"assembly_id": assembly_id,
		"joint_id": int(piston.data["piston_joint_id"]),
		"base_element_id": int(piston.data["element_id"]),
		"head_element_id": int(piston.data["head_element_id"]),
		"foundation_element_id": int(assembly["foundation_element_id"]),
	}


func _power_piston(base_element_id: int, head_element_id: int = 0) -> void:
	_weld_element(base_element_id)
	if head_element_id > 0:
		_weld_element(head_element_id)


func _place_drill_on_head(
	assembly_id: int,
	piston: StructuralCommandResult,
	head_cell: Vector3i
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(piston.data["topology_revision"])
	place.archetype = Slice01Archetypes.stationary_drill()
	place.origin_cell = head_cell + Vector3i(0, 1, 0)
	place.orientation_index = 0
	place.store_id = "player"
	return _session.world.apply_structural_command_now(place)


func _place_piston(
	assembly_id: int,
	origin_cell: Vector3i,
	prior: StructuralCommandResult
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(prior.data["topology_revision"])
	place.archetype = PISTON_BASE
	place.origin_cell = origin_cell
	place.orientation_index = 0
	place.store_id = "player"
	return _session.world.apply_structural_command_now(place)


func _place_frame(
	assembly_id: int,
	origin_cell: Vector3i,
	revision: int
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = revision
	place.archetype = Slice01Archetypes.frame()
	place.origin_cell = origin_cell
	place.orientation_index = 0
	place.store_id = "player"
	return _session.world.apply_structural_command_now(place)


func _weld_element(element_id: int) -> void:
	var element := _session.world.get_element(element_id)
	if element == null:
		return
	var weld := WeldElementCommand.new()
	weld.element_id = element_id
	weld.expected_state_revision = element.state_revision
	weld.max_material_amount = 100.0
	weld.store_id = "player"
	_session.world.apply_structural_command_now(weld)


func _spawn_blueprint(
	blueprint: Blueprint,
	grid_frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = grid_frame
	return _session.world.apply_structural_command_now(command)


func _project_assembly(assembly_id: int) -> void:
	_session.projection.project_assembly_now(assembly_id, null)
	_session.piston_visuals.rebuild_assembly(assembly_id)
	for _frame: int in range(4):
		await get_tree().physics_frame


func _latest_revision(assembly_id: int) -> int:
	var assembly := _session.world.get_assembly_raw(assembly_id)
	if assembly == null:
		return 0
	return assembly.topology_revision


func _flash_status_hint(text: String, seconds: float = 2.5) -> void:
	_status_hint = text
	_status_hint_until_msec = Time.get_ticks_msec() + int(seconds * 1000.0)
	_status.text = text


func _drive_selected_piston(speed_mps: float) -> void:
	var stand := _selected_stand_record()
	if stand.is_empty():
		_flash_status_hint("Нет стенда — P переспавн")
		return
	if stand.get("kind") != "piston":
		_flash_status_hint("«%s» не пистон — жми F1" % stand.get("label", "?"))
		return
	var command := SetActuatorTargetCommand.new()
	command.joint_id = int(stand.get("joint_id", 0))
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = speed_mps
	command.speed_limit_mps = maxf(absf(speed_mps), 0.25)
	command.enabled = true
	var result := _session.apply_set_actuator_target(command)
	if StringName(result.get("status", &"")) != &"ok":
		_flash_status_hint("Пистон: %s" % str(result.get("reason", "failed")))


func _stop_selected_piston() -> void:
	var stand := _selected_stand_record()
	if stand.is_empty() or stand.get("kind") != "piston":
		return
	var command := SetActuatorTargetCommand.new()
	command.joint_id = int(stand.get("joint_id", 0))
	command.mode = SimulationMotorState.ControlMode.STOP
	_session.apply_set_actuator_target(command)


func _drop_falling_frame() -> void:
	for stand: Dictionary in _stands:
		if stand.get("kind") != "falling" or bool(stand.get("released", false)):
			continue
		var assembly_id := int(stand.get("assembly_id", 0))
		var body := _session.projection.get_physics_body(assembly_id) as RigidBody3D
		if body == null:
			continue
		body.freeze = false
		body.sleeping = false
		stand["released"] = true
		return


func _launch_ram_assemblies() -> void:
	for stand: Dictionary in _stands:
		if stand.get("kind") != "ram":
			continue
		var assembly_id := int(stand.get("assembly_id", 0))
		var body := _session.projection.get_physics_body(assembly_id) as RigidBody3D
		if body == null:
			continue
		body.freeze = false
		body.sleeping = false
		body.linear_velocity = stand.get("launch_dir", Vector3.ZERO) * 4.0


func _reset_terrain_patch() -> void:
	_seed_flat_plateau(FLAT_SURFACE_Y)
	_terrain_surface_y = FLAT_SURFACE_Y


func _selected_stand_record() -> Dictionary:
	if _selected_stand < 0 or _selected_stand >= _stands.size():
		return {}
	return _stands[_selected_stand]


func _refresh_status() -> void:
	if not _overlay_visible:
		return
	var lines: PackedStringArray = PackedStringArray([
		"Kinetic Playground — H скрыть/показать",
		"F1 — пистон (башня у спавна) | = выдвинуть | L удар | Y стоп",
		"J сброс рамы | K таран | U земля | P respawn",
		"",
	])
	for index: int in range(_stands.size()):
		var stand: Dictionary = _stands[index]
		var prefix := ">" if index == _selected_stand else " "
		lines.append("%s%d %s" % [prefix, index + 1, stand.get("label", "?")])
		lines.append(_stand_metrics_line(stand))
	_overlay.text = "\n".join(lines)
	_status.text = _selected_metrics()


func _stand_metrics_line(stand: Dictionary) -> String:
	var kind: String = stand.get("kind", "")
	if kind == "piston":
		return _piston_metrics(stand)
	if kind == "falling":
		return "  released=%s" % str(stand.get("released", false))
	if kind == "ram":
		var body := _session.projection.get_physics_body(
			int(stand.get("assembly_id", 0))
		) as RigidBody3D
		if body == null:
			return "  body=missing"
		return "  |v|=%.2f" % body.linear_velocity.length()
	return "  anchor"


func _selected_metrics() -> String:
	if (
		not _status_hint.is_empty()
		and Time.get_ticks_msec() < _status_hint_until_msec
	):
		return _status_hint
	if (
		not _status_hint.is_empty()
		and Time.get_ticks_msec() >= _status_hint_until_msec
	):
		_status_hint = ""
	var stand := _selected_stand_record()
	if stand.is_empty():
		return ""
	if stand.get("kind") == "piston":
		return "Selected: " + _piston_metrics(stand)
	return ""


func _piston_metrics(stand: Dictionary) -> String:
	var joint := _session.world.get_joint(int(stand.get("joint_id", 0)))
	var head := _session.world.get_element(int(stand.get("head_element_id", 0)))
	if joint == null or joint.motor == null:
		return "  motor=missing"
	var motor: SimulationMotorState = joint.motor
	var j_sustained := motor.applied_force_n * (1.0 / 60.0)
	var integrity := head.integrity if head != null else -1.0
	return (
		"  F=%.0fN sat=%s J_dt=%.1f int=%.0f status=%s"
		% [
			motor.applied_force_n,
			str(motor.force_saturated),
			j_sustained,
			integrity,
			SimulationMotorState.Status.keys()[motor.status],
		]
	)


func _foundation_blueprint() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"kinetic_playground_foundation",
		[_placement("element_0", Slice01Archetypes.foundation(), Vector3i.ZERO)]
	)


func _single_frame_blueprint() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"kinetic_playground_frame",
		[_placement("element_0", Slice01Archetypes.frame(), Vector3i.ZERO)]
	)


func _placement(
	local_id: String,
	archetype: ElementArchetype,
	cell: Vector3i
) -> BlueprintElementPlacement:
	var placement := BlueprintElementPlacement.new()
	placement.local_id = local_id
	placement.archetype = archetype
	placement.origin_cell = cell
	return placement
