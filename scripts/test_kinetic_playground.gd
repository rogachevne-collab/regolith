extends Node3D

const SKY_PROBE_Y := 120.0
const GROUND_PROBE_MAX_DISTANCE := 200.0
const TERRAIN_RESET_HALF_EXTENT := 18.0
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

var _world_ready := false
var _overlay_visible := false
var _selected_stand := 0
var _stands: Array[Dictionary] = []
var _terrain_surface_y := 0.0


func _ready() -> void:
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
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
	await _wait_for_terrain_ready()
	var spawn_pos := await _settle_player_near_spawn()
	_loading.visible = false
	_world_ready = true
	_player.call("set_spawn_ready", spawn_pos)
	_session.get_industry_simulation().bind_world(_session.world)
	await _spawn_all_stands()
	_refresh_status()


func _process(_delta: float) -> void:
	if not _world_ready or not _overlay_visible:
		return
	_refresh_status()


func _unhandled_input(event: InputEvent) -> void:
	if not _world_ready or not event.is_pressed() or event.is_echo():
		return
	if Input.is_action_just_pressed("playground_toggle_help"):
		_overlay_visible = not _overlay_visible
		_overlay.visible = _overlay_visible
		_status.visible = _overlay_visible
		return
	if Input.is_action_just_pressed("playground_respawn_stands"):
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


func _wait_for_terrain_ready() -> void:
	var tool: VoxelTool = _terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var probe := _base_spawn.global_position + Vector3(0.0, SKY_PROBE_Y * 0.5, 0.0)
	while true:
		var hit: VoxelRaycastResult = tool.raycast(
			probe,
			Vector3.DOWN,
			GROUND_PROBE_MAX_DISTANCE
		)
		if hit != null:
			_terrain_surface_y = probe.y - hit.distance
			return
		_loading.text = "Стриминг террейна..."
		await get_tree().physics_frame


func _settle_player_near_spawn() -> Vector3:
	var target := Vector3(
		_base_spawn.global_position.x + 4.0,
		_terrain_surface_y + 1.8,
		_base_spawn.global_position.z + 6.0
	)
	_player.global_position = target + Vector3.UP * 2.0
	_player.call("begin_spawn_settle", target)
	while _player.has_method("is_spawn_settled") and not _player.is_spawn_settled():
		await get_tree().physics_frame
	return target


func _respawn_stands() -> void:
	_clear_stand_assemblies()
	_stands.clear()
	await _spawn_all_stands()
	_refresh_status()


func _clear_stand_assemblies() -> void:
	for stand: Dictionary in _stands:
		var foundation_id := int(stand.get("foundation_element_id", 0))
		if foundation_id > 0:
			_dismantle_element(foundation_id)


func _dismantle_element(element_id: int) -> void:
	var element := _session.world.get_element(element_id)
	if element == null:
		return
	var command := DismantleElementCommand.new()
	command.element_id = element_id
	command.expected_state_revision = element.state_revision
	command.store_id = "player"
	_session.world.apply_structural_command_now(command)


func _spawn_all_stands() -> void:
	var origin := _base_spawn.global_position
	_stands.append(
		await _spawn_piston_drill_stand(
			"Piston+drill",
			origin + Vector3(0.0, 0.0, 0.0),
			true
		)
	)
	_stands.append(
		await _spawn_piston_wall_stand(
			"Piston→wall",
			origin + Vector3(12.0, 0.0, 0.0)
		)
	)
	_stands.append(
		await _spawn_falling_frame_stand(
			"Fall frame",
			origin + Vector3(24.0, 0.0, 0.0)
		)
	)
	var ram := await _spawn_ram_stands(origin + Vector3(0.0, 0.0, 14.0))
	_stands.append(ram["a"])
	_stands.append(ram["b"])
	_stands.append(
		await _spawn_anchor_stand(
			"Anchor base",
			origin + Vector3(14.0, 0.0, 14.0)
		)
	)
	if _stands.size() > 0:
		_selected_stand = 0


