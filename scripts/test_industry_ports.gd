extends Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _test_distance_pair_across_assemblies():
		return
	if not _test_overlength_rejected():
		return
	if not _test_cargo_rejected():
		return
	if not _test_diagnosis_messages():
		return
	if not await _test_port_projection_smoke():
		return
	if not await _test_port_projection_bounded_and_stable():
		return
	if not _test_port_marker_world_basis_parity():
		return
	if not await _test_port_marker_local_pose_after_motion():
		return
	print("INDUSTRY-PORTS-V1: PASS")
	get_tree().quit(0)


func _test_distance_pair_across_assemblies() -> bool:
	var world := SimulationWorld.new()
	var source_spawn := _spawn_single_at(
		world,
		"source_0",
		"power_source",
		Vector3i.ZERO
	)
	var distributor_spawn := _spawn_single_at(
		world,
		"distributor_0",
		"power_distributor",
		Vector3i(5, 0, 2)
	)
	if not source_spawn.is_ok() or not distributor_spawn.is_ok():
		world.free()
		return _fail("cross-assembly cable fixture spawn failed")
	var source_id := int(source_spawn.data["local_to_element_id"]["source_0"])
	var distributor_id := int(
		distributor_spawn.data["local_to_element_id"]["distributor_0"]
	)
	if (
		world.get_element(source_id).assembly_id
		== world.get_element(distributor_id).assembly_id
	):
		world.free()
		return _fail("distance cable fixture must use separate assemblies")
	var diagnosis := IndustryElectricPortUtil.diagnose_electric_pair(
		world,
		source_id,
		distributor_id
	)
	var pair: Dictionary = diagnosis.get("pair", {})
	if StringName(diagnosis.get("reason", &"")) != &"ok" or pair.is_empty():
		world.free()
		return _fail(
			"expected compatible distance pair, got reason=%s pair=%s"
			% [diagnosis.get("reason", &""), pair]
		)
	if float(diagnosis.get("distance_m", INF)) >= 12.0:
		world.free()
		return _fail("distance-pair fixture unexpectedly exceeds cable limit")
	if str(pair.get("port_a_id", "")) != "power_out":
		world.free()
		return _fail("expected source power_out, got %s" % pair.get("port_a_id", ""))
	if str(pair.get("port_b_id", "")) != "power_in":
		world.free()
		return _fail(
			"expected distributor power_in, got %s" % pair.get("port_b_id", "")
		)
	var link := world.connect_network(
		source_id,
		str(pair["port_a_id"]),
		distributor_id,
		str(pair["port_b_id"])
	)
	if not link.is_ok():
		world.free()
		return _fail("connect_network failed: %s" % link.reason)
	if world.list_assemblies().size() != 2:
		world.free()
		return _fail("electric link must not mechanically merge assemblies")
	var snapshot := world.capture_snapshot()
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(snapshot)
	if (
		restored == null
		or restored.list_electric_links().size() != 1
		or restored.list_assemblies().size() != 2
	):
		if restored != null:
			restored.free()
		world.free()
		return _fail("cross-assembly cable did not survive snapshot restore")
	restored.free()
	var distributor := world.get_element(distributor_id)
	var assembly := world.get_assembly_raw(distributor.assembly_id)
	var moved := assembly.motion.duplicate_state()
	moved.transform.origin += Vector3(20.0, 0.0, 0.0)
	if not world.sync_assembly_motion(assembly.assembly_id, moved):
		world.free()
		return _fail("failed to move cable endpoint assembly")
	world.get_industry_network().ensure_graph_current(world)
	if not world.list_electric_links().is_empty():
		world.free()
		return _fail("overlength moving cable must be pruned")
	world.free()
	return true


