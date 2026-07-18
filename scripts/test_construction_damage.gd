extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")

func _ready() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "CONSTRUCTION-DAMAGE-V1")
	var tests: Array[Callable] = [
		_test_partial_damage_remains,
		_test_lethal_damage_removes_element_without_refund,
		_test_lethal_damage_refunds_with_fraction,
		_test_last_element_removes_assembly,
		_test_bridge_destruction_splits,
	]
	for test: Callable in tests:
		if not bool(test.call()):
			return
	print("CONSTRUCTION-DAMAGE-V1: PASS")
	get_tree().quit(0)


func _test_partial_damage_remains() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	var spawn := _spawn_single(world)
	if not spawn.is_ok():
		world.free()
		return _fail("single spawn failed")
	var element_id := int(spawn.data["element_ids"][0])
	var element := world.get_element(element_id)
	var max_integrity := element.get_archetype().max_integrity
	var before_revision := element.state_revision
	var result := _damage(world, element_id, max_integrity * 0.4)
	if not result.is_ok():
		world.free()
		return _fail("partial damage rejected")
	if world.get_element(element_id) == null:
		world.free()
		return _fail("partial damage removed element")
	if element.integrity <= 0.0:
		world.free()
		return _fail("partial damage zeroed integrity")
	if element.state_revision <= before_revision:
		world.free()
		return _fail("partial damage did not bump state revision")
	if element.status_reason() != &"element_incomplete":
		world.free()
		return _fail("partial damage did not report incomplete status")
	world.free()
	return true


func _test_lethal_damage_removes_element_without_refund() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 10.0)
	var spawn := _spawn_single(world)
	if not spawn.is_ok():
		world.free()
		return _fail("single spawn failed")
	var element_id := int(spawn.data["element_ids"][0])
	var element := world.get_element(element_id)
	var store_before := world.get_resource_store("player").amount(
		"construction_component"
	)
	var result := _damage(world, element_id, element.integrity + 1.0)
	if not result.is_ok():
		world.free()
		return _fail("lethal damage rejected")
	if world.get_element(element_id) != null:
		world.free()
		return _fail("lethal damage left element in topology")
	var store_after := world.get_resource_store("player").amount(
		"construction_component"
	)
	if not is_equal_approx(store_before, store_after):
		world.free()
		return _fail("lethal damage refunded materials")
	if not bool(result.data.get("assembly_removed", false)):
		world.free()
		return _fail("lethal damage did not remove assembly")
	world.free()
	return true


func _test_lethal_damage_refunds_with_fraction() -> bool:
	var world := SimulationWorld.new()
	world.ensure_resource_store("player")
	world.set_resource_amount("player", "construction_component", 0.0)
	var spawn := _spawn_single(world)
	if not spawn.is_ok():
		world.free()
		return _fail("single spawn failed")
	var element_id := int(spawn.data["element_ids"][0])
	var element := world.get_element(element_id)
	var installed := float(element.installed_materials.get("construction_component", 0.0))
	var result := _damage(
		world,
		element_id,
		element.integrity + 1.0,
		0.5,
		"player"
	)
	if not result.is_ok():
		world.free()
		return _fail("refunding lethal damage rejected")
	if world.get_element(element_id) != null:
		world.free()
		return _fail("refunding lethal damage left element in topology")
	var refunded := world.get_resource_store("player").amount("construction_component")
	var expected := installed * 0.5
	if not is_equal_approx(refunded, expected):
		world.free()
		return _fail(
			"refunding lethal damage expected %.3f, got %.3f"
			% [expected, refunded]
		)
	world.free()
	return true


func _test_last_element_removes_assembly() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn_single(world)
	if not spawn.is_ok():
		world.free()
		return _fail("single spawn failed")
	var assembly_id := int(spawn.data["assembly_id"])
	var element_id := int(spawn.data["element_ids"][0])
	var result := _damage(
		world,
		element_id,
		world.get_element(element_id).integrity + 1.0
	)
	if not result.is_ok() or not result.data["assembly_removed"]:
		world.free()
		return _fail("last element destruction failed")
	if world.get_assembly_raw(assembly_id) != null:
		world.free()
		return _fail("assembly remained after last element destroyed")
	if not world.list_elements().is_empty():
		world.free()
		return _fail("elements remained after last element destroyed")
	world.free()
	return true


func _test_bridge_destruction_splits() -> bool:
	var world := SimulationWorld.new()
	var spawn := _spawn(world, _chain_blueprint(4), GridTransform.identity())
	if not spawn.is_ok():
		world.free()
		return _fail("chain spawn failed")
	var ids: Array = spawn.data["element_ids"]
	var bridge_id := int(ids[1])
	var result := _damage(
		world,
		bridge_id,
		world.get_element(bridge_id).integrity + 1.0
	)
	if not result.is_ok() or not result.data["split"]:
		world.free()
		return _fail("bridge destruction did not split")
	if world.get_element(bridge_id) != null:
		world.free()
		return _fail("bridge element remained in topology")
	if world.list_assemblies().size() != 2:
		world.free()
		return _fail("bridge destruction produced wrong assembly count")
	var survivor_id := int(result.data["survivor_assembly_id"])
	var survivor := world.get_assembly_raw(survivor_id)
	if survivor == null or survivor.element_ids.size() != 2:
		world.free()
		return _fail("survivor component size mismatch after bridge split")
	var new_ids: Array = result.data["new_assembly_ids"]
	if new_ids.size() != 1:
		world.free()
		return _fail("bridge split did not create one detached assembly")
	var detached := world.get_assembly_raw(int(new_ids[0]))
	if detached == null or detached.element_ids.size() != 1:
		world.free()
		return _fail("detached component size mismatch after bridge split")
	world.free()
	return true


func _spawn_single(world: SimulationWorld) -> StructuralCommandResult:
	return _spawn(world, _single_blueprint(Slice01Archetypes.frame()), GridTransform.identity())


func _spawn(
	world: SimulationWorld,
	blueprint: Blueprint,
	frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = frame
	return world.apply_structural_command_now(command)


func _damage(
	world: SimulationWorld,
	element_id: int,
	amount: float,
	refund_fraction_on_destroy: float = 0.0,
	store_id: String = ""
) -> StructuralCommandResult:
	var element := world.get_element(element_id)
	var command := DamageElementCommand.new()
	command.element_id = element_id
	command.expected_state_revision = element.state_revision
	command.damage = amount
	command.refund_fraction_on_destroy = refund_fraction_on_destroy
	command.store_id = store_id
	return world.apply_structural_command_now(command)


func _single_blueprint(archetype: ElementArchetype) -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"damage_single_%s" % archetype.archetype_id,
		[_placement("element_0", archetype, Vector3i.ZERO)]
	)


func _chain_blueprint(count: int) -> Blueprint:
	var placements: Array[BlueprintElementPlacement] = []
	for index: int in range(count):
		placements.append(_placement(
			"frame_%d" % index,
			Slice01Archetypes.frame(),
			Vector3i(index, 0, 0)
		))
	return BlueprintBaker.bake_from_placements("damage_chain", placements)


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


func _fail(reason: String) -> bool:
	print("CONSTRUCTION-DAMAGE-V1: FAIL %s" % reason)
	get_tree().quit(1)
	return false
