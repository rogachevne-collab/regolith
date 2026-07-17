extends Node3D

## Moon experiment entry — spherical VoxelLodTerrain + radial Field.
## Parity wiring with main; spawn probes follow GravityField, not world −Y.

const MIN_WARMUP_FRAMES := 30
## Lunar g=1.62: settle can take a few seconds once a floor exists.
const MAX_SPAWN_SETTLE_FRAMES := 360
## Baked stream should produce colliders faster than live HQ gen.
const PHYSICS_GROUND_TIMEOUT_MS := 20000
## Save load: don't burn 20s on collider stream — pad + play, retire pad later.
const PHYSICS_GROUND_TIMEOUT_LOAD_MS := 2500
const BASE_SPAWN_TIMEOUT_MS := 60000
const AUTOSAVE_INTERVAL_S := 90.0
const LANDING_PAD_SIZE_M := Vector3(48.0, 4.0, 48.0)
## Cross-fade LOD mesh swaps (requires get_lod_fade_discard in terrain shader).
const TERRAIN_LOD_FADE_DURATION_S := 0.25
## Detail normalmaps from LOD 2+ — illusion of geometry on distant blocks.
const TERRAIN_NORMALMAP_BEGIN_LOD := 2

@onready var _terrain: Node3D = $VoxelTerrain
@onready var _boulder_instancer: VoxelInstancer = $VoxelTerrain/VoxelInstancer
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
## VoxelInstancer decorative rocks (streams with terrain chunks).
@export var enable_boulder_instancer := true

@export_group("Planet generator")
## Preferred: res://resources/moon_planet_generator.tres — edit in Voxel graph UI, then F6.
## Clear the slot to rebuild from knobs below instead.
@export var planet_graph: VoxelGeneratorGraph
## Preferred play path: bake H(n) crust to a panorama heightmap and feed the
## native NODE_SDF_SPHERE_HEIGHTMAP (SE-like relief in game, not just noise).
@export var use_baked_heightmap := true
@export var heightmap_size := Vector2i(2048, 1024)
## The node samples the heightmap bilinearly; at 2048 a texel (~1.5 m) is
## coarser than a voxel (0.65 m), so texel-boundary creases show up as ribbed
## facets. Cubic-upsampling the loaded image (no re-bake) smooths those creases.
## 8192x4096 (~0.38 m/texel, sub-voxel) keeps steep crater rims from
## scalloping; drop to 4096x2048 if memory is tight.
@export var heightmap_smooth_size := Vector2i(8192, 4096)
@export_subgroup("Knobs (only if Planet Graph is empty)")
@export_range(0.0, 80.0, 0.5, "or_greater") var height_amp_m := 22.0
@export_range(10.0, 400.0, 1.0, "or_greater") var noise_period_m := 95.0
@export var noise_seed := 5046367
## 0=FBM hills, 2=Ridged (docs eroded look with carve_eroded).
@export_enum("FBM:0", "Ridged:2") var fractal_type: int = 2
@export_range(1, 8) var noise_octaves := 4
## Negate height — ridged carves instead of puffing (Generators→Planet).
@export var carve_eroded := true

var _warmup_frames := 0
var _player_spawn_hint := Vector3.UP
var _player_spawn_pos := Vector3.ZERO
var _world_ready := false
var _autosave_accum := 0.0
var _last_save_ms := 0
var _save_load_attempted := false
var _voxel_stream: VoxelStream
var _landing_pad: StaticBody3D


func is_world_ready() -> bool:
	return _world_ready


