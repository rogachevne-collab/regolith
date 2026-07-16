extends Node3D

## Moon experiment entry — spherical VoxelLodTerrain + radial Field.
## Parity wiring with main; spawn probes follow GravityField, not world −Y.

const MIN_WARMUP_FRAMES := 30
const MAX_SPAWN_SETTLE_FRAMES := 180
const BASE_SPAWN_TIMEOUT_MS := 60000
const AUTOSAVE_INTERVAL_S := 90.0

@onready var _terrain: Node3D = $VoxelTerrain
@onready var _player: Node3D = $Player
@onready var _session: SimulationSession = $SimulationSession
@onready var _base_spawn: Node3D = $BaseSpawn
@onready var _gravity_field: GravityField = $GravityField
@onready var _loading: Label = $CanvasLayer/Loading
@onready var _coordinates: Label = $CanvasLayer/Coordinates
@onready var _hint: Label = $CanvasLayer/Hint

@export var debug_overlay := false
@export var playtest_cargo := true
## Enable after radial rover seating (phase 6). Off for early shell bring-up.
@export var spawn_demo_rover := true
@export var demo_rover_phrase := "колбаса на 12 колес, низкая"
@export var persist_digs := true

var _warmup_frames := 0
var _player_spawn_hint := Vector3.UP
var _player_spawn_pos := Vector3.ZERO
var _world_ready := false
var _autosave_accum := 0.0
var _last_save_ms := 0
var _save_load_attempted := false
var _voxel_stream: VoxelStream


func is_world_ready() -> bool:
	return _world_ready


func _ready() -> void:
	WorldPersistence.save_path_override = MoonGeometry.world_save_path()
	_configure_terrain()
	_configure_dig_stream()
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	_loading.visible = true
	_coordinates.visible = debug_overlay
	_hint.visible = debug_overlay
	var gateway := get_node_or_null("WorldCommandGateway")
	if gateway != null and gateway.has_signal("terrain_modified"):
		gateway.terrain_modified.connect(_on_terrain_modified)
	_player_spawn_hint = _player.global_position
	if _player_spawn_hint.length_squared() <= 0.000001:
		_player_spawn_hint = Vector3.UP
	if _player.has_method("set_spawn_locked"):
		_player.set_spawn_locked(true)
	_player.global_position = MoonGeometry.spawn_hold_point(_player_spawn_hint)
	_place_when_ground_exists()


func _process(delta: float) -> void:
	if _world_ready:
		_autosave_accum += delta
		if _autosave_accum >= AUTOSAVE_INTERVAL_S:
			_autosave_accum = 0.0
			_persist_world()
	if not debug_overlay:
		return
	var player_position: Vector3 = _player.global_position
	_coordinates.text = (
		"Игрок:  %.1f, %.1f, %.1f"
	) % [
		player_position.x,
		player_position.y,
		player_position.z,
	]


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_persist_world(true)
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		_persist_world(true)


func _exit_tree() -> void:
	_persist_world(true)
	WorldPersistence.save_path_override = ""


func _configure_terrain() -> void:
	if not TerrainCompat.is_terrain(_terrain):
		push_error("Moon experiment terrain node is not VoxelTerrain/VoxelLodTerrain")
		return
	if _terrain is VoxelLodTerrain:
		var lod := _terrain as VoxelLodTerrain
		lod.generator = MoonSphereGeneratorFactory.create()
		lod.voxel_bounds = MoonGeometry.voxel_bounds_aabb()
		lod.view_distance = MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS
		lod.generate_collisions = true
	_terrain.scale = Vector3.ONE * MoonGeometry.VOXEL_SCALE


