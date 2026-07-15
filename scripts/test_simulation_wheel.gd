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
		_test_wheel_snapshot_roundtrip,
		_test_dismantle_wheel_breaks_locomotive,
		_test_demo_rover_spawn,
		_test_demo_rover_wheel_sockets_point_down,
		_test_incremental_build_releases_on_activation,
		_test_custom_com_point_velocity,
		_test_ten_wheel_runtime_snapshots,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	if not await _test_demo_rover_drive_and_steer():
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


func _boot_demo_session() -> SimulationSession:
	var session_scene: PackedScene = load(
		"res://scenes/simulation_session.tscn"
	)
	var session := session_scene.instantiate() as SimulationSession
	add_child(session)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		session.world.get_archetype_registry().register(archetype)
	return session


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
	if StringName(result.get("reason", &"")) == &"ok":
		world.free()
		return _fail("invalid travel should be rejected")
	command.travel_m = NAN
	result = world.apply_configure_suspension(command)
	world.free()
	if StringName(result.get("reason", &"")) == &"ok":
		return _fail("non-finite suspension tuning should be rejected")
	return true


func _test_wheel_snapshot_roundtrip() -> bool:
	var world := _boot_world()
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		world.free()
		return _fail("wheel snapshot fixture failed")
	var wheel_command := ConfigureWheelCommand.new()
	wheel_command.wheel_element_id = int(built["wheel_id"])
	wheel_command.steerable_set = true
	wheel_command.steerable = true
	wheel_command.drive_torque_scale = 0.6
	if StringName(
		world.apply_configure_wheel(wheel_command).get("reason", &"")
	) != &"ok":
		world.free()
		return _fail("wheel snapshot configure failed")
	var suspension_command := ConfigureSuspensionCommand.new()
	suspension_command.suspension_element_id = int(built["suspension_id"])
	suspension_command.travel_m = 0.8
	if StringName(
		world.apply_configure_suspension(suspension_command).get("reason", &"")
	) != &"ok":
		world.free()
		return _fail("suspension snapshot configure failed")
	var snapshot := world.capture_snapshot()
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(
		snapshot
	)
	if restored == null:
		world.free()
		return _fail(
			"wheel snapshot restore failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	var wheel_state: WheelInstanceState = restored.ensure_wheel_instance_state(
		wheel_command.wheel_element_id
	)
	var suspension_state: SuspensionInstanceState = (
		restored.ensure_suspension_instance_state(
			suspension_command.suspension_element_id
		)
	)
	var equal: bool = SimulationSnapshot.semantic_equals(
		snapshot,
		restored.capture_snapshot()
	)
	var valid: bool = (
		wheel_state.steerable
		and is_equal_approx(wheel_state.drive_torque_scale, 0.6)
		and is_equal_approx(suspension_state.travel_m, 0.8)
		and equal
	)
	restored.free()
	world.free()
	if not valid:
		return _fail("wheel/suspension instance state did not roundtrip")
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
	var session := _boot_demo_session()
	var world := session.world
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
	var activated := (
		ok
		and world.get_locomotion_controller(assembly_id).is_activated()
	)
	if ok and not activated:
		world.get_locomotion_controller(assembly_id).activate()
		activated = true
	var module_ids: Dictionary = result.get("element_ids", {})
	var wheelbase_m := -1.0
	var front_pair: Dictionary = module_ids.get("fl", {})
	var rear_pair: Dictionary = module_ids.get("rl", {})
	var front_suspension := world.get_element(
		int(front_pair.get("suspension", 0))
	)
	var rear_suspension := world.get_element(
		int(rear_pair.get("suspension", 0))
	)
	if front_suspension != null and rear_suspension != null:
		wheelbase_m = (
			absf(
				float(
					rear_suspension.origin_cell.z
					- front_suspension.origin_cell.z
				)
			)
			* GridMetric.CELL_SIZE_M
		)
	world.get_locomotion_controller(assembly_id).set_drive_command(1.0)
	IndustryElectricBudget.apply_tick(world, 1.0)
	var powered_wheels := 0
	var dynamic_demand_w := 0.0
	for key: String in ["fl", "fr", "rl", "rr"]:
		var pair_variant: Variant = module_ids.get(key, {})
		if not pair_variant is Dictionary:
			continue
		var wheel_id := int((pair_variant as Dictionary).get("wheel", 0))
		if wheel_id <= 0:
			continue
		var runtime := world.get_industry_element_runtime(wheel_id)
		if runtime != null and runtime.powered:
			powered_wheels += 1
		if runtime != null:
			dynamic_demand_w += runtime.dynamic_power_w
	var battery_id := int(module_ids.get("battery", 0))
	if battery_id > 0:
		world.ensure_industry_element_runtime(battery_id).machine_enabled = false
	IndustryElectricBudget.apply_tick(world, 1.0)
	var unpowered_wheels := 0
	for key: String in ["fl", "fr", "rl", "rr"]:
		var pair: Dictionary = module_ids.get(key, {})
		var wheel_id := int(pair.get("wheel", 0))
		var runtime := world.get_industry_element_runtime(wheel_id)
		if runtime != null and not runtime.powered:
			unpowered_wheels += 1
	session.free()
	if not ok:
		return _fail("demo rover spawn failed: %s" % result.get("error", ""))
	if not locomotive:
		return _fail("demo rover should be locomotive")
	if not activated:
		return _fail("demo rover should activate for drive/power checks")
	# Spawn leaves the rover parked (!activated) so construction can continue.
	if not is_equal_approx(wheelbase_m, 2.5):
		return _fail(
			"demo rover wheelbase should be 2.5 m, got %.3f" % wheelbase_m
		)
	if powered_wheels != 4:
		return _fail(
			"demo rover should power all 4 wheels, got %d" % powered_wheels
		)
	if not is_equal_approx(dynamic_demand_w, 1200.0):
		return _fail(
			"drive demand should be 1200 W, got %.1f" % dynamic_demand_w
		)
	if unpowered_wheels != 4:
		return _fail(
			"power loss should disable all wheels, got %d" % unpowered_wheels
		)
	return true


