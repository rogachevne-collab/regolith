extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
const ROVER_FRAME := preload(
	"res://resources/archetypes/slice01/rover_frame.tres"
)

## Пара «подвеска + колесо» — та, что ставит игра: сеточных деталей без точных
## точек крепления больше нет, и зашивать id испечённой визардом детали в тест
## нельзя.
static func _pair_intent() -> RoverIntent:
	return RoverIntent.defaults()


static func _suspension_archetype() -> ElementArchetype:
	return _pair_intent().suspension_archetype()


static func _wheel_archetype() -> ElementArchetype:
	return _pair_intent().wheel_archetype()


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "SIMULATION-WHEEL-V1")
	var tests: Array[Callable] = [
		_test_socket_tag_blocks_frame_to_wheel_socket,
		_test_wheel_placement_requires_suspension,
		_test_wheel_placement_rejects_occupied_socket,
		_test_wheel_pair_discovery,
		_test_locomotive_requires_complete_pair,
		_test_configure_wheel_steerable,
		_test_configure_wheel_grip_scale,
		_test_configure_suspension_rejects_invalid_travel,
		_test_wheel_snapshot_roundtrip,
		_test_dismantle_wheel_breaks_locomotive,
		_test_demo_rover_spawn,
		_test_incremental_build_releases_on_activation,
		_test_wheel_frame_axes,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	if not await _test_ten_wheel_runtime_snapshots():
		return
	if not await _test_demo_rover_drive_and_steer():
		return
	print("SIMULATION-WHEEL-V1: PASS")
	get_tree().quit(0)


func _boot_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "sintered_basalt", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_alloy", 500.0)
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
	place.store_id = PlayerIdentity.store_id("player")
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


## Шасси + одна стойка без колеса. Клетки не зашиваем: у точной детали гнездо
## смотрит вбок, позу считает тот же планировщик, что и композер.
func _build_suspension_only(world: SimulationWorld) -> Dictionary:
	var helper := AssemblyBuildHelper.new(world, PlayerIdentity.store_id("player"))
	helper.ensure_materials(800.0)
	if not helper.spawn_anchor(ROVER_FRAME, GridTransform.identity()):
		return {"error": "anchor: %s" % helper.last_error}
	for cell: Vector3i in [Vector3i(1, 0, 0), Vector3i(2, 0, 0)]:
		if not helper.place(ROVER_FRAME, cell):
			return {"error": "chassis: %s" % helper.last_error}
	# Крепимся к БОРТОВОЙ грани клетки шасси наружу — как это делает композер.
	var plan := RoverComposer._plan_wheel_pair(
		_suspension_archetype(),
		_wheel_archetype(),
		Vector3i(0, 0, 0),
		Vector3i.LEFT
	)
	if plan.is_empty():
		return {"error": "no wheel pair pose"}
	if not helper.place(
		_suspension_archetype(),
		plan["suspension_origin"],
		int(plan["suspension_orientation"]),
		"suspension"
	):
		return {"error": "suspension: %s" % helper.last_error}
	helper.weld_all()
	var assembly := world.get_assembly_raw(helper.assembly_id)
	return {
		"world": world,
		"assembly_id": helper.assembly_id,
		"suspension_id": int(helper.element_ids.get("suspension", 0)),
		"plan": plan,
		"revision": assembly.topology_revision,
	}


func _build_complete_pair(world: SimulationWorld) -> Dictionary:
	var partial := _build_suspension_only(world)
	if partial.has("error"):
		return partial
	var plan: Dictionary = partial["plan"]
	var place := PlaceElementCommand.new()
	place.assembly_id = int(partial["assembly_id"])
	place.expected_assembly_revision = int(partial["revision"])
	place.archetype = _wheel_archetype()
	place.origin_cell = plan["wheel_origin"]
	place.orientation_index = int(plan["wheel_orientation"])
	place.store_id = PlayerIdentity.store_id("player")
	var wheel := world.apply_structural_command_now(place)
	if not wheel.is_ok():
		return {"error": "wheel: %s" % wheel.reason}
	_weld(world, int(wheel.data["element_id"]))
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
	var socket_plan: Dictionary = partial["plan"]
	var deny := _place(
		world,
		int(partial["assembly_id"]),
		int(partial["revision"]),
		ROVER_FRAME,
		socket_plan["wheel_origin"],
		int(socket_plan["wheel_orientation"])
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
		_wheel_archetype(),
		Vector3i(12, 0, 0)
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
	command.archetype = _wheel_archetype()
	var occupied_plan: Dictionary = built["plan"]
	command.origin_cell = occupied_plan["wheel_origin"]
	command.orientation_index = int(occupied_plan["wheel_orientation"])
	var preview := SimulationElement.frame(
		-1,
		command.assembly_id,
		_wheel_archetype(),
		command.origin_cell,
		command.orientation_index,
		{"plate_metal": 1.0}
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


## Ползунок «Сцепление» ужимает авторское сцепление и не даёт выдумать его
## сверх резины: 1.0 — потолок детали, больше отклоняется.
func _test_configure_wheel_grip_scale() -> bool:
	var world := _boot_world()
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		world.free()
		return _fail(
			"complete pair setup failed: %s" % built.get("error", "unknown")
		)
	var wheel_id := int(built["wheel_id"])
	var command := ConfigureWheelCommand.new()
	command.wheel_element_id = wheel_id
	command.grip_scale = 0.4
	var result := world.apply_configure_wheel(command)
	if StringName(result.get("reason", &"")) != &"ok":
		world.free()
		return _fail("grip scale rejected: %s" % result.get("reason"))
	var state := world.ensure_wheel_instance_state(wheel_id)
	if not is_equal_approx(state.grip_scale, 0.4):
		world.free()
		return _fail("grip scale not persisted: %f" % state.grip_scale)
	var over := ConfigureWheelCommand.new()
	over.wheel_element_id = wheel_id
	over.grip_scale = 1.5
	var denied := world.apply_configure_wheel(over)
	var denied_reason := StringName(denied.get("reason", &""))
	var still := world.ensure_wheel_instance_state(wheel_id).grip_scale
	world.free()
	var definition := _wheel_archetype().wheel_definition
	if denied_reason == &"ok":
		return _fail("grip scale above authored ceiling must be rejected")
	if not is_equal_approx(still, 0.4):
		return _fail("rejected grip scale must not change state")
	# Сцепление доезжает до физики: трение шины = авторское × ползунок,
	# потолок — авторское значение (WHEEL-BODY-V1: трение материала тела).
	if not is_equal_approx(
		WheelBodyProjectionUtil.tire_friction(definition, 0.4),
		definition.longitudinal_grip * 0.4
	):
		return _fail("tire friction not scaled by grip slider")
	if not is_equal_approx(
		WheelBodyProjectionUtil.tire_friction(definition, 5.0),
		definition.longitudinal_grip
	):
		return _fail("tire friction must cap at the authored grip")
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
	# Ход берём из самой детали: у испечённой визардом подвески свой диапазон,
	# и зашитые 0.8 м в него не попадают.
	var suspension_definition: SuspensionDefinition = (
		_suspension_archetype().suspension_definition
	)
	var target_travel := 0.5 * (
		suspension_definition.min_travel_m + suspension_definition.max_travel_m
	)
	var suspension_command := ConfigureSuspensionCommand.new()
	suspension_command.suspension_element_id = int(built["suspension_id"])
	suspension_command.travel_m = target_travel
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
		and is_equal_approx(suspension_state.travel_m, target_travel)
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
	dismantle.store_id = PlayerIdentity.store_id("player")
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok():
		world.free()
		return _fail("wheel dismantle failed: %s" % result.reason)
	if WheelSimulationService.is_locomotive_assembly(world, assembly_id):
		world.free()
		return _fail("assembly should stop being locomotive after wheel removed")
	world.free()
	return true


## Ровер, собранный тем же путём, что в игре: питание раздаётся всем колёсам,
## а его пропажа обесточивает все. Пары ищем через discover_pairs, а не по
## ключам раскладки: колёс может быть сколько угодно.
func _test_demo_rover_spawn() -> bool:
	var session := _boot_demo_session()
	var world := session.world
	var result: Dictionary = RoverComposer.spawn_on_terrain(
		session,
		Vector3(8.0, 0.0, 0.0)
	)
	if not bool(result.get("ok", false)):
		var error := str(result.get("error", ""))
		var failures: Variant = result.get("failures", [])
		session.free()
		return _fail("rover spawn failed: %s %s" % [error, failures])
	var assembly_id := int(result["assembly_id"])
	if not WheelSimulationService.is_locomotive_assembly(world, assembly_id):
		session.free()
		return _fail("composed rover should be locomotive")
	var locomotion := world.get_locomotion_controller(assembly_id)
	if not locomotion.is_activated():
		locomotion.activate()
	var wheel_ids: Array[int] = []
	for pair: Dictionary in WheelSimulationService.discover_pairs(
		world,
		assembly_id
	):
		if WheelSimulationService.is_complete_pair(pair):
			wheel_ids.append(int(pair.get("wheel_element_id", 0)))
	if wheel_ids.size() != 4:
		session.free()
		return _fail("composed rover has %d wheel pairs" % wheel_ids.size())

	locomotion.set_drive_command(1.0)
	IndustryElectricBudget.apply_tick(world, 1.0)
	var powered_wheels := 0
	var demand_w := 0.0
	var expected_demand_w := 0.0
	for wheel_id: int in wheel_ids:
		var runtime := world.get_industry_element_runtime(wheel_id)
		if runtime != null and runtime.powered:
			powered_wheels += 1
		if runtime != null:
			demand_w += runtime.dynamic_power_w
		expected_demand_w += (
			world.get_element(wheel_id).get_archetype()
				.wheel_definition.power_draw_w
		)

	# Обесточиваем всё, что не колесо: где именно стоит батарея, тест знать не
	# обязан — важно, что без питания колёса встают.
	for element: SimulationElement in world.list_elements():
		if element.assembly_id != assembly_id or wheel_ids.has(element.element_id):
			continue
		world.ensure_industry_element_runtime(
			element.element_id
		).machine_enabled = false
	IndustryElectricBudget.apply_tick(world, 1.0)
	var unpowered_wheels := 0
	for wheel_id: int in wheel_ids:
		var runtime := world.get_industry_element_runtime(wheel_id)
		if runtime != null and not runtime.powered:
			unpowered_wheels += 1
	session.free()

	if powered_wheels != wheel_ids.size():
		return _fail(
			"rover should power all %d wheels, got %d"
			% [wheel_ids.size(), powered_wheels]
		)
	if not is_equal_approx(demand_w, expected_demand_w):
		return _fail(
			"drive demand should be %.1f W, got %.1f" % [expected_demand_w, demand_w]
		)
	if unpowered_wheels != wheel_ids.size():
		return _fail(
			"power loss should disable all wheels, got %d" % unpowered_wheels
		)
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


## Оси колёсного кадра (WHEEL-BODY-V1): хаб — СВОЯ ось колеса (центр шины, он
## же центр меша), а не точка стыковки с подвеской; вверх против направления
## socket; тройка ортогональна и правая.
##
## Хаб в точке стыковки — ровно тот баг, из-за которого шина обходила стойку по
## кругу: у сеточной детали эта точка на полклетки выше центра колеса.
func _test_wheel_frame_axes() -> bool:
	var world := _boot_world()
	var built := _build_complete_pair(world)
	if built.is_empty() or built.has("error"):
		world.free()
		return _fail("wheel frame fixture failed")
	var suspension := world.get_element(int(built["suspension_id"]))
	var wheel := world.get_element(int(built["wheel_id"]))
	var frame := WheelBodyProjectionUtil.wheel_frame_assembly_local(wheel)
	var socket := WheelBodyProjectionUtil.mount_pad_anchor_assembly_local(
		suspension,
		"wheel_socket"
	)
	var expected_hub := WheelBodyProjectionUtil.axle_point_assembly_local(wheel)
	world.free()
	if frame.is_empty() or socket.is_empty():
		return _fail("wheel frame did not resolve")
	var up: Vector3 = frame["up"]
	var axle: Vector3 = frame["axle"]
	var forward: Vector3 = frame["forward"]
	if not Vector3(frame["hub"]).is_equal_approx(expected_hub):
		return _fail("hub must sit on the wheel's own axle point")
	var socket_gap := (Vector3(frame["hub"]) - Vector3(socket["origin"])).length()
	if socket_gap < GridMetric.HALF_CELL_SIZE_M - 0.001:
		return _fail(
			"grid wheel axle must sit half a cell below the socket, got %.3f"
			% socket_gap
		)
	# Ход подвески — по «вверх» самого шасси, НЕ по грани гнезда: у точной
	# подвески гнездо смотрит вбок, вдоль оси колеса, и привязка к нему кладёт
	# пружину набок, а шину ставит бочкой на попа.
	if not up.is_equal_approx(Vector3.UP):
		return _fail("travel axis must be the chassis' own up, got %s" % str(up))
	if absf(axle.dot(Vector3.UP)) > 0.0001:
		return _fail("axle must be horizontal, got %s" % str(axle))
	if (
		absf(up.dot(axle)) > 0.0001
		or absf(up.dot(forward)) > 0.0001
		or absf(axle.dot(forward)) > 0.0001
	):
		return _fail("wheel frame must be orthogonal")
	if not axle.cross(up).is_equal_approx(-forward):
		return _fail("wheel frame must satisfy axle×up = -forward")
	return true


## 10 колёс на настоящей проекции: телеметрия пишется для каждого колеса и
## конечна; потребление энергии как раньше.
func _test_ten_wheel_runtime_snapshots() -> bool:
	var world := _boot_world()
	var projection := SimulationPhysicsProjection.new()
	add_child(projection)
	projection.bind_world(world)
	var built := _build_multi_axle_rover(world, 5)
	if not bool(built.get("ok", false)):
		projection.queue_free()
		world.free()
		return _fail(
			"10-wheel fixture failed: %s" % built.get("error", "unknown")
		)
	var assembly_id := int(built["assembly_id"])
	var pairs := WheelSimulationService.discover_pairs(world, assembly_id)
	if pairs.size() != 10:
		projection.queue_free()
		world.free()
		return _fail("expected 10 wheel pairs, got %d" % pairs.size())
	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	# Compose alone can leave the projection stale; bind joints after activate
	# the same way the incremental-build test does.
	projection.project_assembly_now(
		assembly_id,
		world.get_assembly_raw(assembly_id).motion.duplicate_state()
	)
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
		projection.queue_free()
		world.free()
		return _fail(
			"10 wheels should request 3000 W, got %.1f"
			% total_dynamic_demand_w
		)
	locomotion.set_drive_command(0.0)
	for pair: Dictionary in pairs:
		var wheel_id := int(pair.get("wheel_element_id", 0))
		var power := world.ensure_industry_element_runtime(wheel_id)
		power.machine_enabled = true
		power.powered = true
	var constraint_count := projection.list_wheel_constraint_records(
		assembly_id
	).size()
	if constraint_count != pairs.size():
		var compiled := world.compile_body_groups(assembly_id)
		projection.queue_free()
		world.free()
		return _fail(
			"10-wheel rover got %d wheel constraints for %d pairs (compile %s/%s, wheel_specs %d)"
			% [
				constraint_count,
				pairs.size(),
				str(compiled.get("valid", false)),
				str(compiled.get("reason", "")),
				(compiled.get("wheel_specs", []) as Array).size(),
			]
		)
	for _step: int in range(10):
		await get_tree().physics_frame
	for pair: Dictionary in pairs:
		var runtime := world.get_wheel_runtime(
			int(pair.get("wheel_element_id", 0))
		)
		if runtime.is_empty():
			projection.queue_free()
			world.free()
			return _fail("10-wheel tick omitted a runtime snapshot")
		for key: String in [
			"wheel_speed",
			"compression_m",
			"normal_force_n",
		]:
			if not is_finite(float(runtime.get(key, NAN))):
				projection.queue_free()
				world.free()
				return _fail("10-wheel snapshot contains non-finite %s" % key)
		var center: Vector3 = runtime.get(
			"wheel_center_body_local",
			Vector3(INF, INF, INF)
		)
		if not center.is_finite():
			projection.queue_free()
			world.free()
			return _fail("10-wheel snapshot contains invalid wheel center")
	projection.queue_free()
	world.free()
	await get_tree().process_frame
	return true


func _test_demo_rover_drive_and_steer() -> bool:
	var session_scene: PackedScene = load(
		"res://scenes/simulation_session.tscn"
	)
	var session := session_scene.instantiate() as SimulationSession
	add_child(session)
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		session.world.get_archetype_registry().register(archetype)
	var result := RoverComposer.spawn_on_terrain(
		session,
		Vector3.ZERO
	)
	if not bool(result.get("ok", false)):
		session.queue_free()
		return _fail(
			"physics demo spawn failed: %s" % result.get("error", "unknown")
		)
	var assembly_id := int(result["assembly_id"])
	var locomotion := session.world.get_locomotion_controller(assembly_id)
	locomotion.activate()
	locomotion.set_parking_brake(false)
	session.projection.wake_assembly_bodies(assembly_id)
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
	for pair: Dictionary in WheelSimulationService.discover_pairs(
		session.world,
		assembly_id
	):
		var probe_id := int(pair.get("wheel_element_id", 0))
		var rt := session.world.get_wheel_runtime(probe_id)
		if not rt.has("contact_world"):
			print("DEBUG wheel %d: NOT GROUNDED %s" % [probe_id, rt.get("status", "?")])
			continue
		var centre_world: Vector3 = body.global_transform * Vector3(
			rt.get("wheel_center_body_local", Vector3.ZERO)
		)
		print("DEBUG wheel %d: gap %.3f m (radius 0.4), compression %.3f, grounded %s" % [
			probe_id,
			centre_world.distance_to(Vector3(rt["contact_world"])),
			float(rt.get("compression_m", -1.0)),
			rt.get("grounded", false),
		])
	var drive_start := body.global_position
	locomotion.set_drive_command(1.0)
	for _step: int in range(180):
		await get_tree().physics_frame
	var drive_delta := body.global_position - drive_start
	drive_delta.y = 0.0
	print("DEMO drive distance: %.3f m in 180 frames" % drive_delta.length())
	# Порог приёмки WHEEL-BODY-V1: ≥ 3.0 м (raycast-база была 3.241 м).
	if drive_delta.length() < 3.0:
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
	# Composer keys: pair_L_0 / pair_R_0 (front), pair_L_1 / pair_R_1 (next axle).
	for key: String in ["pair_L_0", "pair_R_0"]:
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
	for key: String in ["pair_L_1", "pair_R_1"]:
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
	# Задние — замок [0,0], но замер идёт с живого тела: под боковой нагрузкой
	# жёсткий угловой стоп Jolt даёт ~0.02 рад люфта (кинематического нуля
	# больше нет — WHEEL-BODY-V1). Порог отделяет люфт от настоящей рулёжки.
	if front_steering < 0.1 or rear_steering > 0.05:
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


## Многоосный ровер строит композер: он умеет и точные детали, и «колбасу».
func _build_multi_axle_rover(
	world: SimulationWorld,
	axle_count: int
) -> Dictionary:
	var intent := RoverIntent.defaults()
	intent.wheel_count = axle_count * 2
	if not intent.unsupported_reason().is_empty():
		return {"ok": false, "error": intent.unsupported_reason()}
	var composed := RoverComposer.compose(world, intent)
	if not bool(composed.get("ok", false)):
		return {
			"ok": false,
			"error": "%s %s" % [
				composed.get("error", ""), composed.get("failures", []),
			],
		}
	return {"ok": true, "assembly_id": int(composed["assembly_id"])}


func _weld(world: SimulationWorld, element_id: int) -> void:
	var element := world.get_element(element_id)
	if element == null:
		return
	var weld := WeldElementCommand.new()
	weld.element_id = element_id
	weld.expected_state_revision = element.state_revision
	weld.max_material_amount = 100.0
	weld.store_id = PlayerIdentity.store_id("player")
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