func _ready() -> void:
	WorldPersistence.save_path_override = MoonGeometry.world_save_path()
	_loading.visible = true
	_coordinates.visible = debug_overlay
	_hint.visible = debug_overlay
	_loading.text = "Луна..."
	_configure_terrain()
	_configure_dig_stream()
	_configure_boulder_instancer()
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		_session.world.get_archetype_registry().register(archetype)
	var gateway := get_node_or_null("WorldCommandGateway")
	if gateway != null and gateway.has_signal("terrain_modified"):
		gateway.terrain_modified.connect(_on_terrain_modified)
	_player_spawn_hint = _player.global_position
	if _player_spawn_hint.length_squared() <= 0.000001:
		_player_spawn_hint = Vector3.UP
	## Keep spawn off the equirectangular heightmap pole singularity (±Y),
	## where all longitude texels converge into a visible pinch/star.
	_player_spawn_hint = _away_from_pole(_player_spawn_hint)
	## Point VoxelViewer at the saved spot from frame 0 so stream isn't at
	## the default spawn while we still intend to load.
	var early_saved := _peek_saved_player_position()
	if _is_usable_saved_player_position(early_saved):
		_player_spawn_hint = early_saved.normalized()
	if _base_spawn != null:
		var base_len := _base_spawn.global_position.length()
		if base_len < 0.001:
			base_len = MoonGeometry.SURFACE_RADIUS_M
		_base_spawn.global_position = _player_spawn_hint * base_len
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
		## Docs Generators→Planet: graph resource and/or knobs (see exports).
		lod.generator = _make_planet_generator()
		lod.voxel_bounds = MoonGeometry.voxel_bounds_aabb()
		lod.view_distance = MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS
		lod.generate_collisions = true
		lod.collision_lod_count = 1
		lod.lod_count = 4
		lod.lod_distance = 56.0
		lod.lod_fade_duration = TERRAIN_LOD_FADE_DURATION_S
		lod.normalmap_enabled = true
		lod.normalmap_begin_lod_index = TERRAIN_NORMALMAP_BEGIN_LOD
		lod.normalmap_tile_resolution_min = 4
		lod.normalmap_tile_resolution_max = 16
		lod.cache_generated_blocks = true
	if _terrain.material != null:
		var mat: Material = (_terrain.material as Material).duplicate()
		_terrain.material = mat
		if mat is ShaderMaterial:
			var shader_mat := mat as ShaderMaterial
			shader_mat.set_shader_parameter("u_radial_up", 1.0)
			shader_mat.set_shader_parameter("u_planet_radius", MoonGeometry.SURFACE_RADIUS_M)
	_terrain.scale = Vector3.ONE * MoonGeometry.VOXEL_SCALE
	_ensure_player_viewer_wants_collisions()


func _make_planet_generator() -> VoxelGenerator:
	if planet_graph != null:
		var compile_result: Dictionary = planet_graph.compile()
		if not bool(compile_result.get("success", true)):
			push_error("planet_graph compile failed: %s" % str(compile_result))
		else:
			print("MoonExperiment: using planet_graph resource")
			return planet_graph
	if use_baked_heightmap:
		var height_image := MoonHeightmapUtil.ensure_heightmap(
			heightmap_size.x, heightmap_size.y
		)
		if height_image != null and height_image.get_width() > 0:
			_smooth_heightmap(height_image)
			return MoonSphereGeneratorFactory.create_play_heightmap(
				MoonGeometry.radius_voxels(), height_image, 1.0
			)
		push_warning("MoonExperiment: heightmap bake failed; falling back to noise graph")
	return MoonSphereGeneratorFactory.create_play(
		MoonGeometry.radius_voxels(),
		{
			"height_amp_m": height_amp_m,
			"noise_period_m": noise_period_m,
			"noise_seed": noise_seed,
			"fractal_type": fractal_type,
			"octaves": noise_octaves,
			"carve_eroded": carve_eroded,
		}
	)


func _away_from_pole(dir: Vector3) -> Vector3:
	## Tilt near-pole spawn directions down to ~37° latitude, same longitude.
	var n := dir.normalized()
	if absf(n.y) <= 0.7:
		return n
	var horiz := Vector2(n.x, n.z)
	if horiz.length() < 0.001:
		horiz = Vector2(1.0, 0.0)
	horiz = horiz.normalized()
	const LAT_Y := 0.6  # sin(~37°)
	var ring := sqrt(maxf(0.0, 1.0 - LAT_Y * LAT_Y))
	return Vector3(horiz.x * ring, signf(n.y) * LAT_Y, horiz.y * ring).normalized()