func _test_demo_rover_wheel_sockets_point_down() -> bool:
	var session := _boot_demo_session()
	var world := session.world
	var projection := session.projection
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


func _test_incremental_build_releases_on_activation() -> bool:
	var world := _boot_world()
	var projection := SimulationPhysicsProjection.new()
	add_child(projection)
	projection.bind_world(world)
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		projection.queue_free()
		world.free()
		return _fail("incremental locomotive fixture failed")
	var assembly_id := int(built["assembly_id"])
	var anchored_body := projection.get_physics_body(assembly_id)
	if not anchored_body is StaticBody3D:
		projection.queue_free()
		world.free()
		return _fail("wheel installation released unfinished chassis")
	var motion := world.get_assembly_raw(assembly_id).motion.duplicate_state()
	var before_y := motion.transform.origin.y
	world.get_locomotion_controller(assembly_id).activate()
	projection.project_assembly_now(assembly_id, motion)
	var released_body := projection.get_physics_body(assembly_id)
	if not released_body is RigidBody3D:
		projection.queue_free()
		world.free()
		return _fail("activated locomotive did not become dynamic")
	var clearance := WheelSimulationService.activation_clearance_m(
		world,
		assembly_id
	)
	var lift := released_body.global_position.y - before_y
	projection.queue_free()
	world.free()
	if absf(lift - clearance) > 0.001:
		return _fail(
			"release lift %.3f differs from wheel envelope %.3f"
			% [lift, clearance]
		)
	return true


func _test_custom_com_point_velocity() -> bool:
	var body := RigidBody3D.new()
	add_child(body)
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = Vector3(0.75, 0.5, -0.25)
	body.global_transform = Transform3D(
		Basis.IDENTITY.rotated(Vector3.UP, 0.35),
		Vector3(3.0, 2.0, -4.0)
	)
	body.linear_velocity = Vector3(1.5, -0.25, 0.75)
	body.angular_velocity = Vector3(0.0, 2.0, 0.0)
	var center_world := body.to_global(body.center_of_mass)
	var center_velocity := WheelProjectionUtil.velocity_at_world_point(
		body,
		center_world
	)
	if not center_velocity.is_equal_approx(body.linear_velocity):
		body.queue_free()
		return _fail("point velocity did not use custom COM")
	var point := center_world + Vector3(0.0, 0.0, 2.0)
	var expected := (
		body.linear_velocity
		+ body.angular_velocity.cross(point - center_world)
	)
	var actual := WheelProjectionUtil.velocity_at_world_point(body, point)
	body.queue_free()
	if not actual.is_equal_approx(expected):
		return _fail("point velocity angular term is incorrect")
	return true