func _configure_dig_stream() -> void:
	if not persist_digs or not (_terrain is VoxelLodTerrain):
		return
	var dir := MoonGeometry.dig_stream_directory()
	var abs_dir := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)
	## RegionFiles + save_generator_output freezes generated SDF as chunks stream
	## in (do not enable full_load_mode — RegionFiles rejects it).
	var stream := VoxelStreamRegionFiles.new()
	stream.directory = dir
	stream.save_generator_output = true
	_voxel_stream = stream
	(_terrain as VoxelLodTerrain).stream = stream
	if _terrain is VoxelLodTerrain:
		(_terrain as VoxelLodTerrain).full_load_mode_enabled = false
	var version_path := "%s/generator_version.txt" % abs_dir
	var vf := FileAccess.open(version_path, FileAccess.WRITE)
	if vf != null:
		vf.store_string(str(MoonTerrainParams.GENERATOR_VERSION))
		vf.close()
	print(
		"MoonExperiment: stream regions=%s save_generator_output=true gen_v%d"
		% [dir, MoonTerrainParams.GENERATOR_VERSION]
	)


func _persist_world(force := false) -> void:
	if not _world_ready or _session == null:
		return
	if (
		_player == null
		or not is_instance_valid(_player)
		or not _player.is_inside_tree()
	):
		return
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - _last_save_ms < 5000:
		return
	if WorldPersistence.save(_session.world, _player):
		_last_save_ms = now_ms
	_persist_digs()


func _persist_digs() -> void:
	if not persist_digs or not (_terrain is VoxelLodTerrain):
		return
	var lod := _terrain as VoxelLodTerrain
	lod.save_modified_blocks()
	if _voxel_stream != null:
		_voxel_stream.flush()


func _on_terrain_modified(_removed_volume_m3: float) -> void:
	_persist_digs()


func _begin_fresh_world(player_position: Vector3) -> void:
	if not IndustryStoreService.seed_player_starter_resources(_session.world):
		push_error("Fresh world player starter resources seed failed")
	await _finish_world_entry(player_position)
	_spawn_base_when_terrain_ready()


func _finish_world_entry(player_position: Vector3) -> void:
	_player.call("begin_spawn_settle", player_position)
	_loading.text = "Посадка..."
	var settle_frames := 0
	while not _player.call("is_spawn_settled"):
		await get_tree().physics_frame
		settle_frames += 1
		if settle_frames >= MAX_SPAWN_SETTLE_FRAMES:
			push_warning(
				"Spawn settle timed out; releasing player at current position."
			)
			_player.call("set_spawn_ready", _player.global_position)
			break
	_loading.visible = false
	_world_ready = true
	print(
		"MoonExperiment: world_ready player=%s"
		% str(_player.global_position)
	)
	_resync_player_camera()
	_session.get_industry_simulation().bind_world(_session.world)
	_apply_playtest_cargo_if_enabled()
	if spawn_demo_rover:
		call_deferred("_spawn_demo_rover_near_player")


func _finish_loaded_world_entry(spawn_position: Vector3) -> void:
	_player.call("set_spawn_ready", spawn_position)
	_resync_player_camera()
	_loading.visible = false
	_world_ready = true
	print(
		"MoonExperiment: world_ready (loaded) player=%s"
		% str(spawn_position)
	)
	_session.get_industry_simulation().bind_world(_session.world)
	_apply_playtest_cargo_if_enabled()


func _apply_playtest_cargo_if_enabled() -> void:
	if not playtest_cargo or _session == null or _session.world == null:
		return
	if not IndustryStoreService.apply_playtest_cargo(_session.world):
		push_error("Playtest cargo seed failed")