func _smooth_heightmap(height_image: Image) -> void:
	## Cubic-upsample so the node's bilinear sampling no longer shows
	## texel-boundary creases as ribbed facets on the voxel surface.
	var tw := heightmap_smooth_size.x
	var th := heightmap_smooth_size.y
	if tw <= height_image.get_width() or th <= height_image.get_height():
		return
	height_image.resize(tw, th, Image.INTERPOLATE_CUBIC)
	print("MoonExperiment: heightmap cubic-upsampled to %dx%d (smooth surface)" % [tw, th])


func _configure_dig_stream() -> void:
	if not (_terrain is VoxelLodTerrain):
		return
	var dir := MoonGeometry.dig_stream_directory()
	var abs_dir := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)
	## Fresh gen_v dir (no partial LOD scraps). Generator fills crust; digs persist.
	var stream := VoxelStreamSQLite.new()
	stream.database_path = MoonTerrainParams.stream_database_path()
	stream.save_generator_output = false
	_voxel_stream = stream
	var lod := _terrain as VoxelLodTerrain
	lod.stream = stream
	lod.full_load_mode_enabled = false
	lod.cache_generated_blocks = true
	print(
		"MoonExperiment: VoxelGeneratorGraph planet gen_v%d dig-stream=%s"
		% [MoonTerrainParams.GENERATOR_VERSION, stream.database_path]
	)


func _configure_boulder_instancer() -> void:
	if _boulder_instancer == null:
		return
	if enable_boulder_instancer:
		return
	_boulder_instancer.library = null


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


func _on_terrain_modified(
	_removed_volume_m3: float,
	_dig_center: Vector3,
	_dig_radius_m: float
) -> void:
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
			var snap := _snap_spawn_to_ground(_player.global_position)
			push_warning(
				(
					"Spawn settle timed out after %d frames; snapping to %s"
					% [settle_frames, str(snap)]
				)
			)
			_player.call("set_spawn_ready", snap)
			break
	_loading.visible = false
	_world_ready = true
	print(
		"MoonExperiment: world_ready player=%s r=%.2f"
		% [str(_player.global_position), _player.global_position.length()]
	)
	_resync_player_camera()
	_session.get_industry_simulation().bind_world(_session.world)
	_apply_playtest_cargo_if_enabled()
	if spawn_demo_rover:
		await _spawn_demo_rover_near_player()


func _finish_loaded_world_entry(spawn_position: Vector3) -> void:
	_player.call("set_spawn_ready", spawn_position)
	_resync_player_camera()
	_loading.visible = false
	_world_ready = true
	print(
		(
			"MoonExperiment: world_ready (loaded) player=%s r=%.2f"
		)
		% [str(spawn_position), spawn_position.length()]
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
	var ground: Vector3 = Vector3(NAN, NAN, NAN)
	for _attempt in 90:
		var ground_variant: Variant = RoverDemoSpawn.find_flat_ground_near(
			_terrain,
			tool,
			_physics_space_state(),
			_base_spawn.global_position
		)
		if ground_variant is Vector3:
			ground = ground_variant as Vector3
			break
		await get_tree().physics_frame
	if not _is_finite_vec3(ground):
		push_warning("Demo rover spawn failed: no flat ground near BaseSpawn")
		return
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

	while _warmup_frames < MIN_WARMUP_FRAMES:
		_warmup_frames += 1
		var pct: int = int(
			float(_warmup_frames) / float(MIN_WARMUP_FRAMES) * 100.0
		)
		_loading.text = "Загрузка луны... %d%%" % pct
		await get_tree().process_frame

	## Save path first: no "Стриминг луны..." at default spawn, short collider wait.
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
			var saved_spawn := _resolve_saved_player_position(
				payload.get("player", {}),
				tool
			)
			_player.global_position = MoonGeometry.spawn_hold_point(saved_spawn)
			await get_tree().physics_frame
			var loaded_spawn := await _resolve_spawn_with_floor(
				MoonGeometry.spawn_hold_point(saved_spawn),
				_gravity_field.probe_direction_toward_ground(saved_spawn),
				saved_spawn,
				PHYSICS_GROUND_TIMEOUT_LOAD_MS
			)
			WorldPersistence.apply_player_view(
				_player,
				payload.get("player", {}),
				loaded_spawn
			)
			await _finish_loaded_world_entry(loaded_spawn)
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

	## Fresh world (or rejected save): stream SDF, then wait for physics floor.
	while true:
		var player_hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
			tool,
			_terrain,
			probe_origin,
			probe_dir,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if player_hit != null:
			var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
				_terrain,
				probe_origin,
				probe_dir,
				player_hit
			)
			var spawn_position := await _resolve_spawn_with_floor(
				probe_origin,
				probe_dir,
				sdf_point,
				PHYSICS_GROUND_TIMEOUT_MS
			)
			await _begin_fresh_world(spawn_position)
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


