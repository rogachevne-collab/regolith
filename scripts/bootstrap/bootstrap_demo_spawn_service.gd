class_name BootstrapDemoSpawnService
extends RefCounted

## Must match bootstrap.gd constants.
const DEMO_ROVER_OFFSET_M := 32.0
const DEBUG_ROVER_SPAWN_OFFSET_M := 6.0
const DEBUG_PLATFORM_SPAWN_OFFSET_M := 18.0
const DEMO_HOPPER_OFFSET_M := 68.0
const _PlatformComposer := preload("res://scripts/authoring/platform_composer.gd")
const LAMP_POLE_SCENE := preload("res://scenes/props/lamp_pole.tscn")
const LAMP_POLE_OFFSETS_M: Array[Vector3] = [
	Vector3(6.0, 0.0, 4.0),
	Vector3(-5.0, 0.0, 7.0),
	Vector3(2.0, 0.0, -8.0),
]


static func sync_demo_spawn_anchor(bootstrap) -> void:
	if bootstrap._base_spawn == null or bootstrap._player == null:
		return
	var anchor: Vector3 = bootstrap._player.global_position
	if anchor.length_squared() <= 0.000001:
		return
	bootstrap._base_spawn.global_position = anchor


static func demo_spawn_hint_offset(
	bootstrap,
	local_axis: Vector3,
	offset_m: float
) -> Vector3:
	var anchor := Vector3.ZERO
	if (
		bootstrap._player != null
		and bootstrap._player.global_position.length_squared() > 0.000001
	):
		anchor = bootstrap._player.global_position
	elif bootstrap._base_spawn != null:
		anchor = bootstrap._base_spawn.global_position
	else:
		anchor = MoonGeometry.surface_point(Vector3.UP)
	if bootstrap._gravity_field == null:
		return anchor + local_axis * offset_m
	var basis: Basis = bootstrap._gravity_field.tangent_basis_at(anchor)
	var world_axis: Vector3 = (
		basis.x * local_axis.x
		+ basis.y * local_axis.y
		+ basis.z * local_axis.z
	)
	if world_axis.length_squared() <= 0.000001:
		world_axis = basis.z
	return anchor + world_axis.normalized() * offset_m


static func apply_playtest_cargo_if_enabled(bootstrap) -> void:
	if not bootstrap.playtest_cargo or bootstrap._session == null or bootstrap._session.world == null:
		return
	if not IndustryStoreService.apply_playtest_cargo(
		bootstrap._session.world,
		PlayerIdentity.local_uid()
	):
		push_error("Playtest cargo seed failed")


static func spawn_lamp_poles_near_player(bootstrap) -> void:
	if bootstrap.get_node_or_null("LampPoles") != null:
		return
	var root := Node3D.new()
	root.name = "LampPoles"
	bootstrap.add_child(root)
	var space: PhysicsDirectSpaceState3D = bootstrap._physics_space_state()
	var placed := 0
	for local_off in LAMP_POLE_OFFSETS_M:
		var hint := demo_spawn_hint_offset(
			bootstrap, local_off.normalized(), local_off.length()
		)
		var up := Vector3.UP
		if bootstrap._gravity_field != null:
			up = bootstrap._gravity_field.up_at(hint)
		var ground := hint
		if space != null:
			var from := hint + up * 40.0
			var to := hint - up * 80.0
			var q := PhysicsRayQueryParameters3D.create(from, to)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				ground = hit["position"] as Vector3
		var pole: Node3D = LAMP_POLE_SCENE.instantiate()
		root.add_child(pole)
		var basis := Basis.IDENTITY
		if bootstrap._gravity_field != null:
			basis = bootstrap._gravity_field.tangent_basis_at(ground)
		pole.global_transform = Transform3D(basis, ground)
		placed += 1
	print("MoonExperiment: spawned %d lamp poles near player" % placed)


static func spawn_demo_rover_near_player(bootstrap) -> void:
	var hint := demo_spawn_hint_offset(
		bootstrap, Vector3(0.0, 0.0, -1.0), DEMO_ROVER_OFFSET_M
	)
	await spawn_rover_at_hint(bootstrap, hint, "Demo rover")


