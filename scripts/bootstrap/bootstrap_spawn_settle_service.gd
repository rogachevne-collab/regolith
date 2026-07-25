class_name BootstrapSpawnSettleService
extends RefCounted

## Must match bootstrap.gd constants.
const MIN_WARMUP_FRAMES := 30
const MAX_SPAWN_SETTLE_FRAMES := 360
const PHYSICS_GROUND_TIMEOUT_MS := 8000
const PHYSICS_GROUND_TIMEOUT_LOAD_MS := 8000
const LANDING_PAD_SIZE_M := Vector3(48.0, 4.0, 48.0)


static func reseat_player_near(bootstrap, target_world: Vector3) -> void:
	var dir: Vector3 = target_world.normalized()
	if dir.length_squared() < 0.000001:
		dir = bootstrap._player_spawn_hint
	bootstrap._player_spawn_hint = dir
	if bootstrap._player.has_method("set_spawn_locked"):
		bootstrap._player.set_spawn_locked(true)
	var hold: Vector3 = MoonGeometry.spawn_hold_point(dir)
	bootstrap._player.global_position = hold
	bootstrap._set_spawn_streaming_focus(true)
	var resolved: Vector3 = await resolve_spawn_with_floor(
		bootstrap,
		hold,
		bootstrap._gravity_field.probe_direction_toward_ground(hold),
		MoonGeometry.surface_point(dir),
		PHYSICS_GROUND_TIMEOUT_LOAD_MS
	)
	bootstrap._player.call("begin_spawn_settle", resolved)
	var settle_frames := 0
	while not bootstrap._player.call("is_spawn_settled"):
		await bootstrap.get_tree().physics_frame
		settle_frames += 1
		if settle_frames >= MAX_SPAWN_SETTLE_FRAMES:
			bootstrap._player.call(
				"set_spawn_ready",
				snap_spawn_to_ground(bootstrap, bootstrap._player.global_position)
			)
			break
	resync_player_camera(bootstrap)
	bootstrap._set_spawn_streaming_focus(false)


static func begin_fresh_world(bootstrap, player_position: Vector3) -> void:
	if not IndustryStoreService.seed_player_starter_resources(
		bootstrap._session.world,
		PlayerIdentity.local_uid()
	):
		push_error("Fresh world player starter resources seed failed")
	await finish_world_entry(bootstrap, player_position)
	## Main map is intentionally bare on a fresh world — only the demo rover and
	## hopper (spawned in _finish_world_entry). The Slice-01 starter base is no
	## longer auto-placed; build it in-game instead.


static func finish_world_entry(bootstrap, player_position: Vector3) -> void:
	align_sun_day_at(bootstrap, player_position)
	bootstrap._player.call("begin_spawn_settle", player_position)
	bootstrap._loading.text = "Посадка..."
	var settle_frames := 0
	while not bootstrap._player.call("is_spawn_settled"):
		await bootstrap.get_tree().physics_frame
		settle_frames += 1
		if settle_frames >= MAX_SPAWN_SETTLE_FRAMES:
			var snap: Vector3 = snap_spawn_to_ground(
				bootstrap, bootstrap._player.global_position
			)
			push_warning(
				(
					"Spawn settle timed out after %d frames; snapping to %s"
					% [settle_frames, str(snap)]
				)
			)
			bootstrap._player.call("set_spawn_ready", snap)
			break
	bootstrap._loading.visible = false
	bootstrap._world_ready = true
	bootstrap._schedule_map_heightmap_bake()
	## Keep spawn-focus VD until demos finish — restoring 2048 here hitch-stacked
	## with vehicle compose.
	print(
		"MoonExperiment: world_ready player=%s r=%.2f"
		% [str(bootstrap._player.global_position), bootstrap._player.global_position.length()]
	)
	resync_player_camera(bootstrap)
	bootstrap._session.get_industry_simulation().bind_world(bootstrap._session.world)
	bootstrap._apply_playtest_cargo_if_enabled()
	bootstrap._sync_demo_spawn_anchor()
	if bootstrap.spawn_demo_rover:
		await bootstrap._spawn_demo_rover_near_player()
		for _i in 3:
			await bootstrap.get_tree().physics_frame
	if bootstrap.spawn_demo_hopper:
		await bootstrap._spawn_demo_hopper_near_player()
	if bootstrap.spawn_lamp_poles:
		bootstrap._spawn_lamp_poles_near_player()
	bootstrap._set_spawn_streaming_focus(false)


