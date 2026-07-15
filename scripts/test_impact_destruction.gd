extends Node3D

const PISTON_BASE := preload(
	"res://resources/archetypes/slice01/piston_base.tres"
)
const PISTON_HEAD := preload(
	"res://resources/archetypes/slice01/piston_head.tres"
)


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var tests: Array[Callable] = [
		_test_damage_scales_with_impulse,
		_test_weak_impulse_ignored,
		_test_fallback_impulse_uses_separating_velocity,
		_test_terrain_carve_changes_sdf,
		_test_carve_respects_volume_budget,
		_test_mesh_stamp_carves_terrain,
		_test_sustained_grind_carves_trench,
		_test_assembly_contact_damages_both,
		_test_shape_enter_carves_terrain,
		_test_subgrid_immunity_ignores_same_assembly,
		_test_sustained_actuator_carves_terrain,
		_test_sustained_actuator_damages_striker,
		_test_kinetic_loot_threshold,
		_test_player_hit_damages_suit,
	]
	for test: Callable in tests:
		if not bool(await test.call()):
			return
	if not await _test_carriage_monitor_only_configured():
		return
	if not await _test_physics_fall_damages_structure():
		return
	print("KINETIC-INTERACTION-V1: PASS")
	get_tree().quit(0)


func _test_damage_scales_with_impulse() -> bool:
	var weak: float = ImpactResolver.damage_amount(8.0, 100.0)
	var strong: float = ImpactResolver.damage_amount(48.0, 100.0)
	if weak <= 0.0 or strong <= weak:
		return _fail("damage does not scale with impulse")
	return true


func _test_weak_impulse_ignored() -> bool:
	if ImpactResolver.damage_amount(2.0, 100.0) != 0.0:
		return _fail("sub-threshold impulse applied damage")
	return true


func _test_fallback_impulse_uses_separating_velocity() -> bool:
	var body := RigidBody3D.new()
	body.mass = 10.0
	body.linear_velocity = Vector3(3.0, -4.0, 0.0)
	var along_normal: float = ImpactResolver.fallback_impulse_length(
		body,
		null,
		Vector3.UP
	)
	var raw_speed: float = body.linear_velocity.length() * body.mass
	body.queue_free()
	if not is_equal_approx(along_normal, 40.0):
		return _fail(
			"fallback impulse expected 40 got %.3f" % along_normal
		)
	if along_normal >= raw_speed:
		return _fail("fallback should ignore tangential velocity")
	return true


func _test_subgrid_immunity_ignores_same_assembly() -> bool:
	var fixture := await _new_fixture()
	var piston := await _spawn_piston_on_ground(fixture)
	if piston.is_empty():
		_free_fixture(fixture)
		return _fail("subgrid piston spawn failed")
	var head_id := int(piston["head_element_id"])
	var base_id := int(piston["base_element_id"])
	var head_body: PhysicsBody3D = (
		fixture.projection.get_element_projection(head_id).get("body")
	)
	var base_body: PhysicsBody3D = (
		fixture.projection.get_element_projection(base_id).get("body")
	)
	if head_body == null or base_body == null:
		_free_fixture(fixture)
		return _fail("subgrid bodies missing")
	var integrity_before: float = (
		fixture.world.get_element(head_id).integrity
	)
	fixture.impact_service.apply_entry_for_test({
		"batch_key": "subgrid_test",
		"striker_element_id": head_id,
		"striker_body": head_body,
		"local_shape_index": 0,
		"partner": base_body,
		"impulse_length": 48.0,
		"contact_world": head_body.global_position,
		"contact_points": PackedVector3Array([head_body.global_position]),
		"contact_impulses": PackedFloat32Array([48.0]),
	})
	var integrity_after: float = fixture.world.get_element(head_id).integrity
	_free_fixture(fixture)
	if integrity_after < integrity_before:
		return _fail("same-assembly contact damaged striker")
	return true


