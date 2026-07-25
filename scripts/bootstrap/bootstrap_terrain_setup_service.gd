class_name BootstrapTerrainSetupService
extends RefCounted

## Must match bootstrap.gd constants.
const TERRAIN_LOD_FADE_DURATION_S := 0.25
const TERRAIN_COLLISION_UPDATE_DELAY_MS := 100
const TERRAIN_NORMALMAP_BEGIN_LOD := 2
const SPAWN_COLLISION_LOD_COUNT := 3
const SPAWN_FOCUS_VIEW_DISTANCE_VOXELS := 512
const MAP_HEIGHTMAP_SIZE := Vector2i(2048, 1024)


static func configure_terrain(bootstrap) -> void:
	if not TerrainCompat.is_terrain(bootstrap._terrain):
		push_error("Moon experiment terrain node is not VoxelTerrain/VoxelLodTerrain")
		return
	if bootstrap._terrain is VoxelLodTerrain:
		var lod := bootstrap._terrain as VoxelLodTerrain
		## Docs Generators→Planet: graph resource and/or knobs (see exports).
		lod.generator = bootstrap._make_planet_generator()
		## Clipbox, not the default legacy octree. The octree system supports
		## exactly ONE viewer: `VoxelLodTerrain::get_local_viewer_pos` walks every
		## registered viewer and keeps whichever comes last ("TODO Support for
		## multiple viewers, this is a placeholder implementation"). At the time
		## this bit, `GranularVoxelRegionView` created a VoxelViewer per loose
		## material region (it meshes natively now and needs none), so the moon's
		## LODs followed a coin flip: settle around the sand, and LOD0 under the
		## player never gets requested at all (stats stayed blocked=0, io=0 while
		## digs returned `terrain_unavailable` and LOD1/2 colliders carried the
		## player). Clipbox pairs viewers individually, which is what it was added
		## upstream to do — and it stays: nothing guarantees the player's viewer
		## remains the only one.
		lod.streaming_system = VoxelLodTerrain.STREAMING_SYSTEM_CLIPBOX
		## ORDER MATTERS. `set_voxel_bounds` snaps the box to the octree size
		## (`mesh_block_size << (lod_count - 1)`) as it is at assignment time.
		## `set_mesh_block_size` re-snaps, but returns early when the value is
		## already the default (16), and `set_lod_count` never re-snaps at all.
		## Assigned first, the bounds get snapped against the *default* octree
		## size and keep it: ±11888 instead of a multiple of 8192. That, not the
		## arithmetic, is what made `32 + lod_count 10` cut the moon into cubes.
		lod.mesh_block_size = MoonGeometry.DEFAULT_MESH_BLOCK_SIZE
		lod.lod_count = MoonGeometry.DEFAULT_LOD_COUNT
		lod.voxel_bounds = MoonGeometry.voxel_bounds_aabb()
		lod.view_distance = MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS
		lod.generate_collisions = true
		lod.collision_lod_count = SPAWN_COLLISION_LOD_COUNT
		lod.lod_distance = MoonGeometry.DEFAULT_LOD_DISTANCE
		## Clipbox splits what octree took from one knob: `lod_distance` is LOD0
		## reach (and, streaming on, how far edits are allowed), this one is
		## every LOD above it.
		lod.secondary_lod_distance = MoonGeometry.DEFAULT_SECONDARY_LOD_DISTANCE
		lod.lod_fade_duration = TERRAIN_LOD_FADE_DURATION_S
		## Detail normalmaps need generator series generation, which script
		## generators don't support (VT asserts per tile). Graph fallback keeps
		## them; native path relies on real far-LOD geometry for now.
		lod.normalmap_enabled = not bootstrap._generator_is_native
		lod.normalmap_begin_lod_index = TERRAIN_NORMALMAP_BEGIN_LOD
		lod.normalmap_tile_resolution_min = 4
		lod.normalmap_tile_resolution_max = 16
		lod.cache_generated_blocks = true
		lod.threaded_update_enabled = true
		## Trimesh cooking is the expensive half of a ring update, and every dig
		## re-cooks the blocks it touched. Default 0 re-cooks immediately, one
		## edit at a time; a delay coalesces a burst (drill held down, dozer
		## blade pushing) into fewer cooks. Cost is colliders lagging the visual
		## mesh by that long — keep it under a frame or two of gameplay.
		lod.collision_update_delay = TERRAIN_COLLISION_UPDATE_DELAY_MS
		apply_terrain_debug_draw(bootstrap, lod)
	if bootstrap._terrain.material != null:
		var mat: Material = (bootstrap._terrain.material as Material).duplicate()
		bootstrap._terrain.material = mat
		if mat is ShaderMaterial:
			var shader_mat := mat as ShaderMaterial
			apply_planet_terrain_shader_params(bootstrap, shader_mat)
	bootstrap._terrain.scale = Vector3.ONE * MoonGeometry.VOXEL_SCALE
	ensure_player_viewer_for_planet(bootstrap)


