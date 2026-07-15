extends Node

const ROVER_FRAME := preload(
	"res://resources/archetypes/slice01/rover_frame.tres"
)
const WHEEL_SUSPENSION := preload(
	"res://resources/archetypes/slice01/wheel_suspension.tres"
)
const ROVER_DEMO_SPAWN := preload("res://scripts/authoring/rover_demo_spawn.gd")
const DRIVE_WHEEL := preload(
	"res://resources/archetypes/slice01/drive_wheel.tres"
)


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var tests: Array[Callable] = [
		_test_socket_tag_blocks_frame_to_wheel_socket,
		_test_wheel_placement_requires_suspension,
		_test_wheel_placement_rejects_occupied_socket,
		_test_wheel_pair_discovery,
		_test_locomotive_requires_complete_pair,
		_test_configure_wheel_steerable,
		_test_configure_suspension_rejects_invalid_travel,
		_test_dismantle_wheel_breaks_locomotive,
		_test_demo_rover_spawn,
		_test_demo_rover_wheel_sockets_point_down,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("SIMULATION-WHEEL-V1: PASS")
	get_tree().quit(0)


func _boot_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 500.0)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)
	world.get_archetype_registry().register(Slice01Archetypes.foundation())
	world.get_archetype_registry().register(Slice01Archetypes.frame())
	return world


func _spawn_foundation(world: SimulationWorld) -> Dictionary:
	var spawn := SpawnBlueprintCommand.new()
	spawn.blueprint = _single_blueprint(Slice01Archetypes.foundation())
	spawn.grid_frame = GridTransform.identity()
	var result := world.apply_structural_command_now(spawn)
	if not result.is_ok():
		return {}
	return result.data


