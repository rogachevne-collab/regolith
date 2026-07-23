extends Node
## Headless-верификация ActionBar (CONTROL-ACTIONS-V0 §Headless verification).
## Только ядро: side-table/команда/snapshot. Резолв глагола (piston.extend →
## set_actuator_target и т.п.) живёт в hud_control_terminal.gd — presentation,
## проверяется в игре (AGENTS.md R2), не здесь.

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "CONTROL-ACTIONS-V0")
	var tests: Array[Callable] = [
		_test_bind_and_clear_slot,
		_test_bind_rejects_non_control_seat_host,
		_test_bind_rejects_out_of_range_slot,
		_test_action_bar_snapshot_roundtrip,
		_test_snapshot_rejects_action_bar_on_non_control_seat,
		_test_dismantle_host_clears_action_bar,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("CONTROL-ACTIONS-V0: PASS")
	get_tree().quit(0)


func _boot_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	world.ensure_resource_store(PlayerIdentity.store_id("player"))
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_metal", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "girder", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "mechanism", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "conduit", 500.0)
	world.set_resource_amount(PlayerIdentity.store_id("player"), "plate_basalt", 500.0)
	world.get_archetype_registry().register(Slice01Archetypes.foundation())
	world.get_archetype_registry().register(Slice01Archetypes.frame())
	world.get_archetype_registry().register(Slice01Archetypes.control_terminal())
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
	origin_cell: Vector3i
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = revision
	place.archetype = archetype
	place.origin_cell = origin_cell
	place.store_id = PlayerIdentity.store_id("player")
	return world.apply_structural_command_now(place)


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


## Фундамент + control_terminal (роль ControlSeat), достроенный до operational —
## общий фикстур для всех тестов ниже.
func _build_terminal_host(world: SimulationWorld) -> Dictionary:
	var foundation := _spawn_foundation(world)
	if foundation.is_empty():
		return {"error": "foundation"}
	var assembly_id := int(foundation["assembly_id"])
	var revision := int(foundation["topology_revision"])
	var terminal := _place(
		world,
		assembly_id,
		revision,
		Slice01Archetypes.control_terminal(),
		Vector3i(4, 0, 0)
	)
	if not terminal.is_ok():
		return {"error": "terminal: %s" % terminal.reason}
	var host_id := int(terminal.data["element_id"])
	var foundation_id := int(
		(foundation["local_to_element_id"] as Dictionary)["element_0"]
	)
	_weld(world, foundation_id)
	_weld(world, host_id)
	var host := world.get_element(host_id)
	if host == null or not host.is_operational():
		return {"error": "terminal not operational after weld"}
	return {
		"assembly_id": assembly_id,
		"host_id": host_id,
		"foundation_id": foundation_id,
	}


func _single_blueprint(archetype: ElementArchetype) -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"test_control_actions_fixture",
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


func _bind(
	world: SimulationWorld,
	host_id: int,
	page: int,
	index: int,
	payload: Dictionary
) -> Dictionary:
	var command := ConfigureActionSlotCommand.new()
	command.host_element_id = host_id
	command.page = page
	command.index = index
	command.payload = payload
	return world.apply_configure_action_slot(command)


func _test_bind_and_clear_slot() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	var host := world.get_element(host_id)
	var revision_before := host.state_revision
	var payload := {"action_id": "piston.extend", "element_id": 42, "joint_id": 7}
	var bind_result := _bind(world, host_id, 2, 5, payload)
	if StringName(bind_result.get("reason", &"")) != &"ok":
		world.free()
		return _fail("bind failed: %s" % bind_result.get("reason"))
	if host.state_revision <= revision_before:
		world.free()
		return _fail("bind did not bump host state_revision")
	var state := world.ensure_action_bar_state(host_id)
	var bound_slot := state.get_slot(2, 5)
	if bound_slot != payload:
		world.free()
		return _fail("bound slot payload mismatch: %s" % bound_slot)
	# Пустой payload = снять клавишу (тот же приём, что у SetElementNameCommand).
	var clear_result := _bind(world, host_id, 2, 5, {})
	if StringName(clear_result.get("reason", &"")) != &"ok":
		world.free()
		return _fail("clear failed: %s" % clear_result.get("reason"))
	if not state.get_slot(2, 5).is_empty():
		world.free()
		return _fail("slot not cleared")
	world.free()
	return true


func _test_bind_rejects_non_control_seat_host() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	# foundation несёт Frame, не ControlSeat — гейт по роли обязан отказать.
	var result := _bind(
		world,
		int(built["foundation_id"]),
		0,
		0,
		{"action_id": "machine.toggle"}
	)
	var rows := world.list_action_bar_rows()
	world.free()
	if StringName(result.get("reason", &"")) == &"ok":
		return _fail("bind on non-ControlSeat host should be rejected")
	for row: Dictionary in rows:
		if int(row.get("element_id", 0)) == int(built["foundation_id"]):
			return _fail("rejected bind still created a side-table entry")
	return true


func _test_bind_rejects_out_of_range_slot() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	var bad_page := _bind(world, host_id, 9, 0, {"action_id": "x"})
	var bad_index := _bind(world, host_id, 0, -1, {"action_id": "x"})
	world.free()
	if StringName(bad_page.get("reason", &"")) == &"ok":
		return _fail("page 9 (out of [0,9)) should be rejected")
	if StringName(bad_index.get("reason", &"")) == &"ok":
		return _fail("index -1 should be rejected")
	return true


func _test_action_bar_snapshot_roundtrip() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	var payload_a := {"action_id": "actuator.stop", "element_id": 10, "joint_id": 3}
	var payload_b := {
		"action_id": "param.increase", "param_id": "wheel.brake_torque",
		"element_id": 11, "delta": 100.0,
	}
	if StringName(_bind(world, host_id, 0, 0, payload_a).get("reason", &"")) != &"ok":
		world.free()
		return _fail("bind a failed")
	if StringName(_bind(world, host_id, 8, 8, payload_b).get("reason", &"")) != &"ok":
		world.free()
		return _fail("bind b failed")
	var snapshot := world.capture_snapshot()
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(snapshot)
	if restored == null:
		world.free()
		return _fail(
			"action bar snapshot restore failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	var restored_state := restored.ensure_action_bar_state(host_id)
	var ok := (
		restored_state.get_slot(0, 0) == payload_a
		and restored_state.get_slot(8, 8) == payload_b
		and restored_state.get_slot(1, 1).is_empty()
	)
	world.free()
	restored.free()
	if not ok:
		return _fail("action bar contents did not survive snapshot roundtrip")
	return true


## Гейт по роли — не только на команде (R2 «resolve ActionSlot valid/invalid»),
## но и на границе снапшота: рукописный снапшот, ссылающийся на non-ControlSeat
## хост, должен быть отвергнут целиком, как и колёсный/подвесочный ряд.
func _test_snapshot_rejects_action_bar_on_non_control_seat() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var snapshot := world.capture_snapshot()
	snapshot["action_bars"] = [
		{
			"element_id": int(built["foundation_id"]),
			"state": {"pages": []},
		}
	]
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(snapshot)
	world.free()
	if restored != null:
		restored.free()
		return _fail("snapshot with action_bar on non-ControlSeat host should be rejected")
	return true


func _test_dismantle_host_clears_action_bar() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	if StringName(
		_bind(world, host_id, 0, 0, {"action_id": "machine.toggle"}).get("reason", &"")
	) != &"ok":
		world.free()
		return _fail("bind failed")
	var dismantle := DismantleElementCommand.new()
	dismantle.element_id = host_id
	dismantle.expected_assembly_revision = int(
		world.get_assembly_raw(int(built["assembly_id"])).topology_revision
	)
	dismantle.store_id = PlayerIdentity.store_id("player")
	var result := world.apply_structural_command_now(dismantle)
	if not result.is_ok():
		world.free()
		return _fail("dismantle failed: %s" % result.reason)
	var rows := world.list_action_bar_rows()
	world.free()
	for row: Dictionary in rows:
		if int(row.get("element_id", 0)) == host_id:
			return _fail("action bar survived host dismantle")
	return true


func _fail(message: String) -> bool:
	push_error("test_control_actions: %s" % message)
	get_tree().quit(1)
	return false
