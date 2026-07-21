extends Node
## Headless logic gate for the mounted dozer blade (DozerBladeService).
##
## The blade works loose material only, through gateway hooks. Here those hooks
## are stubbed with deterministic callables — the same shape the stationary drill
## uses in test_industry_v1 — so the arithmetic is checked without a granular
## world or real terrain: it loads loose material into its buffer as yield, gates
## on power, and plows aside (losing nothing) when the buffer is full.

const _HeadlessTestHarness := preload(
	"res://scripts/testing/headless_test_harness.gd"
)

const LABEL := "DOZER-BLADE"
const EPS := 0.000001
## Loose regolith the material field yields when sampled at the world origin.
const LOOSE_RESOURCE := "ore_mare_regolith"


func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, LABEL)
	var tests: Array[Callable] = [
		_test_loads_loose_into_buffer,
		_test_no_power_no_work,
		_test_no_contact_no_work,
		_test_full_buffer_plows_without_loss,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


func _fail(message: String) -> bool:
	printerr("%s: FAIL %s" % [LABEL, message])
	get_tree().quit(1)
	return false


## Spawn a single operational dozer_blade (disconnected is fine for logic) and
## return its element id, or -1.
func _spawn_dozer(world: SimulationWorld) -> int:
	var placement := BlueprintElementPlacement.new()
	placement.local_id = "dozer_0"
	placement.archetype = Slice01Archetypes.dozer_blade()
	placement.origin_cell = Vector3i.ZERO
	var blueprint := BlueprintBaker.bake_from_placements(
		"dozer_blade_logic_test",
		[placement]
	)
	blueprint.allow_disconnected = true
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = GridTransform.identity()
	var result := world.apply_structural_command_now(command)
	if not result.is_ok():
		return -1
	return int(result.data["local_to_element_id"]["dozer_0"])


func _service_with_hooks(
	counters: Dictionary,
	load_volume: float
) -> DozerBladeService:
	var service := DozerBladeService.new()
	var contact_hook := func(_element_id: int) -> bool:
		return bool(counters.get("contact", true))
	var load_hook := func(_element_id: int, _budget_m3: float) -> float:
		counters["load"] = int(counters["load"]) + 1
		return load_volume
	var plow_hook := func(_element_id: int) -> float:
		counters["plow"] = int(counters["plow"]) + 1
		return 0.02
	var point_hook := func(_element_id: int) -> Vector3:
		return Vector3.ZERO
	service.set_dozer_blade_hooks(contact_hook, load_hook, plow_hook, point_hook)
	return service


func _tick(service: DozerBladeService, world: SimulationWorld) -> void:
	service.tick(
		world,
		world.ensure_cargo_graph_current(),
		CargoTransferService.new(),
		0.25
	)


func _test_loads_loose_into_buffer() -> bool:
	var world := SimulationWorld.new()
	var id := _spawn_dozer(world)
	if id < 0:
		world.free()
		return _fail("dozer spawn failed")
	var element := world.get_element(id)
	element.set_industry_buffer({})
	var runtime := world.ensure_industry_element_runtime(id)
	runtime.machine_enabled = true
	runtime.powered = true
	var counters := {"load": 0, "plow": 0}
	var service := _service_with_hooks(counters, 0.05)
	_tick(service, world)
	if int(counters["load"]) < 1:
		world.free()
		return _fail("powered blade did not load loose material")
	if element.industry_buffer_amount(LOOSE_RESOURCE) <= EPS:
		world.free()
		return _fail("loaded loose material was not credited to the buffer")
	if element.industry_status_reason() != &"ok":
		world.free()
		return _fail(
			"working blade expected reason ok, got %s"
			% str(element.industry_status_reason())
		)
	if int(counters["plow"]) != 0:
		world.free()
		return _fail("blade with buffer room must load, not plow")
	world.free()
	return true


func _test_no_power_no_work() -> bool:
	var world := SimulationWorld.new()
	var id := _spawn_dozer(world)
	if id < 0:
		world.free()
		return _fail("dozer spawn failed")
	var element := world.get_element(id)
	element.set_industry_buffer({})
	var runtime := world.ensure_industry_element_runtime(id)
	runtime.machine_enabled = true
	runtime.powered = false
	var counters := {"load": 0, "plow": 0}
	var service := _service_with_hooks(counters, 0.05)
	_tick(service, world)
	if int(counters["load"]) != 0 or int(counters["plow"]) != 0:
		world.free()
		return _fail("unpowered blade must do no work")
	if element.industry_buffer_amount(LOOSE_RESOURCE) > EPS:
		world.free()
		return _fail("unpowered blade credited material")
	world.free()
	return true


func _test_no_contact_no_work() -> bool:
	var world := SimulationWorld.new()
	var id := _spawn_dozer(world)
	if id < 0:
		world.free()
		return _fail("dozer spawn failed")
	var element := world.get_element(id)
	element.set_industry_buffer({})
	var runtime := world.ensure_industry_element_runtime(id)
	runtime.machine_enabled = true
	runtime.powered = true
	var counters := {"load": 0, "plow": 0, "contact": false}
	var service := _service_with_hooks(counters, 0.05)
	_tick(service, world)
	if int(counters["load"]) != 0 or int(counters["plow"]) != 0:
		world.free()
		return _fail("blade with no loose material must do no work")
	if element.industry_status_reason() != &"no_terrain_contact":
		world.free()
		return _fail(
			"blade off a heap expected no_terrain_contact, got %s"
			% str(element.industry_status_reason())
		)
	world.free()
	return true


func _test_full_buffer_plows_without_loss() -> bool:
	var world := SimulationWorld.new()
	var id := _spawn_dozer(world)
	if id < 0:
		world.free()
		return _fail("dozer spawn failed")
	var element := world.get_element(id)
	element.set_industry_buffer({})
	var capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
		"dozer_blade"
	)
	# add() rejects any request over remaining room outright, so fill to the brim
	# with exactly what fits rather than an arbitrarily large number.
	var addable := element.industry_buffer.max_addable_amount(
		LOOSE_RESOURCE,
		capacity
	)
	element.industry_buffer.add(LOOSE_RESOURCE, addable, capacity)
	var before := element.industry_buffer_amount(LOOSE_RESOURCE)
	if before <= EPS:
		world.free()
		return _fail("fixture failed to fill the buffer")
	var runtime := world.ensure_industry_element_runtime(id)
	runtime.machine_enabled = true
	runtime.powered = true
	var counters := {"load": 0, "plow": 0}
	var service := _service_with_hooks(counters, 0.05)
	_tick(service, world)
	if int(counters["plow"]) < 1:
		world.free()
		return _fail("full blade must plow material aside")
	if int(counters["load"]) != 0:
		world.free()
		return _fail("full blade must not load — no room to store it")
	if absf(element.industry_buffer_amount(LOOSE_RESOURCE) - before) > EPS:
		world.free()
		return _fail("plowing must not change what the buffer holds")
	if element.industry_status_reason() != &"storage_full":
		world.free()
		return _fail(
			"full blade expected storage_full, got %s"
			% str(element.industry_status_reason())
		)
	world.free()
	return true