func _test_sustained_actuator_carves_terrain() -> bool:
	var fixture := await _new_fixture()
	var piston := await _spawn_piston_on_ground(fixture)
	if piston.is_empty():
		_free_fixture(fixture)
		return _fail("sustained carve piston spawn failed")
	var head_id := int(piston["head_element_id"])
	var head_body: RigidBody3D = (
		fixture.projection.get_element_projection(head_id).get("body")
	)
	if head_body == null:
		_free_fixture(fixture)
		return _fail("sustained carve head body missing")
	var tool: VoxelTool = fixture.terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var contact_world := head_body.global_position + Vector3.DOWN * 0.5
	var sample := contact_world + Vector3(0.0, -0.25, 0.0)
	var sdf_before: float = _terrain_sdf_at(tool, sample)
	var used_volume: float = (
		fixture.impact_service.emit_actuator_sustained_entry_for_test(
			head_id,
			head_body,
			fixture.terrain,
			240_000.0,
			1.0 / 60.0,
			0,
			contact_world
		)
	)
	var sdf_after: float = _terrain_sdf_at(tool, sample)
	_free_fixture(fixture)
	if used_volume <= 0.0:
		return _fail("sustained actuator carved zero volume")
	if not (sdf_after > sdf_before + 0.05):
		return _fail(
			"sustained actuator did not carve terrain %.3f -> %.3f"
			% [sdf_before, sdf_after]
		)
	return true


func _test_sustained_actuator_damages_striker() -> bool:
	var fixture := await _new_fixture()
	var spawn := _spawn_single(fixture.world)
	if not spawn.is_ok():
		_free_fixture(fixture)
		return _fail("sustained damage spawn failed")
	var element_id := int(spawn.data["element_ids"][0])
	var body: RigidBody3D = fixture.projection.get_physics_body(
		int(spawn.data["assembly_id"])
	) as RigidBody3D
	if body == null:
		_free_fixture(fixture)
		return _fail("sustained damage body missing")
	var element: SimulationElement = fixture.world.get_element(element_id)
	if element == null:
		_free_fixture(fixture)
		return _fail("sustained damage element missing")
	var integrity_before: float = element.integrity
	var impulse_length := 600.0 * (1.0 / 60.0)
	fixture.impact_service.apply_entry_for_test({
		"batch_key": "sustained_damage_test",
		"striker_element_id": element_id,
		"striker_body": body,
		"local_shape_index": 0,
		"partner": fixture.terrain,
		"impulse_length": impulse_length,
		"contact_world": body.global_position,
		"contact_points": PackedVector3Array([body.global_position]),
		"contact_impulses": PackedFloat32Array([impulse_length]),
	})
	element = fixture.world.get_element(element_id)
	if element == null:
		_free_fixture(fixture)
		return _fail("sustained impulse removed striker")
	var integrity_after: float = element.integrity
	_free_fixture(fixture)
	if integrity_after >= integrity_before:
		return _fail("sustained-scale impulse did not damage striker")
	return true


func _test_kinetic_loot_threshold() -> bool:
	var fixture := await _new_fixture()
	var spawn := _spawn_single(fixture.world)
	if not spawn.is_ok():
		_free_fixture(fixture)
		return _fail("loot spawn failed")
	var element_id := int(spawn.data["element_ids"][0])
	var body: RigidBody3D = fixture.projection.get_physics_body(
		int(spawn.data["assembly_id"])
	) as RigidBody3D
	if body == null:
		_free_fixture(fixture)
		return _fail("loot body missing")
	var weak_entry := {
		"batch_key": "loot_weak",
		"striker_element_id": element_id,
		"striker_body": body,
		"local_shape_index": 0,
		"partner": fixture.terrain,
		"impulse_length": 8.0,
		"contact_world": Vector3(0.5, 0.0, 0.5),
		"contact_points": PackedVector3Array([Vector3(0.5, 0.0, 0.5)]),
		"contact_impulses": PackedFloat32Array([8.0]),
	}
	fixture.impact_service.apply_entry_for_test(weak_entry)
	if not fixture.world.list_world_loot_piles().is_empty():
		_free_fixture(fixture)
		return _fail("sub-threshold impact dropped loot")
	var strong_entry := weak_entry.duplicate(true)
	strong_entry["batch_key"] = "loot_strong"
	strong_entry["impulse_length"] = 36.0
	strong_entry["contact_world"] = Vector3(3.5, 0.0, 3.5)
	strong_entry["striker_body"] = body
	strong_entry["partner"] = fixture.terrain
	var carved: float = fixture.impact_service.apply_entry_for_test(
		strong_entry
	)
	var piles: Array[Dictionary] = fixture.world.list_world_loot_piles()
	_free_fixture(fixture)
	if carved <= 0.0:
		return _fail("loot impact carved nothing")
	if piles.is_empty():
		return _fail("above-threshold impact dropped no loot")
	var mass := float(piles[0].get("amount_kg", 0.0))
	var expected := (
		carved
		* TerrainMaterialSource.REGOLITH_DENSITY_KG_PER_M3
		* ImpactResolver.KINETIC_COLLECTIBLE_FRACTION
	)
	if absf(mass - expected) > expected * 0.05 + 0.001:
		return _fail(
			"loot mass %.2f != expected %.2f" % [mass, expected]
		)
	return true