func _place(
	world: SimulationWorld,
	assembly_id: int,
	revision: int,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int = 0
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = revision
	place.archetype = archetype
	place.origin_cell = origin_cell
	place.orientation_index = orientation_index
	place.store_id = "player"
	return world.apply_structural_command_now(place)


func _orientation_with_local_face(
	local_face: Vector3i,
	world_direction: Vector3i
) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if (
			OrientationUtil.rotate_direction(local_face, index)
			== world_direction
		):
			return index
	return 0


func _build_suspension_only(world: SimulationWorld) -> Dictionary:
	var foundation := _spawn_foundation(world)
	if foundation.is_empty():
		return {"error": "foundation"}
	var assembly_id := int(foundation["assembly_id"])
	var revision := int(foundation["topology_revision"])
	var chassis := _place(
		world,
		assembly_id,
		revision,
		Slice01Archetypes.frame(),
		Vector3i(4, 0, 0)
	)
	if not chassis.is_ok():
		return {"error": "chassis: %s" % chassis.reason}
	revision = int(chassis.data["topology_revision"])
	var suspension_orientation := _orientation_with_local_face(
		Vector3i.RIGHT,
		Vector3i.LEFT
	)
	var suspension := _place(
		world,
		assembly_id,
		revision,
		WHEEL_SUSPENSION,
		Vector3i(5, 0, 0),
		suspension_orientation
	)
	if not suspension.is_ok():
		return {"error": "suspension: %s" % suspension.reason}
	_weld(world, int(chassis.data["element_id"]))
	_weld(world, int(suspension.data["element_id"]))
	return {
		"world": world,
		"assembly_id": assembly_id,
		"suspension_id": int(suspension.data["element_id"]),
		"suspension_orientation": suspension_orientation,
		"revision": int(suspension.data["topology_revision"]),
	}


func _build_complete_pair(world: SimulationWorld) -> Dictionary:
	var partial := _build_suspension_only(world)
	if partial.has("error"):
		return {}
	var wheel := _place(
		partial["world"],
		int(partial["assembly_id"]),
		int(partial["revision"]),
		DRIVE_WHEEL,
		Vector3i(5, -1, 0)
	)
	if not wheel.is_ok():
		partial["world"].free()
		return {"error": "wheel: %s" % wheel.reason}
	_weld(partial["world"], int(wheel.data["element_id"]))
	partial["wheel_id"] = int(wheel.data["element_id"])
	partial["revision"] = int(wheel.data["topology_revision"])
	return partial


func _test_socket_tag_blocks_frame_to_wheel_socket() -> bool:
	var world := _boot_world()
	var partial := _build_suspension_only(world)
	if partial.is_empty() or partial.has("error"):
		world.free()
		return _fail(
			"suspension setup failed: %s"
			% partial.get("error", "unknown")
		)
	var deny := _place(
		world,
		int(partial["assembly_id"]),
		int(partial["revision"]),
		ROVER_FRAME,
		Vector3i(5, -1, 0),
		int(partial["suspension_orientation"])
	)
	world.free()
	if deny.is_ok():
		return _fail("frame attached to wheel socket")
	if deny.reason != StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION:
		return _fail("expected incompatible_connection, got %s" % deny.reason)
	return true


func _test_wheel_placement_requires_suspension() -> bool:
	var world := _boot_world()
	var partial := _build_suspension_only(world)
	if partial.is_empty() or partial.has("error"):
		world.free()
		return _fail(
			"suspension setup failed: %s"
			% partial.get("error", "unknown")
		)
	var deny := _place(
		world,
		int(partial["assembly_id"]),
		int(partial["revision"]),
		DRIVE_WHEEL,
		Vector3i(7, 0, 0)
	)
	world.free()
	if deny.is_ok():
		return _fail("wheel placed without adjacent suspension")
	if StringName(deny.data.get("detail", &"")) != &"wheel_socket_required":
		return _fail(
			"expected wheel_socket_required, got %s / %s"
			% [deny.reason, deny.data.get("detail", "")]
		)
	return true


func _test_wheel_placement_rejects_occupied_socket() -> bool:
	var world := _boot_world()
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		world.free()
		return _fail(
			"complete pair setup failed: %s"
			% built.get("error", "unknown")
		)
	var command := PlaceElementCommand.new()
	command.assembly_id = int(built["assembly_id"])
	command.archetype = DRIVE_WHEEL
	command.origin_cell = Vector3i(5, -1, 0)
	command.orientation_index = 0
	var preview := SimulationElement.frame(
		-1,
		command.assembly_id,
		DRIVE_WHEEL,
		command.origin_cell,
		command.orientation_index,
		{"construction_component": 1.0}
	)
	var result: Variant = WheelPlacementUtil.validate_wheel_placement(
		world,
		command,
		preview
	)
	world.free()
	if (
		not result is StructuralCommandResult
		or (result as StructuralCommandResult).is_ok()
	):
		return _fail("occupied socket should be rejected")
	var wheel_result := result as StructuralCommandResult
	if StringName(wheel_result.data.get("detail", &"")) != &"socket_occupied":
		return _fail(
			"expected socket_occupied, got %s"
			% wheel_result.data.get("detail", "")
		)
	return true


func _test_wheel_pair_discovery() -> bool:
	var world := _boot_world()
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		world.free()
		return _fail(
			"complete pair setup failed: %s"
			% built.get("error", "unknown")
		)
	var pairs := WheelSimulationService.discover_pairs(
		world,
		int(built["assembly_id"])
	)
	world.free()
	if pairs.size() != 1:
		return _fail("expected one wheel pair, got %d" % pairs.size())
	if int(pairs[0].get("wheel_element_id", 0)) != int(built["wheel_id"]):
		return _fail("pair wheel id mismatch")
	if not WheelSimulationService.is_complete_pair(pairs[0]):
		return _fail("pair should be complete")
	return true


func _test_locomotive_requires_complete_pair() -> bool:
	var world := _boot_world()
	var partial := _build_suspension_only(world)
	if partial.is_empty():
		world.free()
		return _fail("suspension-only setup failed")
	if WheelSimulationService.is_locomotive_assembly(
		world,
		int(partial["assembly_id"])
	):
		world.free()
		return _fail("suspension-only assembly should not be locomotive")
	world.free()
	world = _boot_world()
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		world.free()
		return _fail(
			"complete pair setup failed: %s"
			% built.get("error", "unknown")
		)
	if not WheelSimulationService.is_locomotive_assembly(
		world,
		int(built["assembly_id"])
	):
		world.free()
		return _fail("complete pair assembly should be locomotive")
	world.free()
	return true


func _test_configure_wheel_steerable() -> bool:
	var world := _boot_world()
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		world.free()
		return _fail(
			"complete pair setup failed: %s"
			% built.get("error", "unknown")
		)
	var command := ConfigureWheelCommand.new()
	command.wheel_element_id = int(built["wheel_id"])
	command.steerable_set = true
	command.steerable = true
	var result := world.apply_configure_wheel(command)
	if StringName(result.get("reason", &"")) != &"ok":
		world.free()
		return _fail("configure wheel failed: %s" % result.get("reason"))
	var state := world.ensure_wheel_instance_state(int(built["wheel_id"]))
	if not state.steerable:
		world.free()
		return _fail("steerable not persisted")
	world.free()
	return true


func _test_configure_suspension_rejects_invalid_travel() -> bool:
	var world := _boot_world()
	var partial := _build_suspension_only(world)
	if partial.is_empty() or partial.has("error"):
		world.free()
		return _fail(
			"suspension setup failed: %s"
			% partial.get("error", "unknown")
		)
	var command := ConfigureSuspensionCommand.new()
	command.suspension_element_id = int(partial["suspension_id"])
	command.travel_m = 5.0
	var result := world.apply_configure_suspension(command)
	world.free()
	if StringName(result.get("reason", &"")) == &"ok":
		return _fail("invalid travel should be rejected")
	return true


func _test_dismantle_wheel_breaks_locomotive() -> bool:
	var world := _boot_world()
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		world.free()
		return _fail(
			"complete pair setup failed: %s"
			% built.get("error", "unknown")
		)
	var assembly_id := int(built["assembly_id"])
	if not WheelSimulationService.is_locomotive_assembly(world, assembly_id):
		world.free()
		return _fail("expected locomotive before dismantle")
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = int(built["wheel_id"])
	dismantle.expected_assembly_revision = int(built["revision"])
	dismantle.store_id = "player"
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok():
		world.free()
		return _fail("wheel dismantle failed: %s" % result.reason)
	if WheelSimulationService.is_locomotive_assembly(world, assembly_id):
		world.free()
		return _fail("assembly should stop being locomotive after wheel removed")
	world.free()
	return true


func _test_demo_rover_spawn() -> bool:
	var world := SimulationWorld.new()
	var session := SimulationSession.new()
	var projection := SimulationPhysicsProjection.new()
	world.name = "SimulationWorld"
	projection.name = "SimulationPhysicsProjection"
	session.add_child(world)
	session.add_child(projection)
	session.world = world
	session.projection = projection
	projection.bind_world(world)
	world.ensure_resource_store("player")
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)
	var result: Dictionary = ROVER_DEMO_SPAWN.spawn_on_terrain(
		session,
		Vector3(8.0, 0.0, 0.0)
	)
	var assembly_id := int(result.get("assembly_id", 0))
	var ok := bool(result.get("ok", false))
	var locomotive := (
		ok
		and WheelSimulationService.is_locomotive_assembly(world, assembly_id)
	)
	IndustryElectricBudget.apply_tick(world, 1.0)
	var wheel_powered := false
	var module_ids: Dictionary = result.get("element_ids", {})
	for key: String in ["fl", "fr", "rl", "rr"]:
		var pair_variant: Variant = module_ids.get(key, {})
		if not pair_variant is Dictionary:
			continue
		var wheel_id := int((pair_variant as Dictionary).get("wheel", 0))
		if wheel_id <= 0:
			continue
		var runtime := world.get_industry_element_runtime(wheel_id)
		if runtime != null and runtime.powered:
			wheel_powered = true
			break
	session.free()
	if not ok:
		return _fail("demo rover spawn failed: %s" % result.get("error", ""))
	if not locomotive:
		return _fail("demo rover should be locomotive")
	if not wheel_powered:
		return _fail("demo rover wheels should be powered after electric tick")
	return true