func _test_ten_wheel_runtime_snapshots() -> bool:
	var world := _boot_world()
	var built := _build_multi_axle_rover(world, 5)
	if not bool(built.get("ok", false)):
		world.free()
		return _fail(
			"10-wheel fixture failed: %s" % built.get("error", "unknown")
		)
	var assembly_id := int(built["assembly_id"])
	var pairs := WheelSimulationService.discover_pairs(world, assembly_id)
	if pairs.size() != 10:
		world.free()
		return _fail("expected 10 wheel pairs, got %d" % pairs.size())
	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_drive_command(1.0)
	WheelSimulationService.sync_power_demand(world)
	var total_dynamic_demand_w := 0.0
	for pair: Dictionary in pairs:
		total_dynamic_demand_w += (
			world.ensure_industry_element_runtime(
				int(pair.get("wheel_element_id", 0))
			).dynamic_power_w
		)
	if not is_equal_approx(total_dynamic_demand_w, 3000.0):
		world.free()
		return _fail(
			"10 wheels should request 3000 W, got %.1f"
			% total_dynamic_demand_w
		)
	locomotion.set_drive_command(0.0)
	var body := RigidBody3D.new()
	body.freeze = true
	body.global_position = Vector3(0.0, 1.0, 0.0)
	add_child(body)
	for pair: Dictionary in pairs:
		var wheel_id := int(pair.get("wheel_element_id", 0))
		var power := world.ensure_industry_element_runtime(wheel_id)
		power.machine_enabled = true
		power.powered = true
	var resolver := func(_element_id: int) -> RigidBody3D:
		return body
	WheelSimulationService.tick_assembly(
		world,
		assembly_id,
		1.0 / 60.0,
		resolver,
		[body.get_rid()]
	)
	for pair: Dictionary in pairs:
		var runtime := world.get_wheel_runtime(
			int(pair.get("wheel_element_id", 0))
		)
		if runtime.is_empty():
			body.queue_free()
			world.free()
			return _fail("10-wheel tick omitted a runtime snapshot")
		for key: String in [
			"wheel_speed",
			"compression_m",
			"normal_force_n",
		]:
			if not is_finite(float(runtime.get(key, NAN))):
				body.queue_free()
				world.free()
				return _fail("10-wheel snapshot contains non-finite %s" % key)
		var center: Vector3 = runtime.get(
			"wheel_center_body_local",
			Vector3(INF, INF, INF)
		)
		if not center.is_finite():
			body.queue_free()
			world.free()
			return _fail("10-wheel snapshot contains invalid wheel center")
	body.queue_free()
	world.free()
	return true