func _ensure_player_viewer_wants_collisions() -> void:
	var viewer := _player.get_node_or_null("VoxelViewer") as VoxelViewer
	if viewer == null:
		return
	viewer.requires_collisions = true
	viewer.requires_visuals = true


func _peek_saved_player_position() -> Vector3:
	if not WorldPersistence.has_save():
		return Vector3.ZERO
	var payload: Dictionary = WorldPersistence.read_payload()
	if payload.is_empty():
		return Vector3.ZERO
	var row: Variant = payload.get("player", {})
	if row is Dictionary:
		var position_data: Variant = (row as Dictionary).get("position", [])
		if position_data is Array and position_data.size() >= 3:
			return Vector3(
				float(position_data[0]),
				float(position_data[1]),
				float(position_data[2]),
			)
	return Vector3.ZERO


func _resolve_spawn_with_floor(
	origin: Vector3,
	direction: Vector3,
	sdf_point: Vector3,
	timeout_ms: int = PHYSICS_GROUND_TIMEOUT_MS
) -> Vector3:
	_loading.text = "Стриминг коллизии луны..."
	var wait_start_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait_start_ms < timeout_ms:
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			_physics_space_state(),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if _is_finite_vec3(physics_point):
			print(
				"MoonExperiment: physics ground ready at %s (waited %d ms)"
				% [str(physics_point), Time.get_ticks_msec() - wait_start_ms]
			)
			var up := _gravity_field.up_at(physics_point)
			_player_spawn_pos = (
				physics_point + up * MoonGeometry.SPAWN_CLEARANCE_M
			)
			return _player_spawn_pos
		var meshed_hint := sdf_point if _is_finite_vec3(sdf_point) else origin
		if _is_spawn_area_meshed(meshed_hint):
			_loading.text = "Коллизия луны..."
		else:
			_loading.text = "Стриминг коллизии луны..."
		await get_tree().physics_frame

	var surface := sdf_point
	if not _is_finite_vec3(surface):
		surface = MoonGeometry.surface_point(_player_spawn_hint)
	push_warning(
		"Voxel collider slow; installing temporary landing pad at %s" % str(surface)
	)
	_player_spawn_pos = _install_landing_pad(surface)
	return _player_spawn_pos


func _install_landing_pad(surface: Vector3) -> Vector3:
	_remove_landing_pad()
	var up := _gravity_field.up_at(surface)
	var basis := _gravity_field.tangent_basis_at(surface)
	var body := StaticBody3D.new()
	body.name = "MoonLandingPad"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = LANDING_PAD_SIZE_M
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	## Top face of the box sits on the SDF surface.
	body.global_transform = Transform3D(
		basis,
		surface - up * (LANDING_PAD_SIZE_M.y * 0.5)
	)
	_landing_pad = body
	call_deferred("_retire_landing_pad_when_voxel_floor_ready", surface)
	return surface + up * MoonGeometry.SPAWN_CLEARANCE_M