func _test_demo_rover_wheel_sockets_point_down() -> bool:
	var world := SimulationWorld.new()
	var session := SimulationSession.new()
	var projection := SimulationPhysicsProjection.new()
	world.name = "SimulationWorld"
	projection.name = "SimulationPhysicsProjection"
	session.add_child(world)
	session.add_child(projection)
	session.world = world
	session.projection = projection
	projection.bind_world(world)
	world.ensure_resource_store("player")
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)
	var result: Dictionary = ROVER_DEMO_SPAWN.spawn_on_terrain(
		session,
		Vector3(8.0, 0.0, 0.0)
	)
	var assembly_id := int(result.get("assembly_id", 0))
	if not bool(result.get("ok", false)):
		session.free()
		return _fail("demo rover spawn failed for socket test")
	var body := projection.get_physics_body(assembly_id) as RigidBody3D
	if body == null:
		session.free()
		return _fail("demo rover missing rigid body for socket test")
	for pair: Dictionary in WheelSimulationService.discover_pairs(world, assembly_id):
		if not WheelSimulationService.is_complete_pair(pair):
			continue
		var suspension: SimulationElement = pair.get("suspension_element")
		var socket_pose := WheelProjectionUtil.mount_pad_anchor_assembly_local(
			suspension,
			"wheel_socket"
		)
		if socket_pose.is_empty():
			session.free()
			return _fail("suspension missing wheel_socket pose")
		var ray_dir_world := (
			body.global_transform.basis
			* Vector3(socket_pose["direction"])
		).normalized()
		if ray_dir_world.dot(Vector3.DOWN) < 0.7:
			session.free()
			return _fail(
				"wheel socket should raycast down, got %s"
				% str(ray_dir_world)
			)
	session.free()
	return true


func _weld(world: SimulationWorld, element_id: int) -> void:
	var element := world.get_element(element_id)
	if element == null:
		return
	var weld := WeldElementCommand.new()
	weld.element_id = element_id
	weld.expected_state_revision = element.state_revision
	weld.max_material_amount = 100.0
	weld.store_id = "player"
	world.apply_structural_command_now(weld)


func _single_blueprint(archetype: ElementArchetype) -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"test_wheel_fixture",
		[_placement("element_0", archetype, Vector3i.ZERO)]
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


func _fail(message: String) -> bool:
	push_error("test_simulation_wheel: %s" % message)
	get_tree().quit(1)
	return false
