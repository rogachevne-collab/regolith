extends Node3D

const SKY_PROBE_Y := 120.0
const SPAWN_CLEARANCE := 1.05
const MIN_WARMUP_FRAMES := 30
const MAX_SPAWN_SETTLE_FRAMES := 180
const GROUND_PROBE_MAX_DISTANCE := 200.0
const BASE_SPAWN_TIMEOUT_MS := 60000
const AUTOSAVE_INTERVAL_S := 90.0

@onready var _terrain: Node3D = $VoxelTerrain
@onready var _player: Node3D = $Player
@onready var _session: SimulationSession = $SimulationSession
@onready var _base_spawn: Node3D = $BaseSpawn
## Debug overlay (coordinate readout + controls hint) is off by default; the
## production HUD replaces it. Flip in the inspector for engineering builds.
@export var debug_overlay := false
## Fills player cargo with a large playtest mix on every world entry (fresh or loaded).
@export var playtest_cargo := true
## Spawns a welded rover on the flattest ground patch near BaseSpawn.
@export var spawn_demo_rover := true
## Phrase for RoverComposer (N wheels, long/short/…). Empty → hardcoded demo layout.
@export var demo_rover_phrase := "большой широкий длинный низкий ровер-платформа с 12 колесами, кокпит в центре"

@onready var _loading: Label = $CanvasLayer/Loading
@onready var _coordinates: Label = $CanvasLayer/Coordinates
@onready var _hint: Label = $CanvasLayer/Hint

var _warmup_frames := 0
var _player_spawn_xz := Vector2.ZERO
var _player_spawn_pos := Vector3.ZERO
var _world_ready := false
var _autosave_accum := 0.0
var _last_save_ms := 0
var _save_load_attempted := false


## True after spawn settle (or loaded-world entry). Beckett: `time_control op=step_until condition="is_world_ready()"`.
func is_world_ready() -> bool:
	return _world_ready


func _ready() -> void:
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_flight_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	_loading.visible = true
	_coordinates.visible = debug_overlay
	_hint.visible = debug_overlay
	_player_spawn_xz = Vector2(_player.global_position.x, _player.global_position.z)
	if _player.has_method("set_spawn_locked"):
		_player.set_spawn_locked(true)
	# Hold player in the sky until terrain collider exists — settle finds physics floor.
	_player.global_position = Vector3(_player_spawn_xz.x, SKY_PROBE_Y, _player_spawn_xz.y)
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


func _persist_world(force := false) -> void:
	if not _world_ready or _session == null:
		return
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms - _last_save_ms < 5000:
		return
	if WorldPersistence.save(_session.world, _player):
		_last_save_ms = now_ms


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
	var tool: VoxelTool = _terrain.get_voxel_tool()
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
			"Demo rover spawned: phrase='%s' assembly_id=%d intent=%s"
			% [
				demo_rover_phrase,
				int(result.get("assembly_id", 0)),
				str(result.get("intent", {})),
			]
		)


func _resync_player_camera() -> void:
	var head: Camera3D = _player.get_node_or_null("Camera") as Camera3D
	if head != null and head.has_method("snap_after_teleport"):
		head.call("snap_after_teleport")


func _finalize_loaded_world_after_entry() -> void:
	if not _world_ready:
		return
	WorldPersistence.finalize_loaded_world(_session.world)
	var tool: VoxelTool = _terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	RoverDemoSpawn.reseat_parked_locomotives(
		_session,
		_terrain,
		tool,
		_physics_space_state()
	)


func _place_when_ground_exists() -> void:
	var tool: VoxelTool = _terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var player_origin := Vector3(_player_spawn_xz.x, SKY_PROBE_Y, _player_spawn_xz.y)

	while true:
		if _warmup_frames < MIN_WARMUP_FRAMES:
			_warmup_frames += 1
			var pct: int = int(
				float(_warmup_frames) / float(MIN_WARMUP_FRAMES) * 100.0
			)
			_loading.text = "Загрузка террейна... %d%%" % pct
			await get_tree().process_frame
			continue

		var player_hit: VoxelRaycastResult = _voxel_down_hit(player_origin, tool)
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
				var fallback_spawn := _spawn_position_from_voxel_hit(
					_player_spawn_xz,
					player_origin,
					player_hit
				)
				await _begin_fresh_world(fallback_spawn)
				return

			var player_position := _spawn_position_from_voxel_hit(
				_player_spawn_xz,
				player_origin,
				player_hit
			)
			await _begin_fresh_world(player_position)
			return

		_loading.text = "Стриминг террейна..."
		await get_tree().physics_frame


