extends Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _test_preview_projection_parity_ground():
		return
	if not _test_preview_projection_parity_attach():
		return
	if not _test_snap_resolver_direct_priority():
		return
	if not _test_snap_resolver_scoring_and_hysteresis():
		return
	if not _test_snap_resolver_voxel_below_magnetic():
		return
	if not _test_snap_resolver_corridor_filter():
		return
	if not _test_gateway_resolve_plan_parity():
		return
	if not _test_ground_placement_keeps_continuous_pose():
		return
	if not _test_snap_resolver_performance():
		return
	print("CONSTRUCTION-V1: PASS")
	get_tree().quit(0)


func _test_preview_projection_parity_ground() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var beam: ElementArchetype = Slice01Archetypes.frame_beam()
	var orientations: Array[int] = [
		0,
		_find_orientation(Vector3i.RIGHT, Vector3i.UP),
		_find_orientation(Vector3i.RIGHT, Vector3i.FORWARD),
	]
	for orientation_index: int in orientations:
		if orientation_index < 0:
			continue
		var target := _voxel_target(
			Vector3(4.0, 0.0, 0.0),
			Vector3.UP,
			Vector3.FORWARD
		)
		var plan := ConstructionPlacement.plan(
			world,
			target,
			beam,
			orientation_index
		)
		if not bool(plan.get("valid", false)):
			return _fail(
				"ground plan invalid for orientation %d"
				% orientation_index
			)
		var preview_transforms := GridPoseUtil.projected_element_collider_transforms(
			plan["preview_root_transform"],
			plan["origin_cell"],
			orientation_index,
			beam
		)
		var place: PlaceElementCommand = plan["command"]
		var result := world.apply_structural_command_now(place)
		if not result.is_ok():
			return _fail(
				"ground place failed for orientation %d"
				% orientation_index
			)
		var assembly_id := int(result.data["assembly_id"])
		var projected_root: Transform3D = plan["assembly_world_transform"]
		world.sync_assembly_motion(
			assembly_id,
			GridSpawnUtil.motion_from_transform(
				projected_root,
				world.assembly_has_anchor(assembly_id)
			)
		)
		var placed_transforms := GridPoseUtil.projected_element_collider_transforms(
			projected_root,
			place.origin_cell,
			place.orientation_index,
			beam
		)
		if not _transform_sets_match(preview_transforms, placed_transforms):
			return _fail(
				"ground preview/projection mismatch orientation %d"
				% orientation_index
			)
		_free_fixture(fixture)
		fixture = _new_fixture()
		world = fixture["world"]
	_free_fixture(fixture)
	return true


func _spawn_anchored_frame(world: SimulationWorld) -> StructuralCommandResult:
	var target := _voxel_target(
		Vector3(0.0, 0.0, 0.0),
		Vector3.UP,
		Vector3.FORWARD
	)
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var plan := ConstructionPlacement.plan(world, target, frame, 0)
	if not bool(plan.get("valid", false)):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	return world.apply_structural_command_now(plan["command"])


func _test_preview_projection_parity_attach() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var target := InteractionHit.create(
		assembly_transform * Vector3(1.5, 0.5, 0.5),
		assembly_transform.basis.x,
		assembly_transform.origin.distance_to(
			assembly_transform * Vector3(1.5, 0.5, 0.5)
		),
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		StringName(str(anchor_element.element_id)),
		{
			"element_id": anchor_element.element_id,
			"assembly_id": assembly_id,
			"collider_local_cell": Vector3i.ZERO,
			"aim_direction": Vector3.FORWARD,
		}
	).snapshot()
	var beam: ElementArchetype = Slice01Archetypes.frame_beam()
	var orientation_index := 0
	var plan := ConstructionPlacement.plan(
		world,
		target,
		beam,
		orientation_index
	)
	if not bool(plan.get("valid", false)):
		return _fail("attach plan invalid for frame_beam")
	var preview_transforms := GridPoseUtil.projected_element_collider_transforms(
		plan["preview_root_transform"],
		plan["origin_cell"],
		orientation_index,
		beam
	)
	var place: PlaceElementCommand = plan["command"]
	var result := world.apply_structural_command_now(place)
	if not result.is_ok():
		return _fail("attach place failed for frame_beam")
	var placed_element := world.get_element(int(result.data["element_id"]))
	var placed_transforms := GridPoseUtil.projected_element_collider_transforms(
		assembly.motion.transform,
		placed_element.origin_cell,
		placed_element.orientation_index,
		beam
	)
	if not _transform_sets_match(preview_transforms, placed_transforms):
		return _fail("attach preview/projection mismatch for frame_beam")
	_free_fixture(fixture)
	return true