static func finish_loaded_world_entry(bootstrap, spawn_position: Vector3) -> void:
	align_sun_day_at(bootstrap, spawn_position)
	bootstrap._player.call("set_spawn_ready", spawn_position)
	resync_player_camera(bootstrap)
	bootstrap._loading.visible = false
	bootstrap._world_ready = true
	bootstrap._schedule_map_heightmap_bake()
	bootstrap._set_spawn_streaming_focus(false)
	print(
		(
			"MoonExperiment: world_ready (loaded) player=%s r=%.2f"
		)
		% [str(spawn_position), spawn_position.length()]
	)
	bootstrap._session.get_industry_simulation().bind_world(bootstrap._session.world)
	bootstrap._apply_playtest_cargo_if_enabled()
	if bootstrap.spawn_lamp_poles:
		bootstrap._spawn_lamp_poles_near_player()


static func align_sun_day_at(bootstrap, world_position: Vector3) -> void:
	var cycle := bootstrap.get_node_or_null("DayNightCycle") as DayNightCycle
	if cycle == null:
		return
	var up := world_position
	if up.length_squared() <= 0.000001:
		up = Vector3.UP
	cycle.align_noon_above(up)


static func resync_player_camera(bootstrap) -> void:
	var head: Camera3D = bootstrap._player.get_node_or_null("Camera") as Camera3D
	if head != null and head.has_method("snap_after_teleport"):
		head.call("snap_after_teleport")


static func finalize_loaded_world_after_entry(bootstrap) -> void:
	if not bootstrap._world_ready:
		return
	WorldPersistence.finalize_loaded_world(bootstrap._session.world)
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(bootstrap._terrain)
	if tool == null:
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	RoverDemoSpawn.reseat_parked_locomotives(
		bootstrap._session,
		bootstrap._terrain,
		tool,
		physics_space_state(bootstrap)
	)
	# Un-sintered loose material from last session, back on top of the terrain it
	# was resting on. Only on a loaded world — a fresh one has no heaps to place.
	var granular := bootstrap.get_node_or_null("GranularVoxelWorld") as GranularVoxelWorld
	if granular != null:
		granular.load_field(MoonGeometry.granular_save_path())


static func place_when_ground_exists(bootstrap) -> void:
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(bootstrap._terrain)
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var probe_origin := MoonGeometry.spawn_hold_point(bootstrap._player_spawn_hint)
	var probe_dir: Vector3 = bootstrap._gravity_field.probe_direction_toward_ground(probe_origin)
	bootstrap._set_spawn_streaming_focus(true)

	while bootstrap._warmup_frames < MIN_WARMUP_FRAMES:
		bootstrap._warmup_frames += 1
		var pct: int = int(
			float(bootstrap._warmup_frames) / float(MIN_WARMUP_FRAMES) * 100.0
		)
		bootstrap._loading.text = "Загрузка луны... %d%%" % pct
		await bootstrap.get_tree().process_frame

	## Save path first: no "Стриминг луны..." at default spawn, short collider wait.
	if WorldPersistence.has_save() and not bootstrap._save_load_attempted:
		bootstrap._save_load_attempted = true
		bootstrap._loading.text = "Загрузка сохранения..."
		await bootstrap.get_tree().process_frame
		var payload: Dictionary = WorldPersistence.read_payload()
		var simulation: Variant = payload.get("simulation", {})
		if (
			not payload.is_empty()
			and simulation is Dictionary
			and WorldPersistence.restore_snapshot_data(
				bootstrap._session.world,
				simulation
			)
		):
			WorldPersistence.restore_players_from_payload(payload)
			var player_row := WorldPersistence.player_pose_row(
				PlayerIdentity.local_uid()
			)
			var saved_spawn: Vector3 = resolve_saved_player_position(
				bootstrap, player_row, tool
			)
			bootstrap._player.global_position = MoonGeometry.spawn_hold_point(saved_spawn)
			await bootstrap.get_tree().physics_frame
			var loaded_spawn: Vector3 = await resolve_spawn_with_floor(
				bootstrap,
				MoonGeometry.spawn_hold_point(saved_spawn),
				bootstrap._gravity_field.probe_direction_toward_ground(saved_spawn),
				saved_spawn,
				PHYSICS_GROUND_TIMEOUT_LOAD_MS
			)
			WorldPersistence.apply_player_view(
				bootstrap._player,
				player_row,
				loaded_spawn
			)
			WorldPersistence.restore_map_markers_from_payload(payload)
			finish_loaded_world_entry(bootstrap, loaded_spawn)
			bootstrap.call_deferred("_finalize_loaded_world_after_entry")
			return
		var rejected_backup := WorldPersistence.backup_rejected_save()
		WorldPersistence.clear_map_markers()
		WorldPersistence.clear_players()
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
	if not WorldPersistence.has_save():
		WorldPersistence.clear_map_markers()
		WorldPersistence.clear_players()
	while true:
		var player_hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
			tool,
			bootstrap._terrain,
			probe_origin,
			probe_dir,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if player_hit != null:
			var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
				bootstrap._terrain,
				probe_origin,
				probe_dir,
				player_hit
			)
			var spawn_position: Vector3 = await resolve_spawn_with_floor(
				bootstrap,
				probe_origin,
				probe_dir,
				sdf_point,
				PHYSICS_GROUND_TIMEOUT_MS
			)
			await begin_fresh_world(bootstrap, spawn_position)
			return

		bootstrap._loading.text = "Стриминг луны..."
		await bootstrap.get_tree().physics_frame