func _spawn_piston_drill_stand(
	label: String,
	world_origin: Vector3,
	tower: bool
) -> Dictionary:
	var assembly := await _spawn_anchored_stack(
		world_origin,
		6 if tower else 1
	)
	if assembly.is_empty():
		return {}
	var assembly_id := int(assembly["assembly_id"])
	var prior := _place_frame(
		assembly_id,
		Vector3i(4, 0, 0),
		int(assembly["topology_revision"])
	)
	if not prior.is_ok():
		return {}
	var piston := _place_piston(assembly_id, Vector3i(5, 0, 0), prior)
	if not piston.is_ok():
		return {}
	_power_piston(int(piston.data["element_id"]))
	var drill := _place_drill_on_head(assembly_id, piston)
	if not drill.is_ok():
		return {}
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
	_power_piston(int(piston.data["element_id"]))
	_project_assembly(assembly_id)
	return _stand_from_piston(label, assembly_id, piston, assembly)


func _spawn_falling_frame_stand(label: String, world_origin: Vector3) -> Dictionary:
	var motion := GridSpawnUtil.motion_from_transform(
		Transform3D(Basis.IDENTITY, world_origin + Vector3(0.0, 4.0, 0.0)),
		false
	)
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
	var left_motion := GridSpawnUtil.motion_from_transform(
		Transform3D(Basis.IDENTITY, origin + Vector3(-3.0, 1.0, 0.0)),
		false
	)
	left_motion.sleeping = true
	var right_motion := GridSpawnUtil.motion_from_transform(
		Transform3D(Basis.IDENTITY, origin + Vector3(3.0, 1.0, 0.0)),
		false
	)
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
	var basis := GridSpawnUtil.terrain_basis(Vector3.RIGHT, Vector3.BACK)
	var transform := GridSpawnUtil.transform_on_terrain(
		world_origin + Vector3(0.0, _terrain_surface_y, 0.0),
		basis,
		0.0
	)
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


func _power_piston(base_element_id: int) -> void:
	var runtime := _session.world.ensure_industry_element_runtime(base_element_id)
	runtime.machine_enabled = true
	runtime.powered = true
	_weld_element(base_element_id)


func _place_drill_on_head(
	assembly_id: int,
	piston: StructuralCommandResult
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = int(piston.data["topology_revision"])
	place.archetype = Slice01Archetypes.stationary_drill()
	place.origin_cell = Vector3i(6, 1, 0)
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
	for _frame: int in range(4):
		await get_tree().physics_frame


func _latest_revision(assembly_id: int) -> int:
	var assembly := _session.world.get_assembly_raw(assembly_id)
	if assembly == null:
		return 0
	return assembly.topology_revision


func _drive_selected_piston(speed_mps: float) -> void:
	var stand := _selected_stand_record()
	if stand.is_empty() or stand.get("kind") != "piston":
		return
	var command := SetActuatorTargetCommand.new()
	command.joint_id = int(stand.get("joint_id", 0))
	command.mode = SimulationMotorState.ControlMode.VELOCITY
	command.target_velocity_mps = speed_mps
	command.speed_limit_mps = maxf(absf(speed_mps), 0.25)
	command.enabled = true
	_session.apply_set_actuator_target(command)


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
	var tool: VoxelTool = _terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var center := _base_spawn.global_position
	var min_corner := center - Vector3.ONE * TERRAIN_RESET_HALF_EXTENT
	var max_corner := center + Vector3.ONE * TERRAIN_RESET_HALF_EXTENT
	var min_cell := Vector3i(
		floori(min_corner.x),
		floori(min_corner.y - 2.0),
		floori(min_corner.z)
	)
	var max_cell := Vector3i(
		ceili(max_corner.x),
		ceili(max_corner.y + 2.0),
		ceili(max_corner.z)
	)
	for z: int in range(min_cell.z, max_cell.z + 1):
		for x: int in range(min_cell.x, max_cell.x + 1):
			for y: int in range(min_cell.y, max_cell.y + 1):
				var world_point := Vector3(float(x), float(y), float(z))
				tool.set_voxel_f(
					Vector3i(x, y, z),
					world_point.y - _terrain_surface_y
				)


func _selected_stand_record() -> Dictionary:
	if _selected_stand < 0 or _selected_stand >= _stands.size():
		return {}
	return _stands[_selected_stand]


func _refresh_status() -> void:
	if not _overlay_visible:
		return
	var lines: PackedStringArray = PackedStringArray([
		"Kinetic Playground — H скрыть/показать",
		"F1–F5 выбор стенда | +/- пистон | L slam | Y стоп",
		"J сбросить frame | K таран | U terrain | P respawn",
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
