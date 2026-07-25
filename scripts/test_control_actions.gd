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
		_test_seat_control_defaults_and_mutation,
		_test_seat_control_rejects_non_control_seat,
		_test_seat_control_snapshot_roundtrip_and_orphan,
		_test_dismantle_host_clears_seat_control,
		_test_two_seats_independent_routing,
		_test_snapshot_v9_loads_without_seat_control_states,
		_test_host_hint_pin_prefers_pinned,
		_test_non_seat_hint_resolves_assembly_host,
		_test_interaction_card_seat_flags_and_toggle_invert,
		_test_seat_control_ref_is_stable,
		_test_oxygen_module_terminal_snapshot,
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


func _configure_seat(
	world: SimulationWorld,
	seat_id: int,
	wheels = null,
	thrusters = null,
	gyros = null
) -> Dictionary:
	var command := ConfigureSeatControlsCommand.new()
	command.seat_element_id = seat_id
	command.control_wheels = wheels
	command.control_thrusters = thrusters
	command.control_gyros = gyros
	return world.apply_configure_seat_controls(command)


func _test_seat_control_defaults_and_mutation() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	if world.has_seat_control_state(host_id):
		world.free()
		return _fail("peek/read must not create seat_control row")
	var peeked := world.peek_seat_control_state(host_id)
	if not (
		peeked.control_wheels
		and not peeked.control_thrusters
		and peeked.control_gyros
	):
		world.free()
		return _fail(
			"defaults should be wheels+gyros on, thrusters off: %s"
			% peeked.to_dict()
		)
	var host := world.get_element(host_id)
	var revision_before := host.state_revision
	var result := _configure_seat(world, host_id, false, true, true)
	if StringName(result.get("reason", &"")) != &"ok":
		world.free()
		return _fail("configure_seat_controls failed: %s" % result.get("reason"))
	if not world.has_seat_control_state(host_id):
		world.free()
		return _fail("mutation must create seat_control row")
	var state := world.ensure_seat_control_state(host_id)
	if state.control_wheels or not state.control_thrusters or not state.control_gyros:
		world.free()
		return _fail("partial mutation mismatch: %s" % state.to_dict())
	if host.state_revision <= revision_before:
		world.free()
		return _fail("configure_seat_controls did not bump state_revision")
	# Verb invert pattern: toggle wheels back on.
	var toggled := _configure_seat(world, host_id, not state.control_wheels, null, null)
	if not bool(toggled.get("control_wheels", false)):
		world.free()
		return _fail("toggle verb did not invert control_wheels")
	world.free()
	return true


func _test_seat_control_rejects_non_control_seat() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var result := _configure_seat(world, int(built["foundation_id"]), false, false, false)
	var rows := world.list_seat_control_rows()
	world.free()
	if StringName(result.get("reason", &"")) == &"ok":
		return _fail("configure_seat_controls on non-ControlSeat should fail")
	for row: Dictionary in rows:
		if int(row.get("element_id", 0)) == int(built["foundation_id"]):
			return _fail("rejected configure still created seat_control row")
	return true


func _test_seat_control_snapshot_roundtrip_and_orphan() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	if StringName(
		_configure_seat(world, host_id, true, false, true).get("reason", &"")
	) != &"ok":
		world.free()
		return _fail("configure failed")
	var snapshot := world.capture_snapshot()
	if int(snapshot.get("version", 0)) != SimulationSnapshot.VERSION:
		world.free()
		return _fail("snapshot version mismatch")
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(snapshot)
	if restored == null:
		world.free()
		return _fail(
			"seat_control snapshot restore failed: %s"
			% SimulationSnapshot.last_validate_error
		)
	var state := restored.peek_seat_control_state(host_id)
	if state.control_thrusters or not state.control_wheels or not state.control_gyros:
		world.free()
		restored.free()
		return _fail("seat_control did not survive roundtrip: %s" % state.to_dict())
	# Orphan / wrong role rejected.
	snapshot["seat_control_states"] = [
		{"element_id": int(built["foundation_id"]), "state": {"control_wheels": false}}
	]
	var bad: SimulationWorld = SimulationSnapshot.create_from_snapshot(snapshot)
	world.free()
	restored.free()
	if bad != null:
		bad.free()
		return _fail("seat_control on non-ControlSeat must be rejected")
	return true


func _test_dismantle_host_clears_seat_control() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	if StringName(
		_configure_seat(world, host_id, false, true, true).get("reason", &"")
	) != &"ok":
		world.free()
		return _fail("configure failed")
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
	var rows := world.list_seat_control_rows()
	world.free()
	for row: Dictionary in rows:
		if int(row.get("element_id", 0)) == host_id:
			return _fail("seat_control survived host dismantle")
	return true


