extends Node3D

const FLAT_SURFACE_Y := 0.0
const FLAT_HALF_EXTENT := 40.0
const DROP_HEIGHT_M := 14.0
const DROP_DOWN_IMPULSE_SPEED := 1600.0
const RAM_LAUNCH_SPEED := 11.0

@onready var _terrain: VoxelTerrain = $VoxelTerrain
@onready var _player: Node3D = $Player
@onready var _session: SimulationSession = $SimulationSession
@onready var _base_spawn: Node3D = $BaseSpawn
@onready var _loading: Label = $CanvasLayer/Loading
@onready var _overlay: Label = $CanvasLayer/PlaygroundOverlay
@onready var _status: Label = $CanvasLayer/PlaygroundStatus

var _world_ready := false
var _overlay_visible := true
var _drop_assembly_id := 0
var _drop_released := false
var _ram_ids: Array[int] = []
var _status_hint := ""
var _status_hint_until_msec := 0


func _ready() -> void:
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		_session.world.get_archetype_registry().register(archetype)
	_session.world.ensure_resource_store("player")
	_session.world.set_resource_amount("player", "construction_component", 200.0)
	_loading.visible = true
	_overlay.visible = false
	_status.visible = false
	if _player.has_method("set_spawn_locked"):
		_player.set_spawn_locked(true)
	call_deferred("_boot_playground")


func _boot_playground() -> void:
	await _ensure_flat_playground()
	_session.get_industry_simulation().bind_world(_session.world)
	await _spawn_demos()
	_place_player_facing_drop()
	_loading.text = (
		"Оранжевая рама парит впереди. J — отпустить (реальная физика, g=1.62)."
	)
	_loading.visible = true
	await get_tree().create_timer(4.0).timeout
	_loading.visible = false
	_world_ready = true
	_overlay_visible = true
	_overlay.visible = true
	_status.visible = true
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
		_respawn_demos()
		return
	if Input.is_action_just_pressed("playground_reset_terrain"):
		_seed_flat_plateau(FLAT_SURFACE_Y)
		_flash_hint("Земля залита")
		return
	if Input.is_action_just_pressed("playground_drop_frame"):
		_drop_frame()
		return
	if Input.is_action_just_pressed("playground_ram_launch"):
		_launch_ram()


func _ensure_flat_playground() -> void:
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = FLAT_SURFACE_Y
	_terrain.generator = generator
	_seed_flat_plateau(FLAT_SURFACE_Y)
	for _i: int in range(12):
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


func _spawn_demos() -> void:
	_drop_assembly_id = 0
	_drop_released = false
	_ram_ids.clear()
	await _clear_assemblies()
	var origin := _base_spawn.global_position
	if not await _spawn_drop_frame(origin + Vector3(5.0, 0.0, 0.0)):
		push_error("Kinetic playground: drop frame failed")
	await _spawn_ram_pair(origin + Vector3(0.0, 0.0, 8.0))
	_session.visuals.rebuild_all()
	_session.piston_visuals.rebuild_all()
	for _i: int in range(6):
		await get_tree().physics_frame


func _spawn_drop_frame(world_pos: Vector3) -> bool:
	var spawn_transform := Transform3D(
		Basis.IDENTITY,
		world_pos + Vector3.UP * DROP_HEIGHT_M
	)
	var motion := GridSpawnUtil.motion_from_transform(spawn_transform, false)
	motion.linear_velocity = Vector3.ZERO
	motion.angular_velocity = Vector3.ZERO
	motion.sleeping = true
	motion.frozen = true
	var spawn := _spawn_blueprint(
		_single_frame_blueprint(),
		GridSpawnUtil.grid_frame_from_transform(motion.transform)
	)
	if not spawn.is_ok():
		return false
	var assembly_id := int(spawn.data["assembly_id"])
	_weld_assembly(assembly_id)
	await _finalize_assembly(assembly_id, motion)
	if not _hold_assembly_physics(assembly_id):
		return false
	_drop_assembly_id = assembly_id
	return true


func _spawn_ram_pair(origin: Vector3) -> void:
	for offset_x: float in [-3.0, 3.0]:
		var spawn_transform := Transform3D(
			Basis.IDENTITY,
			origin + Vector3(offset_x, 2.0, 0.0)
		)
		var motion := GridSpawnUtil.motion_from_transform(spawn_transform, false)
		motion.linear_velocity = Vector3.ZERO
		motion.angular_velocity = Vector3.ZERO
		motion.sleeping = true
		motion.frozen = true
		var spawn := _spawn_blueprint(
			_single_frame_blueprint(),
			GridSpawnUtil.grid_frame_from_transform(motion.transform)
		)
		if not spawn.is_ok():
			continue
		var assembly_id := int(spawn.data["assembly_id"])
		_weld_assembly(assembly_id)
		await _finalize_assembly(assembly_id, motion)
		if not _hold_assembly_physics(assembly_id):
			continue
		_ram_ids.append(assembly_id)


func _finalize_assembly(
	assembly_id: int,
	motion: AssemblyMotionState = null
) -> void:
	_session.projection.project_assembly_now(assembly_id, motion)
	for _i: int in range(4):
		await get_tree().physics_frame
	_session.visuals.rebuild_assembly(assembly_id)


func _weld_assembly(assembly_id: int) -> void:
	var assembly := _session.world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	for element_id: int in assembly.element_ids:
		var element := _session.world.get_element(element_id)
		if element == null or element.is_complete():
			continue
		var weld := WeldElementCommand.new()
		weld.element_id = element_id
		weld.expected_state_revision = element.state_revision
		weld.max_material_amount = 100.0
		weld.store_id = "player"
		_session.world.apply_structural_command_now(weld)