func _test_player_hit_damages_suit() -> bool:
	var fixture := await _new_fixture()
	var spawn := _spawn_single(fixture.world)
	if not spawn.is_ok():
		_free_fixture(fixture)
		return _fail("player-hit spawn failed")
	var element_id := int(spawn.data["element_ids"][0])
	var body: RigidBody3D = fixture.projection.get_physics_body(
		int(spawn.data["assembly_id"])
	) as RigidBody3D
	var player := CharacterBody3D.new()
	var suit := SuitState.new()
	suit.name = "SuitState"
	suit.simulate = false
	player.add_child(suit)
	add_child(player)
	var entry := {
		"batch_key": "player_hit_test",
		"striker_element_id": element_id,
		"striker_body": body,
		"local_shape_index": 0,
		"partner": player,
		"impulse_length": 2.0,
		"contact_world": Vector3.ZERO,
		"contact_points": PackedVector3Array(),
		"contact_impulses": PackedFloat32Array(),
	}
	var element_before: float = fixture.world.get_element(element_id).integrity
	fixture.impact_service.apply_entry_for_test(entry)
	if suit.health < suit.health_max:
		player.queue_free()
		_free_fixture(fixture)
		return _fail("sub-threshold hit hurt the player")
	entry["impulse_length"] = 36.0
	var carved: float = fixture.impact_service.apply_entry_for_test(entry)
	var health_after_first: float = suit.health
	fixture.impact_service.apply_entry_for_test(entry)
	var health_after_second: float = suit.health
	var element_after: float = fixture.world.get_element(element_id).integrity
	player.queue_free()
	_free_fixture(fixture)
	if health_after_first >= suit.health_max:
		return _fail("strong hit did not damage the player")
	if carved != 0.0:
		return _fail("player hit must not carve terrain")
	if element_after < element_before:
		return _fail("player hit damaged the striker element")
	if health_after_second < health_after_first:
		return _fail("player hit ignored the personal cooldown")
	return true


func _test_carriage_monitor_only_configured() -> bool:
	var fixture := await _new_fixture()
	var piston := await _spawn_piston_on_ground(fixture)
	if piston.is_empty():
		_free_fixture(fixture)
		return _fail("monitor-only piston spawn failed")
	var head_id := int(piston["head_element_id"])
	var head_body: PhysicsBody3D = (
		fixture.projection.get_element_projection(head_id).get("body")
	)
	_free_fixture(fixture)
	if head_body == null:
		return _fail("monitor-only head body missing")
	if not head_body.has_meta("impact_monitoring"):
		return _fail("carriage missing impact monitoring")
	if int(head_body.get_meta("impact_body_mode", -1)) != (
		ImpactResolverService.ImpactBodyMode.MONITOR_ONLY
	):
		return _fail("carriage impact mode is not MONITOR_ONLY")
	if head_body.custom_integrator:
		return _fail("carriage must keep custom_integrator disabled")
	return true