func _test_demo_rover_drive_and_steer() -> bool:
	var session_scene: PackedScene = load(
		"res://scenes/simulation_session.tscn"
	)
	var session := session_scene.instantiate() as SimulationSession
	add_child(session)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		session.world.get_archetype_registry().register(archetype)
	var result := ROVER_DEMO_SPAWN.spawn_on_terrain(
		session,
		Vector3.ZERO
	)
	if not bool(result.get("ok", false)):
		session.queue_free()
		return _fail(
			"physics demo spawn failed: %s" % result.get("error", "unknown")
		)
	var assembly_id := int(result["assembly_id"])
	session.world.get_locomotion_controller(assembly_id).activate()
	ROVER_DEMO_SPAWN._wake_locomotive_body(session, assembly_id)
	var body := session.projection.get_physics_body(assembly_id) as RigidBody3D
	if body == null:
		session.queue_free()
		return _fail("physics demo body missing")
	for _step: int in range(120):
		await get_tree().physics_frame
	var grounded := 0
	for pair: Dictionary in WheelSimulationService.discover_pairs(
		session.world,
		assembly_id
	):
		var runtime := session.world.get_wheel_runtime(
			int(pair.get("wheel_element_id", 0))
		)
		if bool(runtime.get("grounded", false)):
			grounded += 1
	if grounded != 4:
		session.queue_free()
		return _fail("demo rover should settle on 4 wheels, got %d" % grounded)
	var locomotion := session.world.get_locomotion_controller(assembly_id)
	var drive_start := body.global_position
	locomotion.set_drive_command(1.0)
	for _step: int in range(180):
		await get_tree().physics_frame
	var drive_delta := body.global_position - drive_start
	drive_delta.y = 0.0
	if drive_delta.length() < 0.5:
		session.queue_free()
		return _fail(
			"demo rover drove only %.3f m" % drive_delta.length()
		)
	var heading_before := -body.global_transform.basis.z.normalized()
	locomotion.set_drive_command(0.7)
	locomotion.set_steering_command(1.0)
	for _step: int in range(180):
		await get_tree().physics_frame
	var heading_after := -body.global_transform.basis.z.normalized()
	var heading_change := heading_before.angle_to(heading_after)
	var module_ids: Dictionary = result.get("element_ids", {})
	var front_steering := 0.0
	var rear_steering := 0.0
	for key: String in ["fl", "fr"]:
		var pair: Dictionary = module_ids.get(key, {})
		front_steering = maxf(
			front_steering,
			absf(
				float(
					session.world.get_wheel_runtime(
						int(pair.get("wheel", 0))
					).get("steering_angle_rad", 0.0)
				)
			)
		)
	for key: String in ["rl", "rr"]:
		var pair: Dictionary = module_ids.get(key, {})
		rear_steering = maxf(
			rear_steering,
			absf(
				float(
					session.world.get_wheel_runtime(
						int(pair.get("wheel", 0))
					).get("steering_angle_rad", 0.0)
				)
			)
		)
	locomotion.set_drive_command(0.0)
	locomotion.set_steering_command(0.0)
	if heading_change < 0.05:
		session.queue_free()
		return _fail(
			"demo rover heading changed only %.4f rad" % heading_change
		)
	if front_steering < 0.1 or rear_steering > 0.001:
		session.queue_free()
		return _fail(
			"steering ownership invalid front=%.3f rear=%.3f"
			% [front_steering, rear_steering]
		)
	if (
		not body.global_position.is_finite()
		or not body.linear_velocity.is_finite()
		or not body.angular_velocity.is_finite()
	):
		session.queue_free()
		return _fail("demo rover physics became non-finite")
	session.queue_free()
	ProjectedAssemblyBody.impact_service = null
	await get_tree().process_frame
	return true


func _build_multi_axle_rover(
	world: SimulationWorld,
	axle_count: int
) -> Dictionary:
	if world == null or axle_count <= 0:
		return {"ok": false, "error": "invalid_axle_count"}
	var anchor := PlaceElementCommand.new()
	anchor.assembly_id = 0
	anchor.archetype = ROVER_FRAME
	anchor.origin_cell = Vector3i.ZERO
	anchor.orientation_index = 0
	anchor.new_assembly_grid_frame = GridTransform.identity()
	anchor.initial_motion = AssemblyMotionState.from_grid_frame(
		GridTransform.identity()
	)
	anchor.store_id = "player"
	var anchor_result := world.apply_structural_command_now(anchor)
	if not anchor_result.is_ok():
		return {"ok": false, "error": "anchor"}
	var assembly_id := int(anchor_result.data["assembly_id"])
	var revision := int(anchor_result.data["topology_revision"])
	for z: int in range(axle_count):
		for x: int in range(3):
			if x == 0 and z == 0:
				continue
			var frame := _place(
				world,
				assembly_id,
				revision,
				ROVER_FRAME,
				Vector3i(x, 0, z)
			)
			if not frame.is_ok():
				return {
					"ok": false,
					"error": "frame_%d_%d:%s" % [x, z, frame.reason],
				}
			revision = int(frame.data["topology_revision"])
	for z: int in range(axle_count):
		for side: int in [-1, 1]:
			var x := -1 if side < 0 else 3
			var face := Vector3i.RIGHT if side < 0 else Vector3i.LEFT
			var suspension := _place(
				world,
				assembly_id,
				revision,
				WHEEL_SUSPENSION,
				Vector3i(x, 0, z),
				_orientation_with_local_face(Vector3i.RIGHT, face)
			)
			if not suspension.is_ok():
				return {
					"ok": false,
					"error": "suspension_%d_%d:%s" % [x, z, suspension.reason],
				}
			revision = int(suspension.data["topology_revision"])
			var wheel := _place(
				world,
				assembly_id,
				revision,
				DRIVE_WHEEL,
				Vector3i(x, -1, z)
			)
			if not wheel.is_ok():
				return {
					"ok": false,
					"error": "wheel_%d_%d:%s" % [x, z, wheel.reason],
				}
			revision = int(wheel.data["topology_revision"])
	var assembly := world.get_assembly_raw(assembly_id)
	for element_id: int in assembly.element_ids:
		_weld(world, element_id)
	return {"ok": true, "assembly_id": assembly_id}


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
