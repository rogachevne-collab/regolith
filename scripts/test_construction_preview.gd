extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")

func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "CONSTRUCTION-V1")
	if not _test_preview_projection_parity_ground():
		return
	if not _test_preview_projection_parity_attach():
		return
	if not _test_large_frame_attach():
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
	if not _test_upright_basis_field_aligned():
		return
	if not _test_radial_ground_placement_keeps_field_pose():
		return
	if not _test_rotation_snap_pivot_parity():
		return
	if not _test_rotation_full_cycle_no_drift():
		return
	if not _test_rotation_snap_to_existing_face():
		return
	if not _test_ground_rotation_pivot_hold():
		return
	if not _test_beam_multicell_face_snap_consistency():
		return
	if not _test_preview_port_collider_parity_rotation():
		return
	if not _test_preview_port_collider_attach_orient23():
		return
	if not _test_power_source_attach_rotation_cycle():
		return
	if not _test_attach_face_snap_table():
		return
	if not _test_gateway_attach_orientation_replay():
		return
	if not _test_snap_scan_tracks_assembly_motion():
		return
	if not _test_snap_vehicle_attach_follows_velocity():
		return
	if not _test_snap_resolver_invalid_direct_red_ghost():
		return
	if not _test_snap_resolver_performance():
		return
	if not _test_gateway_voxel_place_spawns_visual():
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
		var assembly := world.get_assembly_raw(assembly_id)
		if (
			assembly == null
			or not assembly.motion.transform.is_equal_approx(projected_root)
		):
			return _fail(
				"ground place did not preserve initial continuous pose orientation %d"
				% orientation_index
			)
		var placed_transforms := GridPoseUtil.projected_element_collider_transforms(
			assembly.motion.transform,
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
		assembly_transform * Vector3(0.75, 0.25, 0.25),
		assembly_transform.basis.x,
		assembly_transform.origin.distance_to(
			assembly_transform * Vector3(0.75, 0.25, 0.25)
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


func _test_large_frame_attach() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("large frame anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var target := InteractionHit.create(
		assembly_transform * Vector3(0.75, 0.25, 0.25),
		assembly_transform.basis.x,
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
	var large_frame := Slice01Archetypes.large_frame()
	var plan := ConstructionPlacement.plan(world, target, large_frame, 0)
	if not bool(plan.get("valid", false)):
		return _fail("large frame attach plan invalid")
	var result := world.apply_structural_command_now(plan["command"])
	if not result.is_ok():
		return _fail("large frame attach failed: %s" % result.reason)
	var placed := world.get_element(int(result.data["element_id"]))
	if (
		placed == null
		or placed.get_archetype().footprint_cells.size() != 125
	):
		return _fail("large frame placement lost its 5x5x5 footprint")
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
		assembly_transform * Vector3(0.25, 0.75, 0.25),
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
		"ray_origin": assembly_transform * Vector3(1.25, 0.25, 0.25),
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
		"ray_origin": assembly_transform * Vector3(1.1, 0.9, 0.25),
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
	# Direct voxel hit must NOT short-circuit the face scan: aiming at the
	# ground next to a structure still offers magnetic faces above the
	# voxel fallback (magnetic snap policy §2-3).
	if str(candidates[0]["source"]) != "face_scan":
		return _fail(
			"magnetic face should beat voxel fallback, got %s"
			% str(candidates[0]["source"])
		)
	if float(candidates[0]["score"]) <= ConstructionSnapResolver.VOXEL_FALLBACK_SCORE:
		return _fail("selected magnetic candidate score too low")
	# The ground plan is lazy while a face wins, but manual cycling must
	# still offer the voxel fallback in the pool.
	var cycled := resolver.resolve({
		"world": world,
		"archetype": frame,
		"orientation_index": 0,
		"ray_origin": assembly_transform * Vector3(0.5, 1.5, 2.0),
		"ray_direction": Vector3(0.0, -0.35, -1.0).normalized(),
		"direct_hit": voxel_hit,
		"manual_candidate_index": 0,
	})
	var has_voxel_candidate := false
	for candidate: Dictionary in cycled["candidates"]:
		if str(candidate["source"]) == "voxel_fallback":
			has_voxel_candidate = true
			break
	if not has_voxel_candidate:
		return _fail("voxel fallback candidate missing from manual cycle pool")
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


func _test_upright_basis_field_aligned() -> bool:
	var surface_up := Vector3(1.0, 1.0, 0.0).normalized()
	var basis := ConstructionPlacement._upright_basis(
		Vector3.FORWARD,
		surface_up
	)
	if not basis.y.is_equal_approx(surface_up):
		return _fail("upright basis y != surface_up on tilted field")
	if absf(basis.y.dot(basis.x)) > 0.001:
		return _fail("upright basis x/y not orthogonal")
	if absf(basis.y.dot(basis.z)) > 0.001:
		return _fail("upright basis y/z not orthogonal")
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var point := Vector3(12.0, 12.0, 0.0)
	var target := _voxel_target(point, surface_up, Vector3.FORWARD)
	target["surface_up"] = surface_up
	var plan := ConstructionPlacement.plan(world, target, frame, 0)
	if not bool(plan.get("valid", false)):
		return _fail("voxel plan with surface_up invalid on tilted field")
	_free_fixture(fixture)
	return true


func _test_radial_ground_placement_keeps_field_pose() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var surface_up := Vector3(0.0, 0.6, 0.8).normalized()
	var point := surface_up * 500.0
	var aim := Vector3(0.8, 0.0, -0.6).normalized()
	var target := _voxel_target(point, surface_up, aim)
	target["surface_up"] = surface_up
	var plan := ConstructionPlacement.plan(world, target, frame, 0)
	if not bool(plan.get("valid", false)):
		return _fail("radial ground plan invalid")
	var root: Transform3D = plan["assembly_world_transform"]
	if not root.basis.y.is_equal_approx(surface_up):
		return _fail("radial ground root basis y != surface_up")
	var ground_contact := GridPoseUtil.ground_contact_local(frame, 0)
	var bottom_world := root.origin + root.basis * ground_contact
	var bottom_error := absf(surface_up.dot(bottom_world - point))
	if bottom_error > 0.05:
		return _fail(
			"radial ground bottom not seated on surface (err=%.4f)"
			% bottom_error
		)
	_free_fixture(fixture)
	return true


func _test_rotation_snap_pivot_parity() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("rotation pivot anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var target := InteractionHit.create(
		assembly_transform * Vector3(0.75, 0.25, 0.25),
		assembly_transform.basis.x,
		assembly_transform.origin.distance_to(
			assembly_transform * Vector3(0.75, 0.25, 0.25)
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
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var orientation_index := 0
	var baseline_plan := ConstructionPlacement.plan(
		world,
		target,
		frame,
		orientation_index
	)
	if not bool(baseline_plan.get("valid", false)):
		return _fail("rotation pivot baseline plan invalid")
	var baseline_pivot := _world_footprint_pivot(baseline_plan)
	for local_axis: Vector3 in [Vector3.UP, Vector3.RIGHT, Vector3.BACK]:
		for _step: int in range(3):
			orientation_index = _rotate_orientation_index(
				orientation_index,
				local_axis
			)
			var plan := ConstructionPlacement.plan(
				world,
				target,
				frame,
				orientation_index
			)
			if not bool(plan.get("valid", false)):
				return _fail(
					"rotation pivot plan invalid axis %s step %d orient %d"
					% [local_axis, _step, orientation_index]
				)
			var snap_context := ConstructionPlacement._attach_snap_context(
				world,
				assembly,
				target,
				target.get("metadata", {})
			)
			var pivot_origin := GridPoseUtil.pivot_compensated_origin(
				frame,
				snap_context["target_port_cell"],
				snap_context["snap_dir"],
				orientation_index
			)
			if plan["origin_cell"] == pivot_origin:
				var pivot := _world_footprint_pivot(plan)
				if pivot.distance_to(baseline_pivot) > 0.01:
					return _fail(
						"rotation pivot drift axis %s step %d orient %d"
						% [local_axis, _step, orientation_index]
					)
	_free_fixture(fixture)
	return true


func _test_rotation_full_cycle_no_drift() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("rotation cycle anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var target := InteractionHit.create(
		assembly_transform * Vector3(0.25, 0.75, 0.25),
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
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var orientation_index := 0
	var baseline_plan := ConstructionPlacement.plan(
		world,
		target,
		frame,
		orientation_index
	)
	if not bool(baseline_plan.get("valid", false)):
		return _fail("rotation cycle baseline plan invalid")
	var baseline_transforms := GridPoseUtil.projected_element_collider_transforms(
		baseline_plan["preview_root_transform"],
		baseline_plan["origin_cell"],
		orientation_index,
		frame
	)
	for _cycle: int in range(4):
		orientation_index = _rotate_orientation_index(
			orientation_index,
			Vector3.UP
		)
	var cycle_plan := ConstructionPlacement.plan(
		world,
		target,
		frame,
		orientation_index
	)
	if not bool(cycle_plan.get("valid", false)):
		return _fail("rotation cycle did not return to valid plan")
	if cycle_plan["origin_cell"] != baseline_plan["origin_cell"]:
		return _fail("rotation cycle origin_cell drift")
	var cycle_transforms := GridPoseUtil.projected_element_collider_transforms(
		cycle_plan["preview_root_transform"],
		cycle_plan["origin_cell"],
		orientation_index,
		frame
	)
	if not _transform_sets_match(baseline_transforms, cycle_transforms):
		return _fail("rotation cycle collider transform drift")
	_free_fixture(fixture)
	return true


func _test_rotation_snap_to_existing_face() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("rotation snap face anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var target := InteractionHit.create(
		assembly_transform * Vector3(0.75, 0.25, 0.25),
		assembly_transform.basis.x,
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
	var beam: ElementArchetype = Slice01Archetypes.frame_beam()
	var orientation_index := 0
	for local_axis: Vector3 in [Vector3.UP, Vector3.RIGHT]:
		for _step: int in range(4):
			var plan := ConstructionPlacement.plan(
				world,
				target,
				beam,
				orientation_index
			)
			if not bool(plan.get("valid", false)):
				return _fail(
					"rotation snap face invalid beam orient %d"
					% orientation_index
				)
			var command: PlaceElementCommand = plan["command"]
			var preview := SimulationElement.frame(
				-1,
				command.assembly_id,
				command.archetype,
				command.origin_cell,
				command.orientation_index,
				{}
			)
			if not RuntimeConnectivity.elements_have_rigid_connection(
				anchor_element,
				preview
			):
				return _fail(
					"rotation snap face lost rigid connection orient %d"
					% orientation_index
				)
			orientation_index = _rotate_orientation_index(
				orientation_index,
				local_axis
			)
	_free_fixture(fixture)
	return true


func _test_ground_rotation_pivot_hold() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var beam: ElementArchetype = Slice01Archetypes.frame_beam()
	var target := _voxel_target(
		Vector3(4.0, 0.0, 0.0),
		Vector3.UP,
		Vector3.FORWARD
	)
	var held_pivot := ConstructionPlacement.baseline_ground_pivot(
		world,
		target,
		beam
	)
	if not held_pivot.is_finite():
		return _fail("ground pivot baseline invalid")
	var orientation_index := 0
	for _step: int in range(4):
		var plan := ConstructionPlacement.plan(
			world,
			target,
			beam,
			orientation_index,
			"player",
			held_pivot
		)
		if not bool(plan.get("valid", false)):
			return _fail(
				"ground pivot hold invalid orient %d"
				% orientation_index
			)
		var pivot := _world_footprint_pivot(plan)
		if pivot.distance_to(held_pivot) > 0.02:
			return _fail(
				"ground pivot drift orient %d delta %.4f"
				% [orientation_index, pivot.distance_to(held_pivot)]
			)
		orientation_index = _rotate_orientation_index(
			orientation_index,
			Vector3.UP
		)
	_free_fixture(fixture)
	return true


func _test_beam_multicell_face_snap_consistency() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("multicell snap anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var beam: ElementArchetype = Slice01Archetypes.frame_beam()
	var hit_point := assembly_transform * Vector3(0.75, 0.25, 0.25)
	var hit_normal := assembly_transform.basis.x
	var target_cell0 := InteractionHit.create(
		hit_point,
		hit_normal,
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
	var target_cell1 := InteractionHit.create(
		hit_point,
		hit_normal,
		1.0,
		InteractionHit.KIND_SIMULATION_ELEMENT,
		null,
		StringName(str(anchor_element.element_id)),
		{
			"element_id": anchor_element.element_id,
			"assembly_id": assembly_id,
			"collider_local_cell": Vector3i(1, 0, 0),
			"aim_direction": Vector3.FORWARD,
		}
	).snapshot()
	var plan0 := ConstructionPlacement.plan(world, target_cell0, beam, 0)
	var plan1 := ConstructionPlacement.plan(world, target_cell1, beam, 0)
	if not bool(plan0.get("valid", false)) or not bool(plan1.get("valid", false)):
		return _fail("multicell snap plans invalid")
	if plan0["origin_cell"] != plan1["origin_cell"]:
		return _fail(
			"multicell face snap origin mismatch %s vs %s"
			% [plan0["origin_cell"], plan1["origin_cell"]]
		)
	_free_fixture(fixture)
	return true


func _test_preview_port_collider_parity_rotation() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var source: ElementArchetype = Slice01Archetypes.power_source()
	var target := _voxel_target(
		Vector3(2.0, 0.0, 2.0),
		Vector3.UP,
		Vector3.FORWARD
	)
	for orientation_index: int in [0, 6, 12, 18]:
		var plan := ConstructionPlacement.plan(
			world,
			target,
			source,
			orientation_index
		)
		if not bool(plan.get("valid", false)):
			return _fail(
				"port parity plan invalid orient %d"
				% orientation_index
			)
		var preview_element := SimulationElement.frame(
			-1,
			-1,
			source,
			plan["origin_cell"],
			orientation_index,
			{}
		)
		for port: PortDefinition in IndustryPortUtil.list_industry_ports(
			preview_element
		):
			var port_tf := IndustryPortUtil.port_local_transform(
				preview_element,
				port
			)
			var marker_tf := IndustryPortUtil.port_marker_local_transform(
				preview_element,
				port
			)
			var expected_normal := Vector3(
				IndustryPortUtil.element_port_direction(preview_element, port)
			)
			if not marker_tf.basis.y.is_equal_approx(expected_normal):
				return _fail(
					"port marker normal mismatch orient %d port %s"
					% [orientation_index, port.port_id]
				)
			if marker_tf.origin.distance_to(port_tf.origin) > 0.01:
				return _fail(
					"port marker origin mismatch orient %d port %s"
					% [orientation_index, port.port_id]
				)
	_free_fixture(fixture)
	return true


func _test_preview_port_collider_attach_orient23() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("orient23 attach anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var target := InteractionHit.create(
		assembly_transform * Vector3(0.25, 0.75, 0.25),
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
	var source: ElementArchetype = Slice01Archetypes.power_source()
	var orientation_index := 23
	var plan := ConstructionPlacement.plan(
		world,
		target,
		source,
		orientation_index
	)
	if not bool(plan.get("valid", false)):
		return _fail("orient23 top attach plan invalid")
	var root: Transform3D = plan["preview_root_transform"]
	var origin_cell: Vector3i = plan["origin_cell"]
	var collider: ColliderDefinition = source.colliders[0]
	var collider_world := GridPoseUtil.collider_world_transform(
		root,
		origin_cell,
		orientation_index,
		collider
	)
	var preview_element := SimulationElement.frame(
		-1,
		-1,
		source,
		origin_cell,
		orientation_index,
		{}
	)
	for port: PortDefinition in IndustryPortUtil.list_industry_ports(preview_element):
		var port_world := (
			root
			* IndustryPortUtil.port_marker_local_transform(
				preview_element,
				port
			)
		)
		var delta := port_world.origin.distance_to(collider_world.origin)
		var expected_delta := (
			IndustryPortUtil.port_marker_local_transform(
				preview_element,
				port
			).origin.distance_to(
				GridPoseUtil.collider_local_transform(
					origin_cell,
					orientation_index,
					collider
				).origin
			)
		)
		if absf(delta - expected_delta) > 0.01:
			return _fail(
				"orient23 port/collider delta %.4f expected %.4f"
				% [delta, expected_delta]
			)
	var bottom_y := collider_world.origin.y - collider.size.y * 0.5
	if absf(bottom_y - GridMetric.CELL_SIZE_M) > 0.01:
		return _fail(
			"orient23 top attach bottom y %.3f expected %.1f"
			% [bottom_y, GridMetric.CELL_SIZE_M]
		)
	_free_fixture(fixture)
	return true


func _test_attach_face_snap_table() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("attach face table anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var faces: Array[Dictionary] = [
		{
			"label": "+X",
			"point": Vector3(0.75, 0.25, 0.25),
			"normal": Vector3.RIGHT,
		},
		{
			"label": "-X",
			"point": Vector3(-0.25, 0.25, 0.25),
			"normal": Vector3.LEFT,
		},
		{
			"label": "+Y",
			"point": Vector3(0.25, 0.75, 0.25),
			"normal": Vector3.UP,
		},
		{
			"label": "-Y",
			"point": Vector3(0.25, -0.25, 0.25),
			"normal": Vector3.DOWN,
		},
		{
			"label": "+Z",
			"point": Vector3(0.25, 0.25, 0.75),
			"normal": Vector3.BACK,
		},
		{
			"label": "-Z",
			"point": Vector3(0.25, 0.25, -0.25),
			"normal": Vector3.FORWARD,
		},
	]
	for face: Dictionary in faces:
		var local_point: Vector3 = face["point"]
		var local_normal: Vector3 = face["normal"]
		var target := InteractionHit.create(
			assembly_transform * local_point,
			assembly_transform.basis * local_normal,
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
		var plan := ConstructionPlacement.plan(world, target, frame, 0)
		if not bool(plan.get("valid", false)):
			return _fail("attach face %s plan invalid" % face["label"])
		var snap_context: Dictionary = plan["attach_snap_context"]
		var expected_origin := GridPoseUtil.snap_origin_without_pivot(
			frame,
			snap_context["target_port_cell"],
			snap_context["snap_dir"],
			0
		)
		if plan["origin_cell"] != expected_origin:
			return _fail(
				"attach face %s origin %s != snap %s"
				% [face["label"], plan["origin_cell"], expected_origin]
			)
		var preview := SimulationElement.frame(
			-1,
			assembly_id,
			frame,
			plan["origin_cell"],
			0,
			{}
		)
		if not RuntimeConnectivity.elements_have_rigid_connection(
			anchor_element,
			preview
		):
			return _fail("attach face %s lost rigid connection" % face["label"])
	_free_fixture(fixture)
	return true


func _test_gateway_attach_orientation_replay() -> bool:
	var fixture := _new_gateway_fixture()
	var world: SimulationWorld = fixture["world"]
	var gateway: WorldCommandGateway = fixture["gateway"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("gateway attach replay anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var direct_hit := InteractionHit.create(
		assembly_transform * Vector3(0.75, 0.25, 0.25),
		assembly_transform.basis.x,
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
	var ray_origin := assembly_transform * Vector3(1.25, 0.25, 0.25)
	var ray_direction := (-assembly_transform.basis.x).normalized()
	var baseline := gateway.resolve_construction_placement({
		"direct_hit": direct_hit,
		"ray_origin": ray_origin,
		"ray_direction": ray_direction,
		"archetype_id": "power_source",
		"orientation_index": 0,
	})
	var baseline_plan: Dictionary = baseline.get("selected_plan", {})
	if not bool(baseline_plan.get("valid", false)):
		return _fail("gateway attach replay baseline invalid")
	var baseline_origin: Vector3i = baseline_plan["origin_cell"]
	var snap_context: Dictionary = baseline_plan.get("attach_snap_context", {})
	var locked_metadata: Dictionary = direct_hit.get("metadata", {}).duplicate(true)
	locked_metadata["locked_target_port_cell"] = snap_context.get(
		"target_port_cell",
		Vector3i.ZERO
	)
	locked_metadata["locked_snap_dir"] = snap_context.get("snap_dir", Vector3i.UP)
	direct_hit["metadata"] = locked_metadata
	var held_pivot := GridPoseUtil.world_footprint_pivot(
		baseline_plan["preview_root_transform"],
		baseline_plan["archetype"],
		baseline_origin,
		0
	)
	var orientation_one := _rotate_orientation_index(0, Vector3.UP)
	gateway.reset_construction_snap()
	var rotated := gateway.resolve_construction_placement({
		"direct_hit": direct_hit,
		"ray_origin": ray_origin,
		"ray_direction": ray_direction,
		"archetype_id": "power_source",
		"orientation_index": orientation_one,
		"held_attach_pivot": held_pivot,
	})
	if not bool(rotated.get("selected_plan", {}).get("valid", false)):
		return _fail("gateway attach replay rotated plan invalid")
	gateway.reset_construction_snap()
	var replay := gateway.resolve_construction_placement({
		"direct_hit": direct_hit,
		"ray_origin": ray_origin,
		"ray_direction": ray_direction,
		"archetype_id": "power_source",
		"orientation_index": 0,
		"held_attach_pivot": held_pivot,
	})
	var replay_plan: Dictionary = replay.get("selected_plan", {})
	if not bool(replay_plan.get("valid", false)):
		return _fail("gateway attach replay return-to-O0 invalid")
	if replay_plan["origin_cell"] != baseline_origin:
		return _fail(
			"gateway attach replay origin drift %s -> %s"
			% [baseline_origin, replay_plan["origin_cell"]]
		)
	_free_fixture(fixture)
	return true


## Ray aimed at the center of some exposed (free-neighbor) occupied cell of
## the assembly, from 2m outside along the exposed face normal. Keeps scan
## tests independent of the fixture's exact block layout.
func _exposed_face_ray(
	world: SimulationWorld,
	assembly: SimulationAssembly
) -> Dictionary:
	var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
		world,
		assembly
	)
	for cell_variant: Variant in occupancy.keys():
		var cell: Vector3i = cell_variant
		for direction: Vector3i in ConstructionOccupancyUtil.CELL_NEIGHBOURS:
			if occupancy.has(cell + direction):
				continue
			var normal := Vector3(direction)
			var center: Vector3 = (
				assembly.motion.transform
				* GridMetric.cell_center_meters(cell)
			)
			var world_normal: Vector3 = (
				assembly.motion.transform.basis * normal
			).normalized()
			return {
				"origin": center + world_normal * 2.0,
				"direction": -world_normal,
			}
	return {}


func _count_face_scan_candidates(result: Dictionary) -> int:
	var count := 0
	for candidate: Dictionary in result.get("candidates", []):
		if str(candidate.get("source", "")) == "face_scan":
			count += 1
	return count


func _test_snap_scan_tracks_assembly_motion() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("snap motion anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var resolver := ConstructionSnapResolver.new()
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var aim := func() -> Dictionary:
		var origin: Vector3 = assembly.motion.transform * Vector3(0.5, 0.5, 2.5)
		return resolver.resolve({
			"world": world,
			"archetype": frame,
			"orientation_index": 0,
			"ray_origin": origin,
			"ray_direction": (
				assembly.motion.transform * Vector3(0.5, 0.5, 0.5) - origin
			).normalized(),
			"direct_hit": {},
		})
	if _count_face_scan_candidates(aim.call()) == 0:
		return _fail("snap scan found no faces at initial pose")
	# Stateless scan must follow the live transform with no invalidation step.
	var moved := assembly.motion.duplicate_state()
	moved.transform.origin += Vector3(30.0, 0.0, 0.0)
	if not world.sync_assembly_motion(assembly_id, moved):
		return _fail("snap motion sync failed")
	if _count_face_scan_candidates(aim.call()) == 0:
		return _fail("snap scan lost faces after assembly moved")
	var stale := resolver.resolve({
		"world": world,
		"archetype": frame,
		"orientation_index": 0,
		"ray_origin": Vector3(0.5, 0.5, 2.5),
		"ray_direction": Vector3(0.0, 0.0, -1.0),
		"direct_hit": {},
	})
	if _count_face_scan_candidates(stale) != 0:
		return _fail("snap scan kept faces at the old pose")
	_free_fixture(fixture)
	return true


func _test_snap_vehicle_attach_follows_velocity() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	world.set_resource_amount("player", "plate_metal", 2000.0)
	world.set_resource_amount("player", "girder", 2000.0)
	world.set_resource_amount("player", "mechanism", 2000.0)
	world.set_resource_amount("player", "conduit", 2000.0)
	var composed := RoverComposer.compose(world, RoverIntent.defaults())
	if not bool(composed.get("ok", false)):
		return _fail(
			"vehicle anchor fixture compose failed: %s"
			% str(composed.get("error", ""))
		)
	var assembly_id := int(composed["assembly_id"])
	# Compose spawns terrain-anchored; emulate the runtime release-from-anchor
	# (floating locomotive) so attach permission follows the velocity rule.
	var anchor_joint_ids: Array[int] = []
	for joint: SimulationJoint in world._joints_for_assembly(assembly_id):
		if joint.kind == SimulationJoint.Kind.ANCHOR:
			anchor_joint_ids.append(joint.joint_id)
	for joint_id: int in anchor_joint_ids:
		world._joints.erase(joint_id)
	var assembly := world.get_assembly_raw(assembly_id)
	assembly.bump_revision()
	if world.assembly_has_anchor(assembly_id):
		return _fail("vehicle anchor fixture still terrain-anchored")
	var resolver := ConstructionSnapResolver.new()
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var aim_ray := _exposed_face_ray(world, assembly)
	if aim_ray.is_empty():
		return _fail("vehicle fixture has no exposed face to aim at")
	var aim := func() -> Dictionary:
		return resolver.resolve({
			"world": world,
			"archetype": frame,
			"orientation_index": 0,
			"ray_origin": aim_ray["origin"],
			"ray_direction": aim_ray["direction"],
			"direct_hit": {},
		})
	# Moving rover: attach not allowed, no magnetic faces.
	assembly.motion.linear_velocity = Vector3(3.0, 0.0, 0.0)
	if _count_face_scan_candidates(aim.call()) != 0:
		return _fail("moving rover offered magnetic faces")
	# Parked (coast-to-stop): faces must appear without any structural event.
	assembly.motion.linear_velocity = Vector3.ZERO
	if _count_face_scan_candidates(aim.call()) == 0:
		return _fail("parked rover did not become magnetic")
	# Driving away again: candidates must vanish just as statelessly.
	assembly.motion.linear_velocity = Vector3(3.0, 0.0, 0.0)
	if _count_face_scan_candidates(aim.call()) != 0:
		return _fail("departed rover kept magnetic faces")
	_free_fixture(fixture)
	return true


func _test_snap_resolver_invalid_direct_red_ghost() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	# Drain the store: ground plan is structurally fine but not payable.
	world.set_resource_amount("player", "plate_metal", 0.0)
	world.set_resource_amount("player", "girder", 0.0)
	world.set_resource_amount("player", "mechanism", 0.0)
	world.set_resource_amount("player", "conduit", 0.0)
	world.set_resource_amount("player", "plate_basalt", 0.0)
	world.set_resource_amount("player", "sintered_basalt", 0.0)
	world.set_resource_amount("player", "plate_alloy", 0.0)
	var resolver := ConstructionSnapResolver.new()
	var frame: ElementArchetype = Slice01Archetypes.frame()
	var voxel_hit := _voxel_target(
		Vector3(4.0, 0.0, 0.0),
		Vector3.UP,
		Vector3.FORWARD
	)
	var result := resolver.resolve({
		"world": world,
		"archetype": frame,
		"orientation_index": 0,
		"ray_origin": Vector3(4.0, 1.5, 2.0),
		"ray_direction": Vector3(0.0, -0.5, -1.0).normalized(),
		"direct_hit": voxel_hit,
	})
	var plan: Dictionary = result["selected_plan"]
	if plan.is_empty():
		return _fail("invalid direct hit lost its plan (no red ghost)")
	if bool(plan.get("valid", false)):
		return _fail("unpayable ground plan reported valid")
	if not (result["selected_target"] as Dictionary).get("valid", false):
		return _fail("red ghost target missing")
	_free_fixture(fixture)
	return true


func _test_power_source_attach_rotation_cycle() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var anchor := _spawn_anchored_frame(world)
	if not anchor.is_ok():
		return _fail("power_source attach anchor spawn failed")
	var assembly_id := int(anchor.data["assembly_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	var anchor_element := world.get_element(int(anchor.data["element_id"]))
	var assembly_transform := assembly.motion.transform
	var target := InteractionHit.create(
		assembly_transform * Vector3(0.75, 0.25, 0.25),
		assembly_transform.basis.x,
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
	var source: ElementArchetype = Slice01Archetypes.power_source()
	var baseline_plan := ConstructionPlacement.plan(world, target, source, 0)
	if not bool(baseline_plan.get("valid", false)):
		return _fail("power_source attach baseline plan invalid")
	var held_pivot := _world_footprint_pivot(baseline_plan)
	var visited: Dictionary = {0: true}
	var queue: Array[int] = [0]
	var pivots_by_orient: Dictionary = {0: held_pivot}
	while not queue.is_empty():
		var orientation_index: int = queue.pop_front()
		var step_held: Vector3 = pivots_by_orient[orientation_index]
		for local_axis: Vector3 in [Vector3.UP, Vector3.RIGHT, Vector3.BACK]:
			var next_orientation := _rotate_orientation_index(
				orientation_index,
				local_axis
			)
			if visited.has(next_orientation):
				continue
			visited[next_orientation] = true
			queue.append(next_orientation)
			var plan := ConstructionPlacement.plan(
				world,
				target,
				source,
				next_orientation,
				"player",
				Vector3(INF, INF, INF),
				step_held
			)
			if not bool(plan.get("valid", false)):
				return _fail(
					"power_source attach plan invalid orient %d"
					% next_orientation
				)
			var pivot := _world_footprint_pivot(plan)
			if pivot.distance_to(step_held) > 0.02:
				var snap_context := ConstructionPlacement._attach_snap_context(
					world,
					assembly,
					target,
					target.get("metadata", {})
				)
				var snap_origin := GridPoseUtil.snap_origin_without_pivot(
					source,
					snap_context["target_port_cell"],
					snap_context["snap_dir"],
					next_orientation
				)
				if plan["origin_cell"] != snap_origin:
					return _fail(
						"power_source attach bad origin %d->%d origin %s snap %s drift %.4f"
						% [
							orientation_index,
							next_orientation,
							plan["origin_cell"],
							snap_origin,
							pivot.distance_to(step_held),
						]
					)
			pivots_by_orient[next_orientation] = pivot
			var command: PlaceElementCommand = plan["command"]
			var preview := SimulationElement.frame(
				-1,
				command.assembly_id,
				command.archetype,
				command.origin_cell,
				command.orientation_index,
				{}
			)
			if not RuntimeConnectivity.elements_have_rigid_connection(
				anchor_element,
				preview
			):
				return _fail(
					"power_source attach lost rigid connection orient %d"
					% next_orientation
				)
	if visited.size() != OrientationUtil.ORIENTATION_COUNT:
		return _fail(
			"power_source attach rotation graph incomplete %d/24"
			% visited.size()
		)
	_free_fixture(fixture)
	return true


func _world_footprint_pivot(plan: Dictionary) -> Vector3:
	var root: Transform3D = plan["preview_root_transform"]
	var archetype: ElementArchetype = plan["archetype"]
	var origin_cell: Vector3i = plan["origin_cell"]
	var orientation_index := int(plan["orientation_index"])
	return GridPoseUtil.world_footprint_pivot(
		root,
		archetype,
		origin_cell,
		orientation_index
	)


func _rotate_orientation_index(
	orientation_index: int,
	local_axis: Vector3
) -> int:
	var current := OrientationUtil.orientation_basis(orientation_index)
	var rotated := current * Basis(local_axis.normalized(), PI * 0.5)
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.orientation_basis(index).is_equal_approx(rotated):
			return index
	return orientation_index


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
		"ray_origin": assembly_transform * Vector3(3.75, 0.25, 1.0),
		"ray_direction": Vector3(0.0, -0.2, -1.0).normalized(),
		"archetype_id": "frame",
		"orientation_index": 0,
	}
	var first := gateway.resolve_construction_placement(params)
	if not bool(first.get("selected_plan", {}).get("valid", false)):
		return _fail("performance resolve produced no valid plan")
	for _repeat: int in range(12):
		gateway.resolve_construction_placement(params)
	var repeat_stats: Dictionary = gateway.snap_resolve_stats()
	# The scan is stateless; the budget invariant is that a resolve validates
	# only a handful of plans (first valid + sticky + direct/voxel), never a
	# per-face sweep.
	if int(repeat_stats.get("plans_validated", 0)) > 4:
		return _fail(
			"performance plans_validated %d exceeds lazy-validation budget"
			% int(repeat_stats.get("plans_validated", 0))
		)
	if int(repeat_stats.get("assemblies_scanned", 0)) > 1:
		return _fail("performance scanned assemblies outside the aim corridor")
	if int(repeat_stats.get("faces_scanned", 0)) > 64:
		return _fail(
			"performance faces_scanned %d exceeds corridor bound"
			% int(repeat_stats.get("faces_scanned", 0))
		)
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
			assembly_transform * (
				GridMetric.cell_to_meters(attach_cell)
				+ Vector3(0.75, 0.25, 0.25)
			),
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
	world.set_resource_amount("player", "plate_metal", 1000.0)
	world.set_resource_amount("player", "girder", 1000.0)
	world.set_resource_amount("player", "mechanism", 1000.0)
	world.set_resource_amount("player", "conduit", 1000.0)
	world.set_resource_amount("player", "plate_basalt", 1000.0)
	world.set_resource_amount("player", "sintered_basalt", 1000.0)
	world.set_resource_amount("player", "plate_alloy", 1000.0)
	var session := SimulationSession.new()
	session.name = "SimulationSession"
	session.add_child(world)
	var projection := SimulationPhysicsProjection.new()
	projection.name = "SimulationPhysicsProjection"
	session.add_child(projection)
	var visuals := ElementVisualProjection.new()
	visuals.name = "ElementVisualProjection"
	session.add_child(visuals)
	var piston_visuals := PistonVisualProjection.new()
	piston_visuals.name = "PistonVisualProjection"
	session.add_child(piston_visuals)
	var wheel_visuals := WheelVisualProjection.new()
	wheel_visuals.name = "WheelVisualProjection"
	session.add_child(wheel_visuals)
	var impact := ImpactResolverService.new()
	impact.name = "ImpactResolverService"
	session.add_child(impact)
	var industry_network := IndustryNetworkProjection.new()
	industry_network.name = "IndustryNetworkProjection"
	session.add_child(industry_network)
	var industry_ports := IndustryPortProjection.new()
	industry_ports.name = "IndustryPortProjection"
	session.add_child(industry_ports)
	var world_loot := WorldLootProjection.new()
	world_loot.name = "WorldLootProjection"
	session.add_child(world_loot)
	root.add_child(session)
	session._ready()
	var gateway := WorldCommandGateway.new()
	root.add_child(gateway)
	gateway.terrain_path = NodePath("../VoxelTerrain")
	gateway.placed_blocks_path = NodePath("../PlacedBlocks")
	gateway.simulation_session_path = NodePath("../SimulationSession")
	gateway._ready()
	return {
		"root": root,
		"world": world,
		"gateway": gateway,
		"session": session,
	}


func _new_fixture() -> Dictionary:
	var root := Node.new()
	add_child(root)
	var world := SimulationWorld.new()
	root.add_child(world)
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "plate_metal", 1000.0)
	world.set_resource_amount("player", "girder", 1000.0)
	world.set_resource_amount("player", "mechanism", 1000.0)
	world.set_resource_amount("player", "conduit", 1000.0)
	world.set_resource_amount("player", "plate_basalt", 1000.0)
	world.set_resource_amount("player", "sintered_basalt", 1000.0)
	world.set_resource_amount("player", "plate_alloy", 1000.0)
	return {
		"root": root,
		"world": world,
	}


func _free_fixture(fixture: Dictionary) -> void:
	var root: Node = fixture["root"]
	root.queue_free()


func _test_gateway_voxel_place_spawns_visual() -> bool:
	var fixture := _new_gateway_fixture()
	var world: SimulationWorld = fixture["world"]
	var gateway: WorldCommandGateway = fixture["gateway"]
	var session: SimulationSession = fixture["session"]
	var large_frame := Slice01Archetypes.large_frame()
	var point := Vector3(0.0, 518.0, 2.0)
	var surface_up := point.normalized()
	var target := _voxel_target(point, surface_up, Vector3.FORWARD)
	target["surface_up"] = surface_up
	var plan := gateway.preview_construction(target, "large_frame", 0)
	if not bool(plan.get("valid", false)):
		return _fail("moon-like gateway preview_construction invalid")
	var plan_origin: Vector3 = plan["assembly_world_transform"].origin
	if plan_origin.distance_to(point) > 15.0:
		return _fail(
			"moon-like plan origin too far from hit (origin=%s hit=%s)"
			% [plan_origin, point]
		)
	var place: PlaceElementCommand = plan["command"]
	var result := world.apply_structural_command_now(place)
	if not result.is_ok():
		return _fail("moon-like place failed: %s" % str(result.reason))
	var assembly_id := int(result.data["assembly_id"])
	var body := session.projection.get_physics_body(assembly_id)
	if body == null:
		return _fail("moon-like place missing physics body")
	if body.global_transform.origin.distance_to(plan_origin) > 0.05:
		return _fail(
			"physics body origin != plan (body=%s plan=%s)"
			% [body.global_transform.origin, plan_origin]
		)
	var visual_count := 0
	for child_node: Node in body.get_children():
		if child_node.has_meta("element_visual"):
			visual_count += 1
	if visual_count <= 0:
		return _fail("moon-like place has no element visual meshes on body")
	_free_gateway_fixture(fixture)
	return true


func _free_gateway_fixture(fixture: Dictionary) -> void:
	_free_fixture(fixture)


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