static func spawn_debug_rover_near_player(bootstrap) -> void:
	if bootstrap._debug_rover_spawn_busy:
		return
	bootstrap._debug_rover_spawn_busy = true
	print("MoonExperiment: U → spawn debug rover…")
	set_debug_spawn_status(bootstrap, "U: собираю ровер перед тобой…")
	# Seat on the aim point in front of the camera — do not wander for a
	# "best flat" patch (that parked the rover ~20m away while compose ran).
	var hint: Vector3 = debug_rover_spawn_hint(bootstrap)
	await spawn_rover_at_hint(bootstrap, hint, "Debug rover (U)", true)
	bootstrap._debug_rover_spawn_busy = false


static func spawn_debug_platform_near_player(bootstrap) -> void:
	if bootstrap._debug_platform_spawn_busy:
		return
	bootstrap._debug_platform_spawn_busy = true
	print("MoonExperiment: , → spawn debug platform…")
	set_debug_spawn_status(bootstrap, ",: собираю платформу 6×8…")
	var hint: Vector3 = debug_platform_spawn_hint(bootstrap)
	await spawn_platform_at_hint(bootstrap, hint, "Debug platform (,)")
	bootstrap._debug_platform_spawn_busy = false


static func debug_platform_spawn_hint(bootstrap) -> Vector3:
	var origin: Vector3 = bootstrap._player.global_position
	var forward: Vector3 = player_flat_forward(bootstrap)
	var camera: Camera3D = bootstrap._player.get_node_or_null("Camera") as Camera3D
	if camera != null and camera.has_method("aim_transform"):
		var aim: Transform3D = camera.call("aim_transform")
		origin = aim.origin
		forward = -aim.basis.z
		if bootstrap._gravity_field != null:
			var up: Vector3 = bootstrap._gravity_field.up_at(origin)
			forward = (forward - up * forward.dot(up)).normalized()
			if forward.length_squared() <= 0.000001:
				forward = player_flat_forward(bootstrap)
	return origin + forward * DEBUG_PLATFORM_SPAWN_OFFSET_M


static func spawn_platform_at_hint(
	bootstrap,
	hint: Vector3,
	label: String
) -> void:
	if bootstrap._session == null:
		push_warning("%s spawn failed: no session" % label)
		return
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(bootstrap._terrain)
	if tool == null:
		push_warning("%s spawn failed: no voxel tool" % label)
		set_debug_spawn_status(bootstrap, "%s: нет voxel tool" % label)
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var space: PhysicsDirectSpaceState3D = bootstrap._physics_space_state()
	var surface_variant: Variant = RoverDemoSpawn._ground_point_along_field(
		bootstrap._terrain,
		tool,
		space,
		hint
	)
	var ground: Vector3 = (
		surface_variant as Vector3 if surface_variant is Vector3 else hint
	)
	ground = await bootstrap._await_physics_ground_at(ground, label)
	if not bootstrap._is_finite_vec3(ground):
		set_debug_spawn_status(
			bootstrap, "%s: нет physics-коллизии под точкой спавна" % label
		)
		return
	var t0 := Time.get_ticks_msec()
	var result: Dictionary = _PlatformComposer.spawn_on_terrain(
		bootstrap._session,
		ground,
		RoverDemoSpawn.STORE_ID,
		bootstrap._terrain,
		tool,
		space
	)
	var assembly_id := int(result.get("assembly_id", 0))
	var body_pos := Vector3(NAN, NAN, NAN)
	if (
		bool(result.get("ok", false))
		and assembly_id > 0
		and bootstrap._session.projection != null
	):
		var body: RigidBody3D = bootstrap._session.projection.get_physics_body(
			assembly_id
		)
		if body != null:
			body_pos = body.global_position
	var dist: float = (
		bootstrap._player.global_position.distance_to(body_pos)
		if bootstrap._is_finite_vec3(body_pos) and bootstrap._player != null
		else -1.0
	)
	if not bool(result.get("ok", false)):
		push_warning(
			"%s spawn failed: %s"
			% [label, str(result.get("error", "unknown"))]
		)
		set_debug_spawn_status(
			bootstrap, "%s FAIL: %s" % [label, str(result.get("error", "unknown"))]
		)
	else:
		print(
			(
				"MoonExperiment: %s spawned assembly_id=%d body=%s "
				+ "dist=%.1fm compose=%dms"
			)
			% [
				label,
				assembly_id,
				str(body_pos),
				dist,
				Time.get_ticks_msec() - t0,
			]
		)
		set_debug_spawn_status(
			bootstrap,
			",: платформа #%d рядом (%.0fm). Собиралась %dms."
			% [assembly_id, dist, Time.get_ticks_msec() - t0]
		)