func _spawn_demo_rover_near_player() -> void:
	if _session == null or _base_spawn == null:
		return
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
	if tool == null:
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var ground_variant: Variant = RoverDemoSpawn.find_flat_ground_near(
		_terrain,
		tool,
		_physics_space_state(),
		_base_spawn.global_position
	)
	if not ground_variant is Vector3:
		push_warning("Demo rover spawn failed: no flat ground near BaseSpawn")
		return
	var ground := ground_variant as Vector3
	var result: Dictionary
	if demo_rover_phrase.strip_edges().is_empty():
		result = RoverDemoSpawn.spawn_on_terrain(
			_session,
			ground,
			RoverDemoSpawn.STORE_ID,
			_terrain,
			tool,
			_physics_space_state()
		)
	else:
		result = RoverComposer.spawn_on_terrain_from_phrase(
			_session,
			ground,
			demo_rover_phrase,
			RoverDemoSpawn.STORE_ID,
			_terrain,
			tool,
			_physics_space_state()
		)
	if not bool(result.get("ok", false)):
		push_warning(
			"Demo rover spawn failed: %s %s"
			% [str(result.get("error", "unknown")), str(result.get("failures", []))]
		)
	else:
		print(
			"MoonExperiment: demo rover spawned assembly_id=%d at %s"
			% [int(result.get("assembly_id", 0)), str(ground)]
		)


func _resync_player_camera() -> void:
	var head: Camera3D = _player.get_node_or_null("Camera") as Camera3D
	if head != null and head.has_method("snap_after_teleport"):
		head.call("snap_after_teleport")


func _finalize_loaded_world_after_entry() -> void:
	if not _world_ready:
		return
	WorldPersistence.finalize_loaded_world(_session.world)
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
	if tool == null:
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	RoverDemoSpawn.reseat_parked_locomotives(
		_session,
		_terrain,
		tool,
		_physics_space_state()
	)


func _place_when_ground_exists() -> void:
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var probe_origin := MoonGeometry.spawn_hold_point(_player_spawn_hint)
	var probe_dir := _gravity_field.probe_direction_toward_ground(probe_origin)

	while true:
		if _warmup_frames < MIN_WARMUP_FRAMES:
			_warmup_frames += 1
			var pct: int = int(
				float(_warmup_frames) / float(MIN_WARMUP_FRAMES) * 100.0
			)
			_loading.text = "Загрузка луны... %d%%" % pct
			await get_tree().process_frame
			continue

		var player_hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
			tool,
			_terrain,
			probe_origin,
			probe_dir,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if player_hit != null:
			if WorldPersistence.has_save() and not _save_load_attempted:
				_save_load_attempted = true
				_loading.text = "Загрузка сохранения..."
				await get_tree().process_frame
				var payload: Dictionary = WorldPersistence.read_payload()
				var simulation: Variant = payload.get("simulation", {})
				if (
					not payload.is_empty()
					and simulation is Dictionary
					and WorldPersistence.restore_snapshot_data(
						_session.world,
						simulation
					)
				):
					var spawn_position := _resolve_saved_player_position(
						payload.get("player", {}),
						tool
					)
					WorldPersistence.apply_player_view(
						_player,
						payload.get("player", {}),
						spawn_position
					)
					await _finish_loaded_world_entry(spawn_position)
					call_deferred("_finalize_loaded_world_after_entry")
					return
				var rejected_backup := WorldPersistence.backup_rejected_save()
				if rejected_backup.is_empty():
					push_warning(
						"Save rejected or corrupt; starting a fresh world."
					)
				else:
					push_warning(
						(
							"Save rejected or corrupt; backed up to %s; "
							+ "starting a fresh world."
						)
						% rejected_backup
					)
				await _begin_fresh_world(
					_spawn_position_from_voxel_hit(probe_origin, probe_dir, player_hit)
				)
				return

			await _begin_fresh_world(
				_spawn_position_from_voxel_hit(probe_origin, probe_dir, player_hit)
			)
			return

		_loading.text = "Стриминг луны..."
		await get_tree().physics_frame