## The four flags that answer "why is there no LOD0 here": which viewer the
## streamer is actually serving, and where mesh and collision each exist. The
## other eight flags stay off — they draw per-block boxes across the whole
## Ø19 km shell and bury the ones worth reading.
static func apply_terrain_debug_draw(bootstrap, lod: VoxelLodTerrain) -> void:
	if not bootstrap.debug_terrain_draw:
		return
	lod.debug_draw_enabled = true
	lod.debug_draw_viewer_clipboxes = true
	lod.debug_draw_loaded_visual_and_collision_blocks = true
	lod.debug_draw_volume_bounds = true
	lod.debug_draw_edit_boxes = true
	print("MoonExperiment: terrain debug draw on (clipboxes, blocks, bounds, edits)")


static func apply_planet_terrain_shader_params(
	bootstrap,
	shader_mat: ShaderMaterial
) -> void:
	shader_mat.set_shader_parameter("u_radial_up", 1.0)
	shader_mat.set_shader_parameter("u_planet_radius", MoonGeometry.active_surface_radius_m())
	## Biome/macro are meter-periodic on dir*R inside the shader — do not shrink
	## u_biome_scale / u_large_scale with diameter (that flattened tri-biome into
	## one soup on Ø19 km). u_detail_scale stays world-triplanar metres.
	print(
		"MoonExperiment: terrain shader radial R=%.0f m"
		% MoonGeometry.active_surface_radius_m()
	)
	apply_brightness_map(bootstrap, shader_mat)


## Display-only albedo brightness (dark maria + fresh-crater ray systems)
## baked natively (~1 s MT at startup); SDF untouched — no GENERATOR_VERSION.
static func apply_brightness_map(bootstrap, shader_mat: ShaderMaterial) -> void:
	if (
		bootstrap._native_generator == null
		or not bootstrap._native_generator.has_method("bake_brightness_map")
	):
		return
	var img: Image = bootstrap._native_generator.bake_brightness_map(1024, 512)
	if img == null:
		push_warning("MoonExperiment: brightness map bake failed")
		return
	var tex := ImageTexture.create_from_image(img)
	shader_mat.set_shader_parameter("u_moon_brightness", tex)
	shader_mat.set_shader_parameter("u_moon_brightness_on", 1.0)
	print("MoonExperiment: albedo brightness map applied (maria + rays)")


static func schedule_map_heightmap_bake(bootstrap) -> void:
	## Only when the native generator owns terrain: the heightmap fallback
	## already baked a full-res EXR synchronously (don't race its file).
	if not bootstrap._generator_is_native or bootstrap._map_heightmap_scheduled:
		return
	bootstrap._map_heightmap_scheduled = true
	if FileAccess.file_exists(MoonHeightmapUtil.heightmap_path()):
		return
	WorkerThreadPool.add_task(
		func() -> void:
			MoonHeightmapUtil.ensure_heightmap(
				MAP_HEIGHTMAP_SIZE.x, MAP_HEIGHTMAP_SIZE.y
			),
		false,
		"Moon map heightmap bake"
	)


static func away_from_pole(dir: Vector3) -> Vector3:
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


## Debug aid: caves cover ~0.1% of the surface — without coordinates nobody
## finds one. Prints the three skylights nearest the current player position.
static func print_nearest_cave_entrances(bootstrap, native: Object) -> void:
	if not native.has_method("cave_entrances"):
		return
	var entrances: PackedVector3Array = native.cave_entrances()
	if entrances.is_empty():
		return
	var origin := Vector3.UP * MoonGeometry.radius_voxels()
	if bootstrap._player != null:
		origin = bootstrap._player.global_position
	var by_dist: Array = []
	for p in entrances:
		by_dist.append([origin.distance_to(p), p])
	by_dist.sort_custom(func(a, b): return a[0] < b[0])
	print("MoonExperiment: %d caves generated" % entrances.size())
	for i in mini(3, by_dist.size()):
		var entry: Array = by_dist[i]
		print(
			"MoonExperiment: cave skylight %d — %.0f m away at %v"
			% [i + 1, entry[0], entry[1]]
		)


static func ensure_player_viewer_for_planet(bootstrap) -> void:
	var viewer: VoxelViewer = find_voxel_viewer(bootstrap)
	if viewer == null:
		return
	viewer.requires_collisions = true
	viewer.requires_visuals = true
	## Effective range is min(terrain, viewer) — keep both at planet budget.
	viewer.view_distance = MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS
	bootstrap._player_camera = bootstrap._player.get_node_or_null("Camera") as Camera3D
	bootstrap._applied_view_distance = MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS


static func set_spawn_streaming_focus(bootstrap, enabled: bool) -> void:
	## Tight VD during spawn: local mesh/collider first. Full shell after ready.
	if not (bootstrap._terrain is VoxelLodTerrain):
		return
	var lod := bootstrap._terrain as VoxelLodTerrain
	var viewer: VoxelViewer = find_voxel_viewer(bootstrap)
	var vd: int = (
		SPAWN_FOCUS_VIEW_DISTANCE_VOXELS
		if enabled
		else MoonGeometry.DEFAULT_VIEW_DISTANCE_VOXELS
	)
	lod.view_distance = vd
	if viewer != null:
		viewer.view_distance = vd
	bootstrap._applied_view_distance = vd
	if enabled:
		print(
			"MoonExperiment: spawn streaming focus vd=%d collision_lod=%d"
			% [vd, SPAWN_COLLISION_LOD_COUNT]
		)


static func find_voxel_viewer(bootstrap) -> VoxelViewer:
	## On foot: child of player. In a vehicle: reparented to the world root.
	if bootstrap._player != null:
		var under_player := bootstrap._player.get_node_or_null("VoxelViewer") as VoxelViewer
		if under_player != null:
			return under_player
	return bootstrap.get_node_or_null("VoxelViewer") as VoxelViewer


static func update_streaming_budget(bootstrap) -> void:
	## Surface: keep the near-field shell small enough that LOD0 under the
	## viewer can finish. Altitude: blend toward |cam|+R so the planet LODs
	## instead of unloading. On Ø19 km, raw |cam|+R on foot was ~22k voxels —
	## the streamer never completed LOD0 outside the spawn-focus bake, so
	## collision_lod_count>1 was the only thing holding the player up.
	if not bootstrap._world_ready:
		return
	if not (bootstrap._terrain is VoxelLodTerrain):
		return
	if bootstrap._player_camera == null:
		if bootstrap._player != null:
			bootstrap._player_camera = (
				bootstrap._player.get_node_or_null("Camera") as Camera3D
			)
		if bootstrap._player_camera == null:
			return
	var vd: int = MoonGeometry.view_distance_voxels_for_camera_distance(
		bootstrap._player_camera.global_position.length()
	)
	if vd == bootstrap._applied_view_distance:
		return
	bootstrap._applied_view_distance = vd
	(bootstrap._terrain as VoxelLodTerrain).view_distance = vd
	var viewer: VoxelViewer = find_voxel_viewer(bootstrap)
	if viewer != null:
		viewer.view_distance = vd


static func configure_far_impostor(bootstrap) -> void:
	## Cheap sphere kept inside Camera.far, scaled to the real angular size.
	## Extreme Camera.far is not an option — breaks directional light culling.
	bootstrap._far_impostor = MeshInstance3D.new()
	bootstrap._far_impostor.name = "MoonFarImpostor"
	var sphere := SphereMesh.new()
	sphere.radius = MoonGeometry.active_surface_radius_m()
	sphere.height = MoonGeometry.active_surface_radius_m() * 2.0
	sphere.radial_segments = 48
	sphere.rings = 24
	bootstrap._far_impostor.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.52)
	mat.roughness = 0.96
	mat.metallic = 0.0
	bootstrap._far_impostor.material_override = mat
	bootstrap._far_impostor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bootstrap._far_impostor.visible = false
	bootstrap.add_child(bootstrap._far_impostor)
	if bootstrap._player_camera == null and bootstrap._player != null:
		bootstrap._player_camera = bootstrap._player.get_node_or_null("Camera") as Camera3D


static func update_far_impostor(bootstrap) -> void:
	if bootstrap._far_impostor == null:
		return
	if bootstrap._player_camera == null:
		if bootstrap._player != null:
			bootstrap._player_camera = (
				bootstrap._player.get_node_or_null("Camera") as Camera3D
			)
		if bootstrap._player_camera == null:
			bootstrap._far_impostor.visible = false
			return
	var cam_pos: Vector3 = bootstrap._player_camera.global_position
	var real_dist: float = cam_pos.length()
	if real_dist < MoonGeometry.FAR_IMPOSTOR_START_M or real_dist < 1.0:
		bootstrap._far_impostor.visible = false
		return
	var visual_dist: float = minf(
		MoonGeometry.FAR_IMPOSTOR_VISUAL_DIST_M,
		bootstrap._player_camera.far * 0.45,
	)
	if visual_dist < 1.0:
		bootstrap._far_impostor.visible = false
		return
	## Angular size match: R_vis / d_vis = R_real / d_real → scale = d_vis / d_real.
	var toward_planet: Vector3 = -cam_pos / real_dist
	bootstrap._far_impostor.global_position = cam_pos + toward_planet * visual_dist
	bootstrap._far_impostor.scale = Vector3.ONE * (visual_dist / real_dist)
	bootstrap._far_impostor.visible = true