static func player_flat_forward(bootstrap) -> Vector3:
	if bootstrap._player == null:
		return Vector3.FORWARD
	var forward: Vector3 = -bootstrap._player.global_transform.basis.z
	if bootstrap._gravity_field != null:
		var up: Vector3 = bootstrap._gravity_field.up_at(bootstrap._player.global_position)
		forward = forward - up * forward.dot(up)
	if forward.length_squared() <= 0.000001:
		var basis: Basis = bootstrap._gravity_field.tangent_basis_at(bootstrap._player.global_position)
		return -basis.z
	return forward.normalized()


static func debug_rover_spawn_hint(bootstrap) -> Vector3:
	var origin: Vector3 = bootstrap._player.global_position
	var forward: Vector3 = player_flat_forward(bootstrap)
	var camera: Camera3D = bootstrap._player.get_node_or_null("Camera") as Camera3D
	if camera != null and camera.has_method("aim_transform"):
		var aim: Transform3D = camera.call("aim_transform")
		origin = aim.origin
		forward = -aim.basis.z
		if bootstrap._gravity_field != null:
			var up: Vector3 = bootstrap._gravity_field.up_at(origin)
			forward = (forward - up * forward.dot(up)).normalized()
			if forward.length_squared() <= 0.000001:
				forward = player_flat_forward(bootstrap)
	return origin + forward * DEBUG_ROVER_SPAWN_OFFSET_M


static func set_debug_spawn_status(bootstrap, text: String) -> void:
	if bootstrap._hint != null:
		bootstrap._hint.text = text