func _test_two_seats_independent_routing() -> bool:
	## Two ControlSeat hosts (separate assemblies) — policy is per seat_id.
	var world := _boot_world()
	var built_a := _build_terminal_host(world)
	var built_b := _build_terminal_host(world)
	if built_a.has("error") or built_b.has("error"):
		world.free()
		return _fail(
			"hosts: %s / %s" % [built_a.get("error"), built_b.get("error")]
		)
	var seat_a := int(built_a["host_id"])
	var seat_b := int(built_b["host_id"])
	if StringName(
		_configure_seat(world, seat_a, true, false, true).get("reason", &"")
	) != &"ok":
		world.free()
		return _fail("configure a failed")
	if StringName(
		_configure_seat(world, seat_b, false, true, false).get("reason", &"")
	) != &"ok":
		world.free()
		return _fail("configure b failed")
	var pa := world.peek_seat_control_state(seat_a)
	var pb := world.peek_seat_control_state(seat_b)
	world.free()
	if pa.control_thrusters or not pa.control_wheels or not pa.control_gyros:
		return _fail("seat a policy corrupted")
	if pb.control_wheels or not pb.control_thrusters or pb.control_gyros:
		return _fail("seat b policy corrupted / not independent")
	return true


func _test_snapshot_v9_loads_without_seat_control_states() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	var snapshot := world.capture_snapshot()
	snapshot["version"] = 9
	snapshot.erase("seat_control_states")
	var restored: SimulationWorld = SimulationSnapshot.create_from_snapshot(
		snapshot
	)
	if restored == null:
		world.free()
		return _fail(
			"v9 without seat_control_states must load: %s"
			% SimulationSnapshot.last_validate_error
		)
	var policy := restored.get_seat_control_state_ref(host_id)
	var ok := (
		policy.control_wheels
		and not policy.control_thrusters
		and policy.control_gyros
		and not restored.has_seat_control_state(host_id)
	)
	world.free()
	restored.free()
	if not ok:
		return _fail(
			"v9 load must expose defaults without creating a row: %s"
			% policy.to_dict()
		)
	return true


func _test_oxygen_module_terminal_snapshot() -> bool:
	## OxygenModule is an ordinary listable machine with enable/power/liters.
	var world := _boot_world()
	world.get_archetype_registry().register(Slice01Archetypes.o2_module())
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var assembly_id := int(built["assembly_id"])
	var host_id := int(built["host_id"])
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		world.free()
		return _fail("assembly missing after host build")
	# Adjacent to control_terminal at (4,0,0) / foundation edge — not floating.
	var placed := _place(
		world,
		assembly_id,
		assembly.topology_revision,
		Slice01Archetypes.o2_module(),
		Vector3i(4, 0, 1)
	)
	if not placed.is_ok():
		world.free()
		return _fail("oxygen module place failed: %s" % placed.reason)
	var module_id := int(placed.data["element_id"])
	_weld(world, module_id)
	IndustryStoreService.ensure_element_keyed_store(
		world,
		world.get_element(module_id)
	)
	var runtime := world.ensure_industry_element_runtime(module_id)
	runtime.powered = true
	runtime.power_reason = &"ok"
	var snap := ControlTerminalSnapshotBuilder.build(world, assembly_id, host_id)
	if not bool(snap.get("valid", false)):
		world.free()
		return _fail("terminal snapshot invalid with oxygen module")
	var found: Dictionary = {}
	for node_variant: Variant in snap.get("nodes", []):
		var node: Dictionary = node_variant
		if int(node.get("element_id", 0)) == module_id:
			found = node
			break
	if found.is_empty():
		world.free()
		return _fail("oxygen module not listable on control terminal")
	if str(found.get("category", "")) != "machine":
		world.free()
		return _fail("oxygen module category must be machine")
	if str(found.get("kind", "")) != "oxygen_module":
		world.free()
		return _fail("oxygen module kind must be oxygen_module")
	var detail: Dictionary = found.get("detail", {})
	if not detail.has("machine_enabled") or not detail.has("powered"):
		world.free()
		return _fail("oxygen module detail missing enable/power")
	if (
		not detail.has("oxygen_current_l")
		or not detail.has("oxygen_capacity_l")
		or not detail.has("idle_w")
		or not detail.has("active_w")
		or not detail.has("demand_w")
	):
		world.free()
		return _fail("oxygen module detail missing liters/demand")
	var toggle := SetMachineEnabledCommand.new()
	toggle.element_id = module_id
	toggle.enabled = false
	if StringName(world.apply_set_machine_enabled(toggle).get("reason", &"")) != &"ok":
		world.free()
		return _fail("set_machine_enabled failed for oxygen module")
	snap = ControlTerminalSnapshotBuilder.build(world, assembly_id, host_id)
	for node_variant2: Variant in snap.get("nodes", []):
		var node2: Dictionary = node_variant2
		if int(node2.get("element_id", 0)) != module_id:
			continue
		if bool(node2.get("detail", {}).get("machine_enabled", true)):
			world.free()
			return _fail("snapshot did not reflect machine_enabled=false")
		break
	world.free()
	return true