static func peek_saved_player_position(bootstrap) -> Vector3:
	if not WorldPersistence.has_save():
		return Vector3.ZERO
	var payload: Dictionary = WorldPersistence.read_payload()
	if payload.is_empty():
		return Vector3.ZERO
	WorldPersistence.restore_players_from_payload(payload)
	var row := WorldPersistence.player_pose_row(PlayerIdentity.local_uid())
	var position_data: Variant = row.get("position", [])
	if position_data is Array and position_data.size() >= 3:
		return Vector3(
			float(position_data[0]),
			float(position_data[1]),
			float(position_data[2]),
		)
	return Vector3.ZERO


## Wait until a cooked voxel collider exists under `hint` (SDF alone is not
## enough for raycast-wheel locomotives). Returns physics surface or NaN.
static func await_physics_ground_at(
	bootstrap,
	hint: Vector3,
	label: String,
	timeout_ms: int = PHYSICS_GROUND_TIMEOUT_MS
) -> Vector3:
	if not is_finite_vec3(hint) or bootstrap._gravity_field == null:
		return Vector3(NAN, NAN, NAN)
	var origin := MoonGeometry.spawn_hold_point(hint)
	var direction: Vector3 = bootstrap._gravity_field.probe_direction_toward_ground(origin)
	var wait_start_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait_start_ms < timeout_ms:
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			physics_space_state(bootstrap),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if is_finite_vec3(physics_point):
			var waited := Time.get_ticks_msec() - wait_start_ms
			if waited > 0:
				print(
					"MoonExperiment: %s physics ground ready at %s (waited %d ms)"
					% [label, str(physics_point), waited]
				)
			return physics_point
		await bootstrap.get_tree().physics_frame
	push_warning(
		"%s: physics collider not ready near %s after %d ms"
		% [label, str(hint), timeout_ms]
	)
	return Vector3(NAN, NAN, NAN)