func _spawn_base_when_terrain_ready() -> void:
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var center_hint := _base_spawn.global_position
	if center_hint.length_squared() <= 0.000001:
		center_hint = Vector3.UP
	var up := _gravity_field.up_at(center_hint)
	var tangent := _gravity_field.tangent_basis_at(center_hint)
	var probe_origin := MoonGeometry.spawn_hold_point(center_hint)
	var probe_dir := -up
	var offset := 1.0
	var samples: Array[Vector3] = [
		probe_origin,
		probe_origin + tangent.x * offset,
		probe_origin - tangent.x * offset,
		probe_origin + tangent.z * offset,
		probe_origin - tangent.z * offset,
	]
	var wait_start_ms := Time.get_ticks_msec()

	while true:
		var hits: Array = []
		var all_ready := true
		for sample: Vector3 in samples:
			var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
				tool,
				_terrain,
				sample,
				probe_dir,
				MoonGeometry.GROUND_PROBE_DISTANCE_M
			)
			hits.append(hit)
			if hit == null:
				all_ready = false
		if all_ready:
			var grounds: Array[Vector3] = []
			for i in samples.size():
				grounds.append(
					_ground_point_from_hit(samples[i], probe_dir, hits[i])
				)
			var base_ground: Vector3 = grounds[0]
			var base_basis := GridSpawnUtil.terrain_basis(
				grounds[1] - grounds[2],
				grounds[3] - grounds[4]
			)
			var base_transform := GridSpawnUtil.transform_on_terrain(
				base_ground,
				base_basis,
				0.0
			)
			var base_result: StructuralCommandResult = (
				_session.spawn_slice01_base_at(base_transform)
			)
			if not base_result.is_ok():
				push_error(
					"Anchored base spawn failed: %s"
					% String(base_result.reason)
				)
			return

		if Time.get_ticks_msec() - wait_start_ms >= BASE_SPAWN_TIMEOUT_MS:
			push_error("Base spawn aborted: terrain SDF raycast timed out")
			return

		await get_tree().physics_frame


func _spawn_position_from_voxel_hit(
	origin: Vector3,
	direction: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
		_terrain,
		origin,
		direction,
		hit
	)
	var surface := VoxelSpaceUtil.resolve_ground_surface_along_ray(
		_physics_space_state(),
		origin,
		direction,
		sdf_point,
		MoonGeometry.GROUND_PROBE_DISTANCE_M
	)
	var up := _gravity_field.up_at(surface)
	_player_spawn_pos = surface + up * MoonGeometry.SPAWN_CLEARANCE_M
	return _player_spawn_pos


func _ground_point_from_hit(
	origin: Vector3,
	direction: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
		_terrain,
		origin,
		direction,
		hit
	)
	return VoxelSpaceUtil.resolve_ground_surface_along_ray(
		_physics_space_state(),
		origin,
		direction,
		sdf_point,
		MoonGeometry.GROUND_PROBE_DISTANCE_M
	)


func _physics_space_state() -> PhysicsDirectSpaceState3D:
	if _terrain == null or not _terrain.is_inside_tree():
		return null
	return _terrain.get_world_3d().direct_space_state


func _resolve_saved_player_position(
	row: Variant,
	tool: VoxelTool
) -> Vector3:
	if row is Dictionary:
		var position_data: Variant = (row as Dictionary).get("position", [])
		if position_data is Array and position_data.size() >= 3:
			var saved := Vector3(
				float(position_data[0]),
				float(position_data[1]),
				float(position_data[2]),
			)
			if _is_usable_saved_player_position(saved):
				return saved
	var hint := _player_spawn_hint
	var origin := MoonGeometry.spawn_hold_point(hint)
	var direction := _gravity_field.probe_direction_toward_ground(origin)
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		_terrain,
		origin,
		direction,
		MoonGeometry.GROUND_PROBE_DISTANCE_M
	)
	if hit != null:
		return _spawn_position_from_voxel_hit(origin, direction, hit)
	return MoonGeometry.surface_point(hint) + (
		_gravity_field.up_at(hint) * MoonGeometry.SPAWN_CLEARANCE_M
	)


func _is_usable_saved_player_position(pos: Vector3) -> bool:
	if not pos.is_finite():
		return false
	# Reject near-origin flat-world leftovers if a wrong save is loaded.
	if pos.length() < MoonGeometry.SURFACE_RADIUS_M * 0.5:
		return false
	return true