static func spawn_rover_at_hint(
	bootstrap,
	hint: Vector3,
	label: String,
	immediate_hint: bool = false
) -> void:
	if bootstrap._session == null:
		push_warning("%s spawn failed: no session" % label)
		return
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(bootstrap._terrain)
	if tool == null:
		push_warning("%s spawn failed: no voxel tool" % label)
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var space: PhysicsDirectSpaceState3D = bootstrap._physics_space_state()
	var ground: Vector3 = Vector3(NAN, NAN, NAN)
	if immediate_hint:
		# Aim point may be mid-air; seat along gravity to the crust first.
		var surface_variant: Variant = RoverDemoSpawn._ground_point_along_field(
			bootstrap._terrain,
			tool,
			space,
			hint
		)
		ground = surface_variant as Vector3 if surface_variant is Vector3 else hint
	else:
		for _attempt in 30:
			var flat_variant: Variant = RoverDemoSpawn.find_flat_ground_near(
				bootstrap._terrain,
				tool,
				space,
				hint,
				24.0,
				3.0,
				false
			)
			if flat_variant is Vector3:
				ground = flat_variant as Vector3
				break
			await bootstrap.get_tree().physics_frame
		if not bootstrap._is_finite_vec3(ground):
			ground = hint
			print("%s: no flat patch, seating at hint" % label)
	if not bootstrap._is_finite_vec3(ground):
		push_warning("%s spawn failed: no ground near player" % label)
		set_debug_spawn_status(bootstrap, "%s: нет земли под точкой спавна" % label)
		return
	# Wheel locomotives are raycast-supported (solid wheel colliders off).
	# SDF seating before the voxel trimesh cooks → freefall through crust.
	ground = await bootstrap._await_physics_ground_at(ground, label)
	if not bootstrap._is_finite_vec3(ground):
		set_debug_spawn_status(
			bootstrap, "%s: нет physics-коллизии под точкой спавна" % label
		)
		return
	var phrase: String = bootstrap.demo_rover_phrase.strip_edges()
	var t0 := Time.get_ticks_msec()
	var result: Dictionary
	if phrase.is_empty():
		# Пустая фраза = дефолтная сборка тем же композером, что и по фразе.
		# Отдельного «демо-ровера» по зашитым клеткам больше нет.
		result = RoverComposer.spawn_on_terrain(
			bootstrap._session,
			ground,
			null,
			RoverDemoSpawn.STORE_ID,
			bootstrap._terrain,
			tool,
			space
		)
	else:
		result = RoverComposer.spawn_on_terrain_from_phrase(
			bootstrap._session,
			ground,
			phrase,
			RoverDemoSpawn.STORE_ID,
			bootstrap._terrain,
			tool,
			space
		)
	var body_pos := Vector3(NAN, NAN, NAN)
	var assembly_id := int(result.get("assembly_id", 0))
	if (
		bool(result.get("ok", false))
		and assembly_id > 0
		and bootstrap._session.projection != null
	):
		var body: RigidBody3D = bootstrap._session.projection.get_physics_body(assembly_id)
		if body != null:
			body_pos = body.global_position
	var dist: float = (
		bootstrap._player.global_position.distance_to(body_pos)
		if bootstrap._is_finite_vec3(body_pos) and bootstrap._player != null
		else -1.0
	)
	if not bool(result.get("ok", false)):
		push_warning(
			"%s spawn failed: %s %s"
			% [
				label,
				str(result.get("error", "unknown")),
				str(result.get("failures", [])),
			]
		)
		set_debug_spawn_status(
			bootstrap, "%s FAIL: %s" % [label, str(result.get("error", "unknown"))]
		)
	else:
		print(
			(
				"MoonExperiment: %s spawned assembly_id=%d body=%s "
				+ "dist=%.1fm compose=%dms phrase='%s'"
			)
			% [
				label,
				assembly_id,
				str(body_pos),
				dist,
				Time.get_ticks_msec() - t0,
				phrase,
			]
		)
		set_debug_spawn_status(
			bootstrap,
			"U: ровер #%d рядом (%.0fm). Собирался %dms."
			% [assembly_id, dist, Time.get_ticks_msec() - t0]
		)


static func spawn_demo_hopper_near_player(bootstrap) -> void:
	if bootstrap._session == null or bootstrap._base_spawn == null:
		return
	var tool: VoxelTool = TerrainCompat.get_voxel_tool(bootstrap._terrain)
	if tool == null:
		return
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var hint := demo_spawn_hint_offset(
		bootstrap, Vector3(1.0, 0.0, 0.0), DEMO_HOPPER_OFFSET_M
	)
	var ground: Vector3 = Vector3(NAN, NAN, NAN)
	for _attempt in 90:
		var ground_variant: Variant = RoverDemoSpawn.find_flat_ground_near(
			bootstrap._terrain,
			tool,
			bootstrap._physics_space_state(),
			hint,
			12.0,
			4.0,
			true
		)
		if ground_variant is Vector3:
			ground = ground_variant as Vector3
			break
		await bootstrap.get_tree().physics_frame
	if not bootstrap._is_finite_vec3(ground):
		push_warning("Demo hopper spawn failed: no flat ground near offset hint")
		return
	ground = await bootstrap._await_physics_ground_at(ground, "Demo hopper")
	if not bootstrap._is_finite_vec3(ground):
		return
	var result: Dictionary = HopperDemoSpawn.spawn_on_terrain(
		bootstrap._session,
		ground,
		HopperDemoSpawn.STORE_ID,
		bootstrap._terrain,
		tool,
		bootstrap._physics_space_state()
	)
	if not bool(result.get("ok", false)):
		push_warning(
			"Demo hopper spawn failed: %s"
			% str(result.get("error", "unknown"))
		)
	else:
		print(
			"MoonExperiment: demo hopper spawned assembly_id=%d at %s"
			% [int(result.get("assembly_id", 0)), str(ground)]
		)