static func resolve_spawn_with_floor(
	bootstrap,
	origin: Vector3,
	direction: Vector3,
	sdf_point: Vector3,
	timeout_ms: int = PHYSICS_GROUND_TIMEOUT_MS
) -> Vector3:
	bootstrap._loading.text = "Стриминг коллизии луны..."
	var wait_start_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait_start_ms < timeout_ms:
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			physics_space_state(bootstrap),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
		if is_finite_vec3(physics_point):
			print(
				"MoonExperiment: physics ground ready at %s (waited %d ms)"
				% [str(physics_point), Time.get_ticks_msec() - wait_start_ms]
			)
			var up: Vector3 = bootstrap._gravity_field.up_at(physics_point)
			bootstrap._player_spawn_pos = (
				physics_point + up * MoonGeometry.SPAWN_CLEARANCE_M
			)
			return bootstrap._player_spawn_pos
		var meshed_hint := sdf_point if is_finite_vec3(sdf_point) else origin
		if is_spawn_area_meshed(bootstrap, meshed_hint):
			bootstrap._loading.text = "Коллизия луны..."
		else:
			bootstrap._loading.text = "Стриминг коллизии луны..."
		await bootstrap.get_tree().physics_frame

	var surface := sdf_point
	if not is_finite_vec3(surface):
		surface = MoonGeometry.surface_point(bootstrap._player_spawn_hint)
	print(
		"MoonExperiment: voxel collider pending; landing pad at %s (waited %d ms)"
		% [str(surface), timeout_ms]
	)
	bootstrap._player_spawn_pos = install_landing_pad(bootstrap, surface)
	return bootstrap._player_spawn_pos


static func install_landing_pad(bootstrap, surface: Vector3) -> Vector3:
	remove_landing_pad(bootstrap)
	var up: Vector3 = bootstrap._gravity_field.up_at(surface)
	var surface_basis: Basis = bootstrap._gravity_field.tangent_basis_at(surface)
	var body := StaticBody3D.new()
	body.name = "MoonLandingPad"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = LANDING_PAD_SIZE_M
	shape_node.shape = box
	body.add_child(shape_node)
	bootstrap.add_child(body)
	## Top face of the box sits on the SDF surface.
	body.global_transform = Transform3D(
		surface_basis,
		surface - up * (LANDING_PAD_SIZE_M.y * 0.5)
	)
	bootstrap._landing_pad = body
	bootstrap.call_deferred("_retire_landing_pad_when_voxel_floor_ready", surface)
	return surface + up * MoonGeometry.SPAWN_CLEARANCE_M


static func remove_landing_pad(bootstrap) -> void:
	if bootstrap._landing_pad != null and is_instance_valid(bootstrap._landing_pad):
		bootstrap._landing_pad.queue_free()
	bootstrap._landing_pad = null


static func retire_landing_pad_when_voxel_floor_ready(
	bootstrap,
	surface: Vector3
) -> void:
	var origin := MoonGeometry.spawn_hold_point(surface)
	var direction: Vector3 = bootstrap._gravity_field.probe_direction_toward_ground(origin)
	var deadline_ms := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline_ms:
		if bootstrap._landing_pad == null or not is_instance_valid(bootstrap._landing_pad):
			return
		var exclude: Array[RID] = []
		exclude.append(bootstrap._landing_pad.get_rid())
		var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
			physics_space_state(bootstrap),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M,
			1,
			exclude
		)
		if is_finite_vec3(physics_point):
			print(
				"MoonExperiment: voxel floor ready, retiring landing pad at %s"
				% str(physics_point)
			)
			remove_landing_pad(bootstrap)
			return
		await bootstrap.get_tree().create_timer(0.5).timeout
	push_warning("Landing pad kept: voxel collider never appeared under spawn")


static func is_spawn_area_meshed(bootstrap, world_hint: Vector3) -> bool:
	if not (bootstrap._terrain is VoxelLodTerrain):
		return false
	var lod := bootstrap._terrain as VoxelLodTerrain
	var local := VoxelSpaceUtil.world_to_local(bootstrap._terrain, world_hint)
	var area := AABB(local - Vector3.ONE * 4.0, Vector3.ONE * 8.0)
	return lod.is_area_meshed(area, 0)


static func is_finite_vec3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