func _spawn_base_when_terrain_ready() -> void:
	var tool: VoxelTool = _terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var base_origin := Vector3(
		_base_spawn.global_position.x,
		SKY_PROBE_Y,
		_base_spawn.global_position.z
	)
	var base_x_minus_origin := base_origin + Vector3.LEFT
	var base_x_plus_origin := base_origin + Vector3.RIGHT
	var base_z_minus_origin := base_origin + Vector3.FORWARD
	var base_z_plus_origin := base_origin + Vector3.BACK
	var wait_start_ms := Time.get_ticks_msec()

	while true:
		var base_hit: VoxelRaycastResult = _voxel_down_hit(base_origin, tool)
		var base_x_minus_hit: VoxelRaycastResult = _voxel_down_hit(
			base_x_minus_origin, tool
		)
		var base_x_plus_hit: VoxelRaycastResult = _voxel_down_hit(
			base_x_plus_origin, tool
		)
		var base_z_minus_hit: VoxelRaycastResult = _voxel_down_hit(
			base_z_minus_origin, tool
		)
		var base_z_plus_hit: VoxelRaycastResult = _voxel_down_hit(
			base_z_plus_origin, tool
		)
		if (
			base_hit != null
			and base_x_minus_hit != null
			and base_x_plus_hit != null
			and base_z_minus_hit != null
			and base_z_plus_hit != null
		):
			var base_ground: Vector3 = _ground_point_from_down_hit(
				base_origin,
				base_hit
			)
			var base_x_minus_ground: Vector3 = _ground_point_from_down_hit(
				base_x_minus_origin,
				base_x_minus_hit
			)
			var base_x_plus_ground: Vector3 = _ground_point_from_down_hit(
				base_x_plus_origin,
				base_x_plus_hit
			)
			var base_z_minus_ground: Vector3 = _ground_point_from_down_hit(
				base_z_minus_origin,
				base_z_minus_hit
			)
			var base_z_plus_ground: Vector3 = _ground_point_from_down_hit(
				base_z_plus_origin,
				base_z_plus_hit
			)
			var base_basis := GridSpawnUtil.terrain_basis(
				base_x_plus_ground - base_x_minus_ground,
				base_z_plus_ground - base_z_minus_ground
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
	xz: Vector2,
	origin: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	var surface_y_sdf := origin.y - _voxel_down_world_distance(hit)
	var surface_y := _resolve_surface_y(xz, surface_y_sdf)
	_player_spawn_pos = Vector3(xz.x, surface_y + SPAWN_CLEARANCE, xz.y)
	return _player_spawn_pos


func _ground_point_from_down_hit(
	origin: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	var sdf_y := origin.y - _voxel_down_world_distance(hit)
	var xz := Vector2(origin.x, origin.z)
	return Vector3(
		origin.x,
		_resolve_surface_y(xz, sdf_y),
		origin.z
	)


func _resolve_surface_y(xz: Vector2, surface_y_sdf: float) -> float:
	return VoxelSpaceUtil.resolve_ground_surface_y(
		_physics_space_state(),
		xz,
		surface_y_sdf,
		SKY_PROBE_Y,
		GROUND_PROBE_MAX_DISTANCE
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
	var xz := _saved_world_spawn_xz()
	var origin := Vector3(xz.x, SKY_PROBE_Y, xz.y)
	var hit: VoxelRaycastResult = _voxel_down_hit(origin, tool)
	if hit != null:
		return _spawn_position_from_voxel_hit(
			xz,
			origin,
			hit
		)
	return Vector3(xz.x, _saved_world_spawn_y(), xz.y)


func _saved_world_spawn_y() -> float:
	var best_y := -INF
	for assembly: SimulationAssembly in _session.world.list_assemblies():
		if assembly.tombstoned or assembly.motion == null:
			continue
		best_y = maxf(best_y, assembly.motion.transform.origin.y)
	if is_finite(best_y):
		return best_y + SPAWN_CLEARANCE
	if _player_spawn_pos.y > 0.0:
		return _player_spawn_pos.y
	return SPAWN_CLEARANCE


func _saved_world_spawn_xz() -> Vector2:
	var sum := Vector2.ZERO
	var count := 0
	for assembly: SimulationAssembly in _session.world.list_assemblies():
		if assembly.tombstoned or assembly.motion == null:
			continue
		var origin: Vector3 = assembly.motion.transform.origin
		sum += Vector2(origin.x, origin.z)
		count += 1
	if count > 0:
		return sum / float(count)
	return _player_spawn_xz


func _voxel_down_hit(origin: Vector3, tool: VoxelTool) -> VoxelRaycastResult:
	return VoxelSpaceUtil.raycast_world(
		tool,
		_terrain,
		origin,
		Vector3.DOWN,
		200.0
	)


func _voxel_down_world_distance(hit: VoxelRaycastResult) -> float:
	return VoxelSpaceUtil.raycast_hit_world_distance(_terrain, hit)


func _is_usable_saved_player_position(pos: Vector3) -> bool:
	if not pos.is_finite():
		return false
	if absf(pos.x) < 0.25 and absf(pos.z) < 0.25 and pos.y < 2.0:
		return false
	return true