func _test_terrain_carve_changes_sdf() -> bool:
	var fixture := await _new_fixture()
	var tool: VoxelTool = fixture.terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var sample := Vector3(0.5, -0.5, 0.5)
	var before := _terrain_sdf_at(tool, sample)
	var carved: float = fixture.gateway.apply_terrain_carve({
		"stamp_kind": &"sphere",
		"center": sample,
		"radius": 1.2,
		"strength": 1.0,
	})
	if carved <= 0.0:
		_free_fixture(fixture)
		return _fail("terrain carve reported zero volume")
	var after := _terrain_sdf_at(tool, sample)
	_free_fixture(fixture)
	if not (after > before + 0.05):
		return _fail(
			"terrain sdf did not change enough before=%.3f after=%.3f"
			% [before, after]
		)
	return true


func _test_carve_respects_volume_budget() -> bool:
	var fixture := await _new_fixture()
	# Fitted radius must stay above minimum_measurable_radius_m (0.45 at
	# voxel size 1.0), so the budget cannot be arbitrarily small here.
	var budget := 0.5
	var carved: float = fixture.gateway.apply_terrain_carve(
		{
			"stamp_kind": &"sphere",
			"center": Vector3(0.5, -0.5, 0.5),
			"radius": 1.2,
			"strength": 1.0,
		},
		budget
	)
	_free_fixture(fixture)
	if carved <= 0.0:
		return _fail("budgeted carve removed nothing")
	if carved > budget * 1.15:
		return _fail(
			"carve exceeded volume budget %.3f > %.3f" % [carved, budget]
		)
	return true


func _test_sustained_grind_carves_trench() -> bool:
	var fixture := await _new_fixture()
	var piston := await _spawn_piston_on_ground(fixture)
	if piston.is_empty():
		_free_fixture(fixture)
		return _fail("grind piston spawn failed")
	var head_id := int(piston["head_element_id"])
	var head_body: RigidBody3D = (
		fixture.projection.get_element_projection(head_id).get("body")
	)
	if head_body == null:
		_free_fixture(fixture)
		return _fail("grind head body missing")
	var start := head_body.global_position + Vector3.DOWN * 0.5
	var finish := start + Vector3(1.2, 0.0, 0.0)
	var midpoint := (start + finish) * 0.5 + Vector3.DOWN * 0.25
	fixture.impact_service.emit_actuator_sustained_entry_for_test(
		head_id,
		head_body,
		fixture.terrain,
		240_000.0,
		1.0 / 60.0,
		0,
		start
	)
	# Same batch key: wait out the pair cooldown before the second bite.
	await get_tree().create_timer(0.12).timeout
	var tool: VoxelTool = fixture.terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var sdf_mid_before := _terrain_sdf_at(tool, midpoint)
	var carved: float = (
		fixture.impact_service.emit_actuator_sustained_entry_for_test(
			head_id,
			head_body,
			fixture.terrain,
			240_000.0,
			1.0 / 60.0,
			0,
			finish
		)
	)
	var sdf_mid_after := _terrain_sdf_at(tool, midpoint)
	_free_fixture(fixture)
	if carved <= 0.0:
		return _fail("grind segment carved zero volume")
	if not (sdf_mid_after > sdf_mid_before + 0.05):
		return _fail(
			"grind did not trench between contacts %.3f -> %.3f"
			% [sdf_mid_before, sdf_mid_after]
		)
	return true


func _test_mesh_stamp_carves_terrain() -> bool:
	var fixture := await _new_fixture()
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE
	collider.shape = shape
	add_child(collider)
	# Tilted box, as after an angled landing.
	collider.global_transform = Transform3D(
		Basis(Vector3(0.0, 0.0, 1.0), deg_to_rad(35.0)),
		Vector3(0.5, 0.4, 0.5)
	)
	var contact := Vector3(0.5, 0.0, 0.5)
	var op := TerrainImpactCarver.build_mesh_op(
		contact,
		collider,
		1.0,
		Vector3.DOWN
	)
	collider.queue_free()
	if op.is_empty():
		_free_fixture(fixture)
		return _fail("mesh stamp op unavailable for box collider")
	var tool: VoxelTool = fixture.terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var sample := Vector3(0.5, -0.5, 0.5)
	var sdf_before := _terrain_sdf_at(tool, sample)
	var carved: float = fixture.gateway.apply_terrain_carve(op)
	var sdf_after := _terrain_sdf_at(tool, sample)
	_free_fixture(fixture)
	if carved <= 0.0:
		return _fail("mesh stamp carved zero volume")
	if not (sdf_after > sdf_before + 0.05):
		return _fail(
			"mesh stamp did not change sdf %.3f -> %.3f"
			% [sdf_before, sdf_after]
		)
	return true