func _test_overlength_rejected() -> bool:
	var world := SimulationWorld.new()
	var source_spawn := _spawn_single_at(
		world,
		"source_0",
		"power_source",
		Vector3i.ZERO
	)
	var distributor_spawn := _spawn_single_at(
		world,
		"distributor_0",
		"power_distributor",
		Vector3i(13, 0, 0)
	)
	if not source_spawn.is_ok() or not distributor_spawn.is_ok():
		world.free()
		return _fail("overlength fixture spawn failed")
	var source_id := int(source_spawn.data["local_to_element_id"]["source_0"])
	var distributor_id := int(
		distributor_spawn.data["local_to_element_id"]["distributor_0"]
	)
	var diagnosis := IndustryElectricPortUtil.diagnose_electric_pair(
		world,
		source_id,
		distributor_id
	)
	if not diagnosis.get("pair", {}).is_empty():
		world.free()
		return _fail("overlength placement must not expose a cable pair")
	var reason := StringName(diagnosis.get("reason", &""))
	if reason != &"cable_too_long":
		world.free()
		return _fail(
			"expected cable_too_long for 13 m placement, got %s"
			% reason
		)
	var result := world.connect_network(
		source_id,
		"power_out",
		distributor_id,
		"power_in"
	)
	if (
		result.is_ok()
		or result.reason != StructuralCommandResult.REASON_CABLE_TOO_LONG
	):
		world.free()
		return _fail("authority must reject overlength cable")
	world.free()
	return true


func _test_cargo_rejected() -> bool:
	var world := SimulationWorld.new()
	var drill_spawn := _spawn_single_at(
		world,
		"drill_0",
		"stationary_drill",
		Vector3i.ZERO
	)
	var pipe_spawn := _spawn_single_at(
		world,
		"pipe_0",
		"cargo_pipe",
		Vector3i(1, 0, 0)
	)
	if not drill_spawn.is_ok() or not pipe_spawn.is_ok():
		world.free()
		return _fail("cargo rejection fixture spawn failed")
	var result := world.connect_network(
		int(drill_spawn.data["local_to_element_id"]["drill_0"]),
		"cargo_out",
		int(pipe_spawn.data["local_to_element_id"]["pipe_0"]),
		"cargo_through_nx"
	)
	if (
		result.is_ok()
		or result.reason
		!= StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
	):
		world.free()
		return _fail("connect_network must reject cargo ports")
	world.free()
	return true


func _test_diagnosis_messages() -> bool:
	var world := SimulationWorld.new()
	var only_source := _spawn_single(world, "source_0", "power_source", Vector3i.ZERO)
	if not only_source.is_ok():
		world.free()
		return _fail("single source spawn failed")
	var source_id := int(only_source.data["local_to_element_id"]["source_0"])
	var empty_diagnosis := IndustryElectricPortUtil.diagnose_electric_pair(
		world,
		source_id,
		99999
	)
	if StringName(empty_diagnosis.get("reason", &"")) != &"invalid_target":
		world.free()
		return _fail("missing element should report invalid_target")
	world.free()
	return true


func _test_port_projection_smoke() -> bool:
	var fixture := _new_projection_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: IndustryPortProjection = fixture["projection"]
	var physics: SimulationPhysicsProjection = fixture["physics"]
	projection.set_presentation_state(true, [int(fixture["element_id"])])
	await get_tree().process_frame
	if projection.marker_count() <= 0:
		_free_fixture(fixture)
		return _fail("expected at least one port marker after rebuild")
	var element := world.get_element(int(fixture["element_id"]))
	var body := physics.get_physics_body(element.assembly_id)
	var marker_found := false
	for child: Node in body.get_children():
		if str(child.name).begins_with(IndustryPortProjection.MARKER_PREFIX):
			marker_found = true
			break
	if not marker_found:
		_free_fixture(fixture)
		return _fail("port marker must be a local assembly-body child")
	_free_fixture(fixture)
	return true


