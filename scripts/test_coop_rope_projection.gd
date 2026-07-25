extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Guest join rebuild must not leave stale frozen-rope body refs that make
## rope_path SCRIPT ERROR every frame (coop join rope_path spam).


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "COOP-ROPE-PROJECTION")
	if not await _test_rebuild_all_clears_stale_frozen_rope_bodies():
		return
	if not await _test_bind_world_rebuild_clears_stale_frozen_rope_bodies():
		return
	print("COOP-ROPE-PROJECTION: PASS")
	get_tree().quit(0)


func _test_rebuild_all_clears_stale_frozen_rope_bodies() -> bool:
	var fixture := _new_fixture()
	var link_id := await _seed_frozen_rope(fixture)
	if link_id < 0:
		_free_fixture(fixture)
		return _fail("could not seed frozen rope")
	var projection: SimulationPhysicsProjection = fixture["projection"]
	if projection.rope_path(link_id).is_empty():
		_free_fixture(fixture)
		return _fail("frozen rope_path empty before rebuild")
	projection.rebuild_all()
	if not projection._rope_states.is_empty():
		_free_fixture(fixture)
		return _fail("_rope_states not cleared after rebuild_all")
	for _i: int in range(100):
		if not projection.rope_path(link_id).is_empty():
			_free_fixture(fixture)
			return _fail(
				"rope_path must return empty after rebuild cleared cache"
			)
	_free_fixture(fixture)
	return true


func _test_bind_world_rebuild_clears_stale_frozen_rope_bodies() -> bool:
	var fixture := _new_fixture()
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	var link_id := await _seed_frozen_rope(fixture)
	if link_id < 0:
		_free_fixture(fixture)
		return _fail("bind_world fixture: could not seed frozen rope")
	projection.unbind_world()
	projection.bind_world(world)
	if not projection._rope_states.is_empty():
		_free_fixture(fixture)
		return _fail("_rope_states not cleared after bind_world rebuild")
	for _i: int in range(100):
		projection.rope_path(link_id)
	_free_fixture(fixture)
	return true


func _seed_frozen_rope(fixture: Dictionary) -> int:
	var world: SimulationWorld = fixture["world"]
	var projection: SimulationPhysicsProjection = fixture["projection"]
	var spawned: StructuralCommandResult = _spawn(
		world,
		_single_blueprint(Slice01Archetypes.frame()),
		GridTransform.identity()
	)
	if not spawned.is_ok():
		return -1
	var element_id: int = int(spawned.data["element_ids"][0])
	var assembly_id: int = int(spawned.data["assembly_id"])
	var body := projection.get_physics_body(assembly_id) as RigidBody3D
	if body == null:
		return -1
	await get_tree().process_frame
	var origin := world.element_world_transform(element_id).origin
	var anchor := origin + Vector3(5.0, 0.0, 0.0)
	var roped: StructuralCommandResult = world.connect_rope(
		element_id,
		origin,
		0,
		anchor,
		0.5
	)
	if not roped.is_ok():
		return -1
	var link_id := int(roped.data["link_id"])
	var link: IndustryElectricLink = world.get_industry_network().get_link(link_id)
	var revision := world.get_assembly_raw(assembly_id).topology_revision
	var to_local := body.global_transform.affine_inverse()
	var path_local := PackedVector3Array([to_local * origin, to_local * anchor])
	projection._rope_states[link_id] = {
		"_frozen": {
			"body": body,
			"path_local": path_local,
			"assembly_id": assembly_id,
			"revision": revision,
			"rest_m": link.rest_length_m,
		}
	}
	return link_id


func _new_fixture() -> Dictionary:
	var root := Node.new()
	add_child(root)
	var world := SimulationWorld.new()
	root.add_child(world)
	var projection := SimulationPhysicsProjection.new()
	root.add_child(projection)
	projection.bind_world(world)
	return {
		"root": root,
		"world": world,
		"projection": projection,
	}


func _free_fixture(fixture: Dictionary) -> void:
	var root: Node = fixture["root"]
	root.queue_free()


func _spawn(
	world: SimulationWorld,
	blueprint: Blueprint,
	frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = frame
	return world.apply_structural_command_now(command)


func _single_blueprint(archetype: ElementArchetype) -> Blueprint:
	return BlueprintBaker.bake_from_placements(
		"coop_rope_projection_%s" % archetype.archetype_id,
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


func _fail(reason: String) -> bool:
	print("COOP-ROPE-PROJECTION: FAIL %s" % reason)
	get_tree().quit(1)
	return false