func _test_assembly_contact_damages_both() -> bool:
	var fixture := await _new_fixture()
	var first := _spawn_single(fixture.world)
	var second := _spawn_single_offset(fixture.world, Vector3i(4, 0, 0))
	if not first.is_ok() or not second.is_ok():
		_free_fixture(fixture)
		return _fail("assembly spawn failed")
	var first_id := int(first.data["element_ids"][0])
	var second_id := int(second.data["element_ids"][0])
	var first_body: PhysicsBody3D = fixture.projection.get_physics_body(
		int(first.data["assembly_id"])
	)
	var second_body: PhysicsBody3D = fixture.projection.get_physics_body(
		int(second.data["assembly_id"])
	)
	var first_before: float = fixture.world.get_element(first_id).integrity
	var second_before: float = fixture.world.get_element(second_id).integrity
	fixture.impact_service.apply_entry_for_test({
		"batch_key": "test_a",
		"striker_element_id": first_id,
		"striker_body": first_body,
		"local_shape_index": 0,
		"partner": second_body,
		"impulse_length": 36.0,
		"contact_world": Vector3.ZERO,
		"contact_points": PackedVector3Array([Vector3.ZERO]),
		"contact_impulses": PackedFloat32Array([36.0]),
	})
	fixture.impact_service.apply_entry_for_test({
		"batch_key": "test_b",
		"striker_element_id": second_id,
		"striker_body": second_body,
		"local_shape_index": 0,
		"partner": first_body,
		"impulse_length": 36.0,
		"contact_world": Vector3.ZERO,
		"contact_points": PackedVector3Array([Vector3.ZERO]),
		"contact_impulses": PackedFloat32Array([36.0]),
	})
	var first_after: float = fixture.world.get_element(first_id).integrity
	var second_after: float = fixture.world.get_element(second_id).integrity
	_free_fixture(fixture)
	if first_after >= first_before:
		return _fail("first assembly took no damage")
	if second_after >= second_before:
		return _fail("second assembly took no damage")
	return true


func _test_shape_enter_carves_terrain() -> bool:
	var fixture := await _new_fixture()
	var spawn := _spawn_single(fixture.world)
	if not spawn.is_ok():
		_free_fixture(fixture)
		return _fail("shape-enter spawn failed")
	var assembly_id := int(spawn.data["assembly_id"])
	var motion := GridSpawnUtil.motion_from_transform(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 1.2, 0.0)),
		false
	)
	fixture.projection.project_assembly_now(assembly_id, motion)
	var body := fixture.projection.get_physics_body(assembly_id) as RigidBody3D
	if body == null:
		_free_fixture(fixture)
		return _fail("shape-enter body missing")
	if not body.has_meta("impact_monitoring"):
		_free_fixture(fixture)
		return _fail("dynamic assembly body missing impact monitoring")
	if body.custom_integrator:
		_free_fixture(fixture)
		return _fail(
			"impact body must not enable custom_integrator"
			+ " (Jolt drops applied forces and gravity)"
		)
	body.linear_velocity = Vector3(0.0, -12.0, 0.0)
	var tool: VoxelTool = fixture.terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var sample := Vector3(0.5, -0.5, 0.5)
	var sdf_before: float = _terrain_sdf_at(tool, sample)
	var used_volume: float = fixture.impact_service.apply_entry_for_test({
		"batch_key": "shape_enter_test",
		"striker_element_id": int(spawn.data["element_ids"][0]),
		"striker_body": body,
		"local_shape_index": 0,
		"partner": fixture.terrain,
		"impulse_length": 36.0,
		"contact_world": Vector3(0.5, 0.0, 0.5),
		"contact_points": PackedVector3Array([Vector3(0.5, 0.0, 0.5)]),
		"contact_impulses": PackedFloat32Array([36.0]),
	})
	var sdf_after: float = _terrain_sdf_at(tool, sample)
	_free_fixture(fixture)
	if used_volume <= 0.0:
		return _fail("impact entry carved zero volume")
	if not (sdf_after > sdf_before + 0.05):
		return _fail(
			"shape-enter did not carve terrain sdf %.3f -> %.3f"
			% [sdf_before, sdf_after]
		)
	return true