func _test_port_projection_bounded_and_stable() -> bool:
	var fixture := _new_large_projection_fixture(24)
	var projection: IndustryPortProjection = fixture["projection"]
	var world: SimulationWorld = fixture["world"]
	var element_ids: Array = fixture["element_ids"]
	projection.set_presentation_state(true, element_ids)
	await get_tree().process_frame
	if projection.visible_element_count() != 2:
		_free_fixture(fixture)
		return _fail(
			"projection must clamp real marker scope to two elements, got %d"
			% projection.visible_element_count()
		)
	var expected_max := 0
	for index: int in range(2):
		expected_max += IndustryPortUtil.list_industry_ports(
			world.get_element(int(element_ids[index]))
		).size()
	if projection.marker_count() > expected_max:
		_free_fixture(fixture)
		return _fail(
			"marker count %d exceeds two-element port bound %d"
			% [projection.marker_count(), expected_max]
		)
	var rebuilds_before := projection.rebuild_count()
	for _frame: int in range(20):
		projection.set_presentation_state(true, element_ids)
	if projection.rebuild_count() != rebuilds_before:
		_free_fixture(fixture)
		return _fail("unchanged presentation frames rebuilt port markers")
	projection.set_presentation_state(true, [])
	if projection.marker_count() != 0:
		_free_fixture(fixture)
		return _fail("empty target set must render zero real-element markers")
	_free_fixture(fixture)
	return true


func _test_port_marker_world_basis_parity() -> bool:
	var world := SimulationWorld.new()
	var orientation_index := _find_orientation(Vector3i.FORWARD, Vector3i.RIGHT)
	if orientation_index < 0:
		world.free()
		return _fail("failed to find yaw orientation index")
	var spawn := _spawn_single_at(
		world,
		"source_0",
		"power_source",
		Vector3i.ZERO,
		orientation_index
	)
	if not spawn.is_ok():
		world.free()
		return _fail("rotated port marker fixture spawn failed")
	var element_id := int(spawn.data["local_to_element_id"]["source_0"])
	var element := world.get_element(element_id)
	var port := IndustryPortUtil.find_port(element, "power_out")
	if port == null:
		world.free()
		return _fail("power_out port missing")
	var marker_tf := IndustryPortUtil.port_marker_world_transform(
		world,
		element,
		port
	)
	var assembly := world.get_assembly_raw(element.assembly_id)
	var local_tf := IndustryPortUtil.port_marker_local_transform(
		element,
		port
	)
	var expected := assembly.motion.transform * local_tf
	if marker_tf.origin.distance_to(expected.origin) > 0.01:
		world.free()
		return _fail("port marker world origin mismatch on rotated element")
	if not marker_tf.basis.is_equal_approx(expected.basis):
		world.free()
		return _fail("port marker world basis mismatch on rotated element")
	world.free()
	return true


func _test_port_marker_local_pose_after_motion() -> bool:
	var fixture := _new_projection_fixture()
	var world: SimulationWorld = fixture["world"]
	var physics: SimulationPhysicsProjection = fixture["physics"]
	var projection: IndustryPortProjection = fixture["projection"]
	var element_id := int(fixture["element_id"])
	projection.set_presentation_state(true, [element_id])
	await get_tree().process_frame
	var element := world.get_element(element_id)
	var port := IndustryPortUtil.find_port(element, "power_out")
	if port == null:
		_free_fixture(fixture)
		return _fail("power_out port missing for motion fixture")
	var body := physics.get_physics_body(element.assembly_id)
	var marker: Node3D = null
	for child: Node in body.get_children():
		if str(child.name).begins_with(IndustryPortProjection.MARKER_PREFIX):
			marker = child as Node3D
			break
	if marker == null:
		_free_fixture(fixture)
		return _fail("port marker missing on assembly body")
	var local_before := marker.transform
	var assembly := world.get_assembly_raw(element.assembly_id)
	var moved := assembly.motion.duplicate_state()
	moved.transform.origin += Vector3(4.0, 1.0, -2.0)
	moved.transform = moved.transform.rotated(Vector3.UP, 0.35)
	if not world.sync_assembly_motion(element.assembly_id, moved):
		_free_fixture(fixture)
		return _fail("motion sync failed for port marker fixture")
	body.global_transform = moved.transform
	projection.rebuild_all()
	await get_tree().process_frame
	if not marker.transform.is_equal_approx(local_before):
		_free_fixture(fixture)
		return _fail("port marker local pose changed after assembly motion")
	var expected_world := moved.transform * local_before
	if marker.global_transform.origin.distance_to(expected_world.origin) > 0.02:
		_free_fixture(fixture)
		return _fail("port marker world pose did not follow assembly body")
	_free_fixture(fixture)
	return true