func _remove_landing_pad() -> void:
	if _landing_pad != null and is_instance_valid(_landing_pad):
		_landing_pad.queue_free()
	_landing_pad = null


func _retire_landing_pad_when_voxel_floor_ready(surface: Vector3) -> void:
	var origin := MoonGeometry.spawn_hold_point(surface)
	var direction := _gravity_field.probe_direction_toward_ground(origin)
	var deadline_ms := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline_ms:
		if _landing_pad == null or not is_instance_valid(_landing_pad):
			return
		var exclude: Array[RID] = []
		exclude.append(_landing_pad.get_rid())
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			_physics_space_state(),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M,
			1,
			exclude
		)
		if _is_finite_vec3(physics_point):
			print(
				"MoonExperiment: voxel floor ready, retiring landing pad at %s"
				% str(physics_point)
			)
			_remove_landing_pad()
			return
		await get_tree().create_timer(0.5).timeout
	push_warning("Landing pad kept: voxel collider never appeared under spawn")


func _is_spawn_area_meshed(world_hint: Vector3) -> bool:
	if not (_terrain is VoxelLodTerrain):
		return false
	var lod := _terrain as VoxelLodTerrain
	var local := VoxelSpaceUtil.world_to_local(_terrain, world_hint)
	var area := AABB(local - Vector3.ONE * 4.0, Vector3.ONE * 8.0)
	return lod.is_area_meshed(area, 0)


func _is_finite_vec3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


func _snap_spawn_to_ground(near_position: Vector3) -> Vector3:
	var hint := near_position
	if hint.length_squared() <= 0.000001:
		hint = _player_spawn_hint
	var origin := MoonGeometry.spawn_hold_point(hint)
	var direction := _gravity_field.probe_direction_toward_ground(origin)
	var exclude: Array[RID] = []
	if _landing_pad != null and is_instance_valid(_landing_pad):
		exclude.append(_landing_pad.get_rid())
	var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
		_physics_space_state(),
		origin,
		direction,
		MoonGeometry.GROUND_PROBE_DISTANCE_M,
		1,
		exclude
	)
	var surface := physics_point
	if not _is_finite_vec3(surface):
		## Prefer the temp pad / any collider including the pad.
		surface = VoxelSpaceUtil.physics_surface_along_ray(
			_physics_space_state(),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
	if not _is_finite_vec3(surface):
		var tool: VoxelTool = TerrainCompat.get_voxel_tool(_terrain)
		if tool != null:
			tool.channel = VoxelBuffer.CHANNEL_SDF
			var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
				tool,
				_terrain,
				origin,
				direction,
				MoonGeometry.GROUND_PROBE_DISTANCE_M
			)
			if hit != null:
				surface = VoxelSpaceUtil.raycast_hit_world_point(
					_terrain,
					origin,
					direction,
					hit
				)
	if not _is_finite_vec3(surface):
		surface = MoonGeometry.surface_point(hint)
	if _landing_pad == null:
		return _install_landing_pad(surface)
	var up := _gravity_field.up_at(surface)
	return surface + up * MoonGeometry.SPAWN_CLEARANCE_M


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
	## Relief is SURFACE_RADIUS_M ± HEIGHT_CLAMP_M; reject stale noise-graph saves.
	var min_r := (
		MoonGeometry.SURFACE_RADIUS_M
		- MoonTerrainParams.HEIGHT_CLAMP_M
		- 10.0
	)
	var max_r := (
		MoonGeometry.SURFACE_RADIUS_M
		+ MoonTerrainParams.HEIGHT_CLAMP_M
		+ MoonGeometry.SPAWN_SKY_OFFSET_M
	)
	var r := pos.length()
	if r < min_r or r > max_r:
		return false
	## Reject saved positions sitting on the equirectangular pole pinch (±Y);
	## fall back to the off-pole fresh spawn instead.
	return absf(pos.normalized().y) <= 0.7