func _test_physics_fall_damages_structure() -> bool:
	var fixture := await _new_fixture()
	var spawn := _spawn_single(fixture.world)
	if not spawn.is_ok():
		_free_fixture(fixture)
		return _fail("physics spawn failed")
	var assembly_id := int(spawn.data["assembly_id"])
	var element_id := int(spawn.data["element_ids"][0])
	var tool: VoxelTool = fixture.terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var integrity_before: float = fixture.world.get_element(element_id).integrity
	var motion := GridSpawnUtil.motion_from_transform(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 3.5, 0.0)),
		false
	)
	motion.linear_velocity = Vector3.ZERO
	fixture.projection.project_assembly_now(assembly_id, motion)
	var body := fixture.projection.get_physics_body(assembly_id) as RigidBody3D
	if body == null:
		_free_fixture(fixture)
		return _fail("projected rigid body missing")
	body.sleeping = false
	for _step: int in range(180):
		await get_tree().physics_frame
	var integrity_after: float = fixture.world.get_element(element_id).integrity
	_free_fixture(fixture)
	if integrity_after >= integrity_before:
		return _fail(
			"fall impact did not reduce integrity %.3f -> %.3f"
			% [integrity_before, integrity_after]
		)
	return true


func _new_fixture() -> Dictionary:
	for _frame: int in range(3):
		await get_tree().process_frame
	var terrain := VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.generate_collisions = true
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = 0.0
	terrain.generator = generator
	terrain.mesher = VoxelMesherTransvoxel.new()
	terrain.run_stream_in_editor = true
	terrain.automatic_loading_enabled = true
	add_child(terrain)
	var viewer := VoxelViewer.new()
	viewer.name = "TerrainViewer"
	viewer.view_distance = 64
	viewer.requires_collisions = true
	viewer.requires_visuals = false
	terrain.add_child(viewer)
	if not await _wait_for_editable_terrain(terrain):
		push_warning("impact test terrain never became editable")
	var placed := Node3D.new()
	placed.name = "PlacedBlocks"
	add_child(placed)
	var gateway := WorldCommandGateway.new()
	gateway.name = "WorldCommandGateway"
	gateway.terrain_path = NodePath("../VoxelTerrain")
	gateway.placed_blocks_path = NodePath("../PlacedBlocks")
	add_child(gateway)
	var session_scene: PackedScene = load(
		"res://scenes/simulation_session.tscn"
	)
	var session: SimulationSession = session_scene.instantiate()
	session.name = "SimulationSession"
	session.gateway_path = NodePath("../WorldCommandGateway")
	add_child(session)
	gateway.simulation_session_path = NodePath("../SimulationSession")
	await get_tree().process_frame
	session.impact_service.bind(session.world, gateway)
	ProjectedAssemblyBody.impact_service = session.impact_service
	session.projection.bind_impact_service(session.impact_service)
	for _frame: int in range(12):
		await get_tree().physics_frame
	return {
		"terrain": terrain,
		"gateway": gateway,
		"session": session,
		"placed": placed,
		"world": session.world,
		"projection": session.projection,
		"impact_service": session.impact_service,
	}


func _free_fixture(fixture: Dictionary) -> void:
	var terrain: VoxelTerrain = fixture.get("terrain")
	var gateway: WorldCommandGateway = fixture.get("gateway")
	var session: SimulationSession = fixture.get("session")
	var placed: Node = fixture.get("placed")
	if gateway != null:
		gateway.queue_free()
	if session != null:
		session.queue_free()
	if placed != null:
		placed.queue_free()
	if terrain != null:
		terrain.queue_free()