func _find_orientation(from: Vector3i, to: Vector3i) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.rotate_direction(from, index) == to:
			return index
	return -1


func _spawn_single(
	world: SimulationWorld,
	local_id: String,
	archetype_id: String,
	cell: Vector3i
) -> StructuralCommandResult:
	return _spawn(
		world,
		BlueprintBaker.bake_from_placements(
			"industry_ports_single",
			[
				_placement(
					local_id,
					Slice01Archetypes.load_required(archetype_id),
					cell
				),
			]
		),
		GridTransform.identity()
	)


func _spawn_single_at(
	world: SimulationWorld,
	local_id: String,
	archetype_id: String,
	world_cell: Vector3i,
	orientation_index: int = 0
) -> StructuralCommandResult:
	var frame := GridTransform.identity()
	frame.translation = world_cell
	return _spawn(
		world,
		BlueprintBaker.bake_from_placements(
			"industry_ports_%s" % local_id,
			[
				_placement(
					local_id,
					Slice01Archetypes.load_required(archetype_id),
					Vector3i.ZERO,
					orientation_index
				),
			]
		),
		frame
	)


func _placement(
	local_id: String,
	archetype: ElementArchetype,
	cell: Vector3i,
	orientation_index: int = 0
) -> BlueprintElementPlacement:
	var placement := BlueprintElementPlacement.new()
	placement.local_id = local_id
	placement.archetype = archetype
	placement.origin_cell = cell
	placement.orientation_index = orientation_index
	return placement


func _spawn(
	world: SimulationWorld,
	blueprint: Blueprint,
	grid_frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = grid_frame
	return world.apply_structural_command_now(command)


func _new_projection_fixture() -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var world := SimulationWorld.new()
	root.add_child(world)
	var physics := SimulationPhysicsProjection.new()
	root.add_child(physics)
	physics.bind_world(world)
	var projection := IndustryPortProjection.new()
	root.add_child(projection)
	var spawn := _spawn_single(
		world,
		"source_0",
		"power_source",
		Vector3i.ZERO
	)
	if not spawn.is_ok():
		push_error("projection fixture spawn failed")
	var element_id := int(spawn.data["local_to_element_id"]["source_0"])
	projection.bind(world, physics)
	return {
		"root": root,
		"world": world,
		"physics": physics,
		"projection": projection,
		"element_id": element_id,
	}


func _new_large_projection_fixture(element_count: int) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var world := SimulationWorld.new()
	root.add_child(world)
	var physics := SimulationPhysicsProjection.new()
	root.add_child(physics)
	physics.bind_world(world)
	var projection := IndustryPortProjection.new()
	root.add_child(projection)
	var placements: Array[BlueprintElementPlacement] = []
	for index: int in range(element_count):
		placements.append(
			_placement(
				"source_%d" % index,
				Slice01Archetypes.load_required("power_source"),
				Vector3i(index, 0, 0)
			)
		)
	var spawn := _spawn(
		world,
		BlueprintBaker.bake_from_placements(
			"industry_ports_large_assembly",
			placements
		),
		GridTransform.identity()
	)
	var element_ids: Array = []
	if not spawn.is_ok():
		push_error("large projection fixture spawn failed: %s" % spawn.reason)
	else:
		var mapping: Dictionary = spawn.data["local_to_element_id"]
		for index: int in range(element_count):
			element_ids.append(
				int(mapping["source_%d" % index])
			)
	projection.bind(world, physics)
	return {
		"root": root,
		"world": world,
		"projection": projection,
		"element_ids": element_ids,
	}


func _free_fixture(fixture: Dictionary) -> void:
	var root: Node = fixture.get("root")
	if is_instance_valid(root):
		root.queue_free()


func _fail(reason: String) -> bool:
	print("INDUSTRY-PORTS-V1: FAIL %s" % reason)
	get_tree().quit(1)
	return false
