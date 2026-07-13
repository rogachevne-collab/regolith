extends Node3D


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var tests: Array[Callable] = [
		_test_damage_scales_with_impulse,
		_test_weak_impulse_ignored,
		_test_terrain_carve_changes_sdf,
		_test_assembly_contact_damages_both,
		_test_shape_enter_carves_terrain,
	]
	for test: Callable in tests:
		if not bool(await test.call()):
			return
	if not await _test_physics_fall_damages_structure():
		return
	print("IMPACT-DESTRUCTION-V0: PASS")
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
	print("IMPACT-DESTRUCTION-V0: FAIL %s" % reason)
	get_tree().quit(1)
	return false