static func snap_spawn_to_ground(bootstrap, near_position: Vector3) -> Vector3:
	var hint := near_position
	if hint.length_squared() <= 0.000001:
		hint = bootstrap._player_spawn_hint
	var origin := MoonGeometry.spawn_hold_point(hint)
	var direction: Vector3 = bootstrap._gravity_field.probe_direction_toward_ground(origin)
	var exclude: Array[RID] = []
	if bootstrap._landing_pad != null and is_instance_valid(bootstrap._landing_pad):
		exclude.append(bootstrap._landing_pad.get_rid())
	var physics_point := VoxelSpaceUtil.physics_surface_along_ray(
		physics_space_state(bootstrap),
		origin,
		direction,
		MoonGeometry.GROUND_PROBE_DISTANCE_M,
		1,
		exclude
	)
	var surface := physics_point
	if not is_finite_vec3(surface):
		## Prefer the temp pad / any collider including the pad.
		surface = VoxelSpaceUtil.physics_surface_along_ray(
			physics_space_state(bootstrap),
			origin,
			direction,
			MoonGeometry.GROUND_PROBE_DISTANCE_M
		)
	if not is_finite_vec3(surface):
		var tool: VoxelTool = TerrainCompat.get_voxel_tool(bootstrap._terrain)
		if tool != null:
			tool.channel = VoxelBuffer.CHANNEL_SDF
			var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
				tool,
				bootstrap._terrain,
				origin,
				direction,
				MoonGeometry.GROUND_PROBE_DISTANCE_M
			)
			if hit != null:
				surface = VoxelSpaceUtil.raycast_hit_world_point(
					bootstrap._terrain,
					origin,
					direction,
					hit
				)
	if not is_finite_vec3(surface):
		surface = MoonGeometry.surface_point(hint)
	if bootstrap._landing_pad == null:
		return install_landing_pad(bootstrap, surface)
	var up: Vector3 = bootstrap._gravity_field.up_at(surface)
	return surface + up * MoonGeometry.SPAWN_CLEARANCE_M


static func spawn_position_from_voxel_hit(
	bootstrap,
	origin: Vector3,
	direction: Vector3,
	hit: VoxelRaycastResult
) -> Vector3:
	var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
		bootstrap._terrain,
		origin,
		direction,
		hit
	)
	var surface := VoxelSpaceUtil.resolve_ground_surface_along_ray(
		physics_space_state(bootstrap),
		origin,
		direction,
		sdf_point,
		MoonGeometry.GROUND_PROBE_DISTANCE_M
	)
	var up: Vector3 = bootstrap._gravity_field.up_at(surface)
	bootstrap._player_spawn_pos = surface + up * MoonGeometry.SPAWN_CLEARANCE_M
	return bootstrap._player_spawn_pos


static func physics_space_state(bootstrap) -> PhysicsDirectSpaceState3D:
	if bootstrap._terrain == null or not bootstrap._terrain.is_inside_tree():
		return null
	return bootstrap._terrain.get_world_3d().direct_space_state


static func resolve_saved_player_position(
	bootstrap,
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
			if is_usable_saved_player_position(saved):
				return saved
	var hint: Vector3 = bootstrap._player_spawn_hint
	var origin := MoonGeometry.spawn_hold_point(hint)
	var direction: Vector3 = bootstrap._gravity_field.probe_direction_toward_ground(origin)
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		bootstrap._terrain,
		origin,
		direction,
		MoonGeometry.GROUND_PROBE_DISTANCE_M
	)
	if hit != null:
		return spawn_position_from_voxel_hit(bootstrap, origin, direction, hit)
	return MoonGeometry.surface_point(hint) + (
		bootstrap._gravity_field.up_at(hint) * MoonGeometry.SPAWN_CLEARANCE_M
	)


static func is_usable_saved_player_position(pos: Vector3) -> bool:
	if not pos.is_finite():
		return false
	# Reject near-origin flat-world leftovers if a wrong save is loaded.
	if pos.length() < MoonGeometry.active_surface_radius_m() * 0.5:
		return false
	## Relief is active_surface_radius_m ± HEIGHT_CLAMP_M; reject stale saves.
	var min_r := (
		MoonGeometry.active_surface_radius_m()
		- MoonTerrainParams.HEIGHT_CLAMP_M
		- 10.0
	)
	var max_r := (
		MoonGeometry.active_surface_radius_m()
		+ MoonTerrainParams.HEIGHT_CLAMP_M
		+ MoonGeometry.SPAWN_SKY_OFFSET_M
	)
	var r := pos.length()
	if r < min_r or r > max_r:
		return false
	## Reject saved positions sitting on the equirectangular pole pinch (±Y);
	## fall back to the off-pole fresh spawn instead.
	return absf(pos.normalized().y) <= 0.7