func _hold_assembly_physics(assembly_id: int) -> bool:
	var body := _session.projection.get_physics_body(assembly_id) as RigidBody3D
	if body == null:
		return false
	body.mass = maxf(body.mass, 180.0)
	body.freeze = true
	body.sleeping = true
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	_session.projection.sync_body_motion_now(assembly_id)
	return true


func _release_assembly_physics(
	assembly_id: int,
	initial_velocity: Vector3 = Vector3.ZERO
) -> bool:
	var body := _session.projection.get_physics_body(assembly_id) as RigidBody3D
	if body == null:
		return false
	body.freeze = false
	body.sleeping = false
	if not initial_velocity.is_zero_approx():
		body.linear_velocity = initial_velocity
	_session.projection.sync_body_motion_now(assembly_id)
	return true


func _place_player_facing_drop() -> void:
	var look_at := _base_spawn.global_position + Vector3(
		5.0,
		DROP_HEIGHT_M * 0.5,
		0.0
	)
	var spawn := _base_spawn.global_position + Vector3(2.0, FLAT_SURFACE_Y + 1.8, -2.0)
	_player.global_position = spawn
	if _player.has_method("set_spawn_ready"):
		_player.call("set_spawn_ready", spawn)
	_player.look_at(Vector3(look_at.x, spawn.y, look_at.z), Vector3.UP)


func _drop_frame() -> void:
	if _drop_assembly_id <= 0:
		_flash_hint("Рама не заспавнилась — P")
		return
	if _drop_released:
		_flash_hint("Уже брошена — P переспавн")
		return
	if not _release_assembly_physics(_drop_assembly_id):
		_flash_hint("Нет RigidBody — P переспавн")
		return
	var body := _session.projection.get_physics_body(
		_drop_assembly_id
	) as RigidBody3D
	if body != null:
		body.apply_central_impulse(
			Vector3.DOWN * body.mass * DROP_DOWN_IMPULSE_SPEED
		)
		_session.projection.sync_body_motion_now(_drop_assembly_id)
	_drop_released = true
	_flash_hint(
		"Пинок вниз %.0f м/с + падение с %.0f м"
		% [DROP_DOWN_IMPULSE_SPEED, DROP_HEIGHT_M]
	)


func _launch_ram() -> void:
	if _ram_ids.is_empty():
		_flash_hint("Таран не заспавнился — P")
		return
	var launched := false
	for index: int in range(_ram_ids.size()):
		var dir := Vector3.RIGHT if index == 0 else Vector3.LEFT
		if _release_assembly_physics(
			_ram_ids[index],
			dir * RAM_LAUNCH_SPEED
		):
			launched = true
	if launched:
		_flash_hint("Таран!")
	else:
		_flash_hint("Нет тел для тарана")


func _respawn_demos() -> void:
	_world_ready = false
	_loading.text = "Переспавн..."
	_loading.visible = true
	await _spawn_demos()
	_place_player_facing_drop()
	_drop_released = false
	_loading.visible = false
	_world_ready = true
	_flash_hint("Готово. J — бросок рамы.")


func _clear_assemblies() -> void:
	var guard := 0
	while guard < 128:
		guard += 1
		var pending := false
		for assembly: SimulationAssembly in _session.world.list_assemblies():
			if assembly.tombstoned or assembly.element_ids.is_empty():
				continue
			pending = true
			var command := DismantleElementCommand.new()
			command.element_id = int(assembly.element_ids[0])
			command.expected_assembly_revision = assembly.topology_revision
			command.store_id = "player"
			_session.world.apply_structural_command_now(command)
			break
		if not pending:
			break
	_session.projection.rebuild_all()
	for _i: int in range(6):
		await get_tree().physics_frame


func _spawn_blueprint(
	blueprint: Blueprint,
	grid_frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = grid_frame
	return _session.world.apply_structural_command_now(command)


func _single_frame_blueprint() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"kinetic_playground_frame",
		[
			_placement(
				"element_0",
				Slice01Archetypes.frame(),
				Vector3i.ZERO
			)
		]
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


func _flash_hint(text: String) -> void:
	_status_hint = text
	_status_hint_until_msec = Time.get_ticks_msec() + 3000


func _integrity_percent(assembly_id: int) -> float:
	if assembly_id <= 0:
		return 0.0
	var assembly := _session.world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.element_ids.is_empty():
		return 0.0
	var element := _session.world.get_element(int(assembly.element_ids[0]))
	if element == null:
		return 0.0
	return element.structural_fraction() * 100.0


func _refresh_status() -> void:
	var drop_body := _session.projection.get_physics_body(_drop_assembly_id)
	var drop_speed := 0.0
	var body_kind := "none"
	if drop_body is RigidBody3D:
		var rigid := drop_body as RigidBody3D
		drop_speed = rigid.linear_velocity.length()
		body_kind = "rigid frozen=%s" % rigid.freeze
	elif drop_body is StaticBody3D:
		body_kind = "static (!)"
	_overlay.text = """Kinetic playground — удары, не пистон
J — пинок рамы вниз (%.0f м/с) + удар о землю
K — таран двух рам сзади
P — переспавн | U — залить землю | H — скрыть

Оранжевая рама впереди = J. Две рамы сзади = K.""" % DROP_DOWN_IMPULSE_SPEED
	if (
		not _status_hint.is_empty()
		and Time.get_ticks_msec() < _status_hint_until_msec
	):
		_status.text = _status_hint
	else:
		_status_hint = ""
		var carve_m3 := 0.0
		if _session != null and _session.impact_service != null:
			carve_m3 = _session.impact_service.last_terrain_carve_m3
		_status.text = "drop |v|=%.1f int=%.0f%% carve=%.3fm³ %s" % [
			drop_speed,
			_integrity_percent(_drop_assembly_id),
			carve_m3,
			body_kind,
		]