func _spawn_single(world: SimulationWorld) -> StructuralCommandResult:
	return _spawn(world, _single_blueprint(), GridTransform.identity())


func _spawn_single_offset(
	world: SimulationWorld,
	offset: Vector3i
) -> StructuralCommandResult:
	var frame := GridTransform.identity()
	frame.translation = offset
	return _spawn(world, _single_blueprint(), frame)


func _spawn(
	world: SimulationWorld,
	blueprint: Blueprint,
	grid_frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = grid_frame
	return world.apply_structural_command_now(command)


func _spawn_piston_on_ground(fixture: Dictionary) -> Dictionary:
	var world: SimulationWorld = fixture.world
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 100.0)
	world.get_archetype_registry().register(PISTON_HEAD)
	var foundation := _spawn(
		world,
		_single_blueprint_foundation(),
		GridTransform.identity()
	)
	if not foundation.is_ok():
		return {}
	var assembly_id := int(foundation.data["assembly_id"])
	var frame_place := PlaceElementCommand.new()
	frame_place.assembly_id = assembly_id
	frame_place.expected_assembly_revision = int(
		foundation.data["topology_revision"]
	)
	frame_place.archetype = Slice01Archetypes.frame()
	frame_place.origin_cell = Vector3i(4, 0, 0)
	frame_place.orientation_index = 0
	frame_place.store_id = "player"
	var frame_result := world.apply_structural_command_now(frame_place)
	if not frame_result.is_ok():
		return {}
	var piston_place := PlaceElementCommand.new()
	piston_place.assembly_id = assembly_id
	piston_place.expected_assembly_revision = int(
		frame_result.data["topology_revision"]
	)
	piston_place.archetype = PISTON_BASE
	piston_place.origin_cell = Vector3i(5, 0, 0)
	piston_place.orientation_index = 0
	piston_place.store_id = "player"
	var piston_result := world.apply_structural_command_now(piston_place)
	if not piston_result.is_ok():
		return {}
	fixture.projection.project_assembly_now(assembly_id, null)
	for _frame: int in range(6):
		await get_tree().physics_frame
	return {
		"assembly_id": assembly_id,
		"base_element_id": int(piston_result.data["element_id"]),
		"head_element_id": int(piston_result.data["head_element_id"]),
	}


func _single_blueprint_foundation() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"impact_foundation",
		[
			_placement(
				"element_0",
				Slice01Archetypes.foundation(),
				Vector3i.ZERO
			)
		]
	)


func _single_blueprint() -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"impact_single_frame",
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


func _terrain_surface_y(tool: VoxelTool) -> float:
	var hit: VoxelRaycastResult = tool.raycast(
		Vector3(0.5, 10.0, 0.5),
		Vector3.DOWN,
		20.0
	)
	if hit == null:
		return INF
	return hit.position.y


func _terrain_sdf_at(tool: VoxelTool, world_point: Vector3) -> float:
	var cell := Vector3i(
		floori(world_point.x),
		floori(world_point.y),
		floori(world_point.z),
	)
	return tool.get_voxel_f(cell)


func _wait_for_editable_terrain(terrain: VoxelTerrain) -> bool:
	var tool: VoxelTool = terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var edit_box := AABB(Vector3(-8.0, -8.0, -8.0), Vector3(16.0, 16.0, 16.0))
	for _frame: int in range(180):
		if tool.is_area_editable(edit_box):
			return true
		await get_tree().physics_frame
	return false


func _seed_flat_terrain(
	terrain: VoxelTerrain,
	surface_y: float = 0.0
) -> bool:
	var block_size := terrain.get_data_block_size()
	var block_pos := Vector3i.ZERO
	var buffer := VoxelBuffer.new()
	buffer.create(block_size, block_size, block_size)
	var block_origin := terrain.data_block_to_voxel(block_pos)
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
	return terrain.try_set_block_data(block_pos, buffer)


func _fail(reason: String) -> bool:
	print("KINETIC-INTERACTION-V1: FAIL %s" % reason)
	get_tree().quit(1)
	return false