func _test_host_hint_pin_prefers_pinned() -> bool:
	var pinned := ControlTerminalSnapshotBuilder.host_hint_for_refresh(42, 7)
	var fallthrough := ControlTerminalSnapshotBuilder.host_hint_for_refresh(0, 7)
	if pinned != 42:
		return _fail("pinned host must win over look-away aim")
	if fallthrough != 7:
		return _fail("no pin → fallthrough hint")
	return true


func _test_non_seat_hint_resolves_assembly_host() -> bool:
	## K / look-at-frame: non-seat hint on the assembly still gets an action bar
	## host; explicit seat hint stays pinned; hint=0 does not invent a seat.
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var assembly_id := int(built["assembly_id"])
	var host_id := int(built["host_id"])
	var foundation_id := int(built["foundation_id"])
	var from_frame := ControlTerminalSnapshotBuilder.build_bar_only(
		world,
		assembly_id,
		foundation_id
	)
	if not bool(from_frame.get("valid", false)):
		world.free()
		return _fail("non-seat hint snapshot invalid")
	if int(from_frame.get("control_seat_element_id", 0)) != host_id:
		world.free()
		return _fail(
			"non-seat hint must resolve assembly ControlSeat host, got %d"
			% int(from_frame.get("control_seat_element_id", 0))
		)
	var from_seat := ControlTerminalSnapshotBuilder.build_bar_only(
		world,
		assembly_id,
		host_id
	)
	if int(from_seat.get("control_seat_element_id", 0)) != host_id:
		world.free()
		return _fail("explicit seat hint must stay pinned")
	var no_hint := ControlTerminalSnapshotBuilder.build_bar_only(
		world,
		assembly_id,
		0
	)
	if int(no_hint.get("control_seat_element_id", -1)) != 0:
		world.free()
		return _fail("hint=0 must not invent a lowest-seat host")
	world.free()
	return true


func _test_interaction_card_seat_flags_and_toggle_invert() -> bool:
	## Compact-bar path: invert from authoritative state when `_nodes` empty.
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	if StringName(
		_configure_seat(world, host_id, true, false, true).get("reason", &"")
	) != &"ok":
		world.free()
		return _fail("configure failed")
	var card := world.get_interaction_card(host_id)
	if card == null or not card.keys.has("control_thrusters"):
		world.free()
		return _fail("InteractionCard must publish seat routing flags")
	if bool(card.keys.get("control_thrusters", true)):
		world.free()
		return _fail("card must reflect authoritative thrusters=false")
	# Invert path used by closed compact bar (no terminal node detail).
	var next_thrusters := not SeatControlState.flag_of(
		world.get_seat_control_state_ref(host_id),
		"control_thrusters"
	)
	if not next_thrusters:
		world.free()
		return _fail("invert of false must be true")
	var toggled := _configure_seat(world, host_id, null, next_thrusters, null)
	if not bool(toggled.get("control_thrusters", false)):
		world.free()
		return _fail("toggle OFF→ON must stick via authoritative state")
	var off_again := not SeatControlState.flag_of(
		world.get_seat_control_state_ref(host_id),
		"control_thrusters"
	)
	var toggled_off := _configure_seat(world, host_id, null, off_again, null)
	world.free()
	if bool(toggled_off.get("control_thrusters", true)):
		return _fail("toggle ON→OFF must stick (closed-bar invert path)")
	return true


func _test_seat_control_ref_is_stable() -> bool:
	var world := _boot_world()
	var built := _build_terminal_host(world)
	if built.has("error"):
		world.free()
		return _fail("host setup failed: %s" % built["error"])
	var host_id := int(built["host_id"])
	var defaults_a := world.get_seat_control_state_ref(host_id)
	var defaults_b := world.get_seat_control_state_ref(host_id)
	if defaults_a != defaults_b:
		world.free()
		return _fail("missing row must return shared defaults_ref")
	_configure_seat(world, host_id, false, true, true)
	var row_a := world.get_seat_control_state_ref(host_id)
	var row_b := world.get_seat_control_state_ref(host_id)
	if row_a != row_b or row_a.control_wheels:
		world.free()
		return _fail("ensure row must be stable shared ref")
	world.clear_element_instance_state(host_id)
	if world.has_seat_control_state(host_id):
		world.free()
		return _fail("clear_element_instance_state must drop seat_control row")
	world.free()
	return true


func _fail(message: String) -> bool:
	push_error("test_control_actions: %s" % message)
	get_tree().quit(1)
	return false