func _test_snap_resolver_direct_priority() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("snap anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var direct := InteractionHit.create(
		assembly_transform * Vector3(0.5, 1.5, 0.5),
		assembly_transform.basis.y,
		1.0,
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		StringName(str(anchor_element.element_id)),
		{
			"element_id": anchor_element.element_id,
			"assembly_id": assembly_id,
			"collider_local_cell": Vector3i.ZERO,
			"aim_direction": Vector3.FORWARD,
		}
	).snapshot()
	var resolver := ConstructionSnapResolver.new()
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var result := resolver.resolve({
		"world": world,
		"archetype": frame,
		"orientation_index": 0,
		"ray_origin": Vector3(0.0, 2.0, 4.0),
		"ray_direction": Vector3(0.0, -0.2, -1.0).normalized(),
		"direct_hit": direct,
	})
	var candidates: Array = result["candidates"]
	if candidates.is_empty():
		return _fail("snap resolver returned no candidates")
	if float(candidates[0]["score"]) < ConstructionSnapResolver.DIRECT_ELEMENT_SCORE:
		return _fail("direct compatible hit did not win priority")
	if str(candidates[0]["source"]) != "direct_element":
		return _fail("selected candidate was not direct element hit")
	_free_fixture(fixture)
	return true


func _test_snap_resolver_scoring_and_hysteresis() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("hysteresis anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var resolver := ConstructionSnapResolver.new()
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var assembly_transform := assembly.motion.transform
	var first := resolver.resolve({
		"world": world,
		"archetype": frame,
		"orientation_index": 0,
		"ray_origin": assembly_transform * Vector3(2.5, 0.5, 0.5),
		"ray_direction": (-assembly_transform.basis.x).normalized(),
		"direct_hit": {},
	})
	var first_candidates: Array = first["candidates"]
	if first_candidates.is_empty():
		return _fail("hysteresis setup found no candidates")
	var sticky_key := str(first["sticky_key"])
	if sticky_key.is_empty():
		return _fail("sticky key missing after first resolve")
	var second := resolver.resolve({
		"world": world,
		"archetype": frame,
		"orientation_index": 0,
		"ray_origin": assembly_transform * Vector3(2.2, 1.8, 0.5),
		"ray_direction": Vector3(-0.2, -0.9, -0.1).normalized(),
		"direct_hit": {},
	})
	var kept_sticky := false
	for index: int in range(second["candidates"].size()):
		if (
			str(second["candidates"][index]["key"]) == sticky_key
			and int(second["selected_index"]) == index
		):
			kept_sticky = true
			break
	if not kept_sticky:
		return _fail("hysteresis did not keep sticky candidate")
	var manual_index := resolver.cycle_candidate(
		second["candidates"],
		int(second["selected_index"]),
		1
	)
	if manual_index < 0 or manual_index >= second["candidates"].size():
		return _fail("manual cycle hook failed")
	_free_fixture(fixture)
	return true


func _test_snap_resolver_voxel_below_magnetic() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("voxel priority anchor spawn failed")
	var assembly := world.get_assembly_raw(int(anchor.data["assembly_id"]))
	var assembly_transform := assembly.motion.transform
	var resolver := ConstructionSnapResolver.new()
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var voxel_hit := _voxel_target(
		Vector3(8.0, -2.0, 0.0),
		Vector3.UP,
		Vector3(0.0, -1.0, 0.0)
	)
	var result := resolver.resolve({
		"world": world,
		"archetype": frame,
		"orientation_index": 0,
		"ray_origin": assembly_transform * Vector3(0.5, 1.5, 2.0),
		"ray_direction": Vector3(0.0, -0.35, -1.0).normalized(),
		"direct_hit": voxel_hit,
	})
	var candidates: Array = result["candidates"]
	if candidates.is_empty():
		return _fail("voxel priority found no candidates")
	if str(candidates[0]["source"]) == "voxel_fallback":
		return _fail("magnetic face should beat voxel fallback")
	if float(candidates[0]["score"]) <= ConstructionSnapResolver.VOXEL_FALLBACK_SCORE:
		return _fail("selected magnetic candidate score too low")
	_free_fixture(fixture)
	return true


func _test_snap_resolver_corridor_filter() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("corridor anchor spawn failed")
	var assembly := world.get_assembly_raw(int(anchor.data["assembly_id"]))
	var assembly_transform := assembly.motion.transform
	var resolver := ConstructionSnapResolver.new()
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var behind := resolver.resolve({
		"world": world,
		"archetype": frame,
		"orientation_index": 0,
		"ray_origin": assembly_transform * Vector3(0.5, 0.5, 3.0),
		"ray_direction": Vector3(0.0, 0.0, -1.0).normalized(),
		"direct_hit": {},
	})
	for candidate: Dictionary in behind["candidates"]:
		var point: Vector3 = candidate["target"]["point"]
		var to_point := point - (assembly_transform * Vector3(0.5, 0.5, 3.0))
		if to_point.dot(Vector3(0.0, 0.0, -1.0)) < 0.0:
			return _fail("corridor selected a face behind the ray")
	_free_fixture(fixture)
	return true


func _test_gateway_resolve_plan_parity() -> bool:
	var fixture := _new_gateway_fixture()
	var world: SimulationWorld = fixture["world"]
	var gateway: WorldCommandGateway = fixture["gateway"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("gateway parity anchor spawn failed")
	var assembly := world.get_assembly_raw(int(anchor.data["assembly_id"]))
	var assembly_transform := assembly.motion.transform
	var resolved := gateway.resolve_construction_placement({
		"direct_hit": {},
		"ray_origin": assembly_transform * Vector3(2.5, 0.5, 0.5),
		"ray_direction": (-assembly_transform.basis.x).normalized(),
		"archetype_id": "frame",
		"orientation_index": 0,
	})
	if not bool(resolved.get("selected_plan", {}).get("valid", false)):
		return _fail("gateway resolve did not produce valid plan")
	var target: Dictionary = resolved["selected_target"]
	var plan: Dictionary = resolved["selected_plan"]
	var replay := gateway.preview_construction(
		target,
		"frame",
		0
	)
	if not bool(replay.get("valid", false)):
		return _fail("gateway replay plan invalid")
	var replay_command: PlaceElementCommand = replay["command"]
	var plan_command: PlaceElementCommand = plan["command"]
	if (
		replay_command.origin_cell != plan_command.origin_cell
		or replay_command.orientation_index != plan_command.orientation_index
	):
		return _fail("gateway resolve/plan command mismatch")
	_free_fixture(fixture)
	return true


func _test_ground_placement_keeps_continuous_pose() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var target := _voxel_target(
		Vector3(4.0, 0.45, 0.0),
		Vector3.UP,
		Vector3.FORWARD
	)
	var plan := ConstructionPlacement.plan(world, target, frame, 0)
	if not bool(plan.get("valid", false)):
		return _fail("fractional ground plan invalid")
	var command: PlaceElementCommand = plan["command"]
	var snapped_transform := GridPoseUtil.grid_frame_to_transform(
		command.new_assembly_grid_frame
	)
	var continuous_transform: Transform3D = plan["assembly_world_transform"]
	if continuous_transform.is_equal_approx(snapped_transform):
		return _fail("ground placement lost continuous terrain pose")
	if not plan["preview_root_transform"].is_equal_approx(continuous_transform):
		return _fail("preview root diverged from continuous ground pose")
	_free_fixture(fixture)
	return true


func _test_snap_resolver_performance() -> bool:
	var fixture := _new_gateway_fixture()
	var world: SimulationWorld = fixture["world"]
	var gateway: WorldCommandGateway = fixture["gateway"]
	var assembly := _spawn_frame_row(world, 15)
	if assembly == null:
		return _fail("performance row spawn failed")
	var assembly_transform := assembly.motion.transform
	var params := {
		"direct_hit": {},
		"ray_origin": assembly_transform * Vector3(7.5, 0.5, 2.0),
		"ray_direction": Vector3(0.0, -0.2, -1.0).normalized(),
		"archetype_id": "frame",
		"orientation_index": 0,
	}
	var first := gateway.resolve_construction_placement(params)
	var first_stats: Dictionary = gateway.snap_resolve_stats()
	if int(first_stats.get("faces_in_cache", 0)) < 40:
		return _fail(
			"performance cache too small: %d faces"
			% int(first_stats.get("faces_in_cache", 0))
		)
	if not bool(first_stats.get("cache_rebuilt", false)):
		return _fail("performance first resolve did not rebuild cache")
	var rebuild_count_after_first := int(first_stats.get("cache_rebuilds", 0))
	for _repeat: int in range(12):
		gateway.resolve_construction_placement(params)
	var repeat_stats: Dictionary = gateway.snap_resolve_stats()
	if int(repeat_stats.get("cache_rebuilds", 0)) != rebuild_count_after_first:
		return _fail("performance repeat resolves rebuilt snap cache")
	if int(repeat_stats.get("plans_validated", 0)) > (
		ConstructionSnapResolver.TOP_K_VALIDATE + 1
	):
		return _fail(
			"performance plans_validated %d exceeds top-K cap"
			% int(repeat_stats.get("plans_validated", 0))
		)
	if int(repeat_stats.get("faces_scanned", 0)) > int(
		repeat_stats.get("faces_in_cache", 0)
	):
		return _fail("performance faces_scanned exceeds faces_in_cache")
	_free_fixture(fixture)
	return true


func _spawn_frame_row(
	world: SimulationWorld,
	count: int
) -> SimulationAssembly:
	if count <= 0:
		return null
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return null
	var assembly_id := int(anchor.data["assembly_id"])
	var attach_element_id := int(anchor.data["element_id"])
	var frame: ElementArchetype = Slice01Archetypes.frame()
	for _index: int in range(1, count):
		var assembly := world.get_assembly_raw(assembly_id)
		var attach_element := world.get_element(attach_element_id)
		if assembly == null or attach_element == null:
			return null
		var assembly_transform := assembly.motion.transform
		var attach_cell := attach_element.origin_cell
		var target := InteractionHit.create(
			assembly_transform * (Vector3(attach_cell) + Vector3(1.5, 0.5, 0.5)),
			assembly_transform.basis.x,
			1.0,
			InteractionHit.KIND_SIMULATION_ELEMENT,
			null,
			StringName(str(attach_element_id)),
			{
				"element_id": attach_element_id,
				"assembly_id": assembly_id,
				"collider_local_cell": Vector3i.ZERO,
				"aim_direction": Vector3.FORWARD,
			}
		).snapshot()
		var plan := ConstructionPlacement.plan(world, target, frame, 0)
		if not bool(plan.get("valid", false)):
			return null
		var result := world.apply_structural_command_now(plan["command"])
		if not result.is_ok():
			return null
		attach_element_id = int(result.data["element_id"])
	return world.get_assembly_raw(assembly_id)


func _transform_sets_match(
	left: Array[Transform3D],
	right: Array[Transform3D]
) -> bool:
	if left.size() != right.size():
		return false
	for index: int in range(left.size()):
		if not left[index].is_equal_approx(right[index]):
			return false
	return true


func _new_gateway_fixture() -> Dictionary:
	var root := Node.new()
	add_child(root)
	var terrain := VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	var placed := Node3D.new()
	placed.name = "PlacedBlocks"
	root.add_child(terrain)
	root.add_child(placed)
	var world := SimulationWorld.new()
	world.name = "SimulationWorld"
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 1000.0)
	var session := SimulationSession.new()
	session.name = "SimulationSession"
	session.add_child(world)
	var projection := SimulationPhysicsProjection.new()
	projection.name = "SimulationPhysicsProjection"
	session.add_child(projection)
	var visuals := ElementVisualProjection.new()
	visuals.name = "ElementVisualProjection"
	session.add_child(visuals)
	root.add_child(session)
	session._ready()
	var gateway := WorldCommandGateway.new()
	root.add_child(gateway)
	gateway.terrain_path = NodePath("../VoxelTerrain")
	gateway.placed_blocks_path = NodePath("../PlacedBlocks")
	gateway.simulation_session_path = NodePath("../SimulationSession")
	gateway._ready()
	gateway._bind_snap_cache_events()
	return {
		"root": root,
		"world": world,
		"gateway": gateway,
	}


func _new_fixture() -> Dictionary:
	var root := Node.new()
	add_child(root)
	var world := SimulationWorld.new()
	root.add_child(world)
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 1000.0)
	return {
		"root": root,
		"world": world,
	}


func _free_fixture(fixture: Dictionary) -> void:
	var root: Node = fixture["root"]
	root.queue_free()


func _voxel_target(
	point: Vector3,
	normal: Vector3,
	aim_direction: Vector3
) -> Dictionary:
	return InteractionHit.create(
		point,
		normal,
		point.length(),
		InteractionHit.KIND_VOXEL,
		null,
		StringName(),
		{"aim_direction": aim_direction}
	).snapshot()


func _find_orientation(from: Vector3i, to: Vector3i) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.rotate_direction(from, index) == to:
			return index
	return -1


func _fail(reason: String) -> bool:
	print("CONSTRUCTION-V1: FAIL %s" % reason)
	get_tree().quit(1)
	return false
