extends Node3D



const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")

## Join catch-up dig_ops replay: gateway contract (bool return, discard_yield,

## ordering). Terrain writes use a seeded flat block after is_area_editable —

## not generator streaming timing — so SDF probes stay deterministic in CI.



const DIG_POINT := Vector3(2.0, 0.0, 2.0)

const DIG_SAMPLE := DIG_POINT + Vector3(0.0, -0.35, 0.0)

const ORDER_FIRST := Vector3(1.0, 0.0, 1.0)

const ORDER_SECOND := Vector3(4.0, 0.0, 4.0)

const ORDER_FIRST_SAMPLE := ORDER_FIRST + Vector3(0.0, -0.35, 0.0)

const ORDER_SECOND_SAMPLE := ORDER_SECOND + Vector3(0.0, -0.35, 0.0)

const LOOT_TEST_POINT := Vector3(3.0, 0.0, 3.0)

## r=0.5 spheres barely overlap; span < path_max_span so host path-sweeps the gap.
const SWEEP_A := Vector3(0.0, 0.0, 0.0)
const SWEEP_B := Vector3(1.3, 0.0, 0.0)
const SWEEP_RADIUS := 0.5





func _ready() -> void:

	call_deferred("_run")





func _run() -> void:

	_HeadlessTestHarness.arm_watchdog(self, "COOP-DIG-REPLAY", 25.0)

	PlayerIdentity.override_local_uid("player")

	var tests: Array[Callable] = [

		_test_replay_invalid_target_returns_false,

		_test_replay_remote_dig_bool_and_carve,

		_test_join_dig_ops_replay_order,

		_test_replay_discard_yield_no_double_loot,

		_test_replay_skips_path_sweep,

	]

	for test: Callable in tests:

		if not bool(await test.call()):

			get_tree().quit(1)

			return

	print("COOP-DIG-REPLAY: PASS")

	get_tree().quit(0)





func _new_fixture() -> Dictionary:

	for _frame: int in range(3):

		await get_tree().process_frame

	var terrain := VoxelTerrain.new()

	terrain.name = "VoxelTerrain"

	terrain.generate_collisions = true

	var generator := VoxelGeneratorFlat.new()

	generator.channel = VoxelBuffer.CHANNEL_SDF

	generator.height = 0.0

	terrain.generator = generator

	terrain.mesher = VoxelMesherTransvoxel.new()

	terrain.run_stream_in_editor = true

	terrain.automatic_loading_enabled = true

	add_child(terrain)

	var viewer := VoxelViewer.new()

	viewer.name = "TerrainViewer"

	viewer.view_distance = 64

	viewer.requires_collisions = true

	viewer.requires_visuals = false

	terrain.add_child(viewer)

	if not await _wait_for_editable_terrain(terrain):

		terrain.queue_free()

		return {}

	if not _seed_flat_terrain(terrain):

		terrain.queue_free()

		return {}

	var placed := Node3D.new()

	placed.name = "PlacedBlocks"

	add_child(placed)

	var session_scene: PackedScene = load(

		"res://scenes/simulation_session.tscn"

	)

	var session: SimulationSession = session_scene.instantiate()

	session.name = "SimulationSession"

	add_child(session)

	var gateway := WorldCommandGateway.new()

	gateway.name = "WorldCommandGateway"

	gateway.terrain_path = NodePath("../VoxelTerrain")

	gateway.placed_blocks_path = NodePath("../PlacedBlocks")

	gateway.simulation_session_path = NodePath("../SimulationSession")

	add_child(gateway)

	session.gateway_path = NodePath("../WorldCommandGateway")

	await get_tree().process_frame

	session.world.ensure_resource_store(PlayerIdentity.store_id("player"))

	for _frame: int in range(4):

		await get_tree().physics_frame

	return {

		"terrain": terrain,

		"gateway": gateway,

		"session": session,

		"placed": placed,

		"world": session.world,

	}





func _free_fixture(fixture: Dictionary) -> void:

	for key: String in ["gateway", "session", "placed", "terrain"]:

		var node: Node = fixture.get(key)

		if node != null:

			node.queue_free()





func _voxel_target(point: Vector3) -> Dictionary:

	return {

		"valid": true,

		"point": point,

		"normal": Vector3.UP,

		"target_kind": InteractionHit.KIND_VOXEL,

		"aim_direction": Vector3(0.0, -1.0, 0.0),

	}





func _dig_command(point: Vector3, discard_yield: bool = false) -> Dictionary:

	return {

		"kind": &"voxel_remove",

		"target": _voxel_target(point),

		"parameters": {"radius": 0.5, "discard_yield": discard_yield},

	}





func _wire_op(point: Vector3, discard_yield: bool = true) -> Dictionary:

	var command := _dig_command(point, discard_yield)

	return CoopCommandCodec.build_dig_op(

		command,

		{"status": &"ok", "data": {"removed_volume_m3": 0.1}}

	)





func _host_dig(

	gateway: WorldCommandGateway,

	command: Dictionary

) -> Dictionary:

	var previous := gateway.actor_uid

	gateway.actor_uid = "host"

	var result := gateway._execute(command)

	gateway.actor_uid = previous

	return result





func _sample_sdf(tool: VoxelTool, point: Vector3) -> float:

	var cell := Vector3i(

		floori(point.x),

		floori(point.y),

		floori(point.z),

	)

	return tool.get_voxel_f(cell)





func _test_replay_invalid_target_returns_false() -> bool:

	var fixture := await _new_fixture()

	if fixture.is_empty():

		return _fail("fixture build failed (terrain not editable)")

	var gateway: WorldCommandGateway = fixture["gateway"]

	var rejected := gateway.replay_remote_dig({

		"kind": &"voxel_remove",

		"target": {"valid": false},

		"parameters": {"radius": 0.5},

	})

	_free_fixture(fixture)

	if rejected:

		return _fail("invalid target must return false from replay_remote_dig")

	return true





func _test_replay_remote_dig_bool_and_carve() -> bool:

	var fixture := await _new_fixture()

	if fixture.is_empty():

		return _fail("fixture build failed (terrain not editable)")

	var gateway: WorldCommandGateway = fixture["gateway"]

	var tool: VoxelTool = (fixture["terrain"] as VoxelTerrain).get_voxel_tool()

	tool.channel = VoxelBuffer.CHANNEL_SDF

	var before := _sample_sdf(tool, DIG_SAMPLE)

	if before >= -0.05:

		_free_fixture(fixture)

		return _fail(

			"seeded fixture must be solid at dig sample (sdf=%.4f)" % before

		)

	var ok := gateway.replay_remote_dig(_wire_op(DIG_POINT, true))

	var delta := _sample_sdf(tool, DIG_SAMPLE) - before

	_free_fixture(fixture)

	if not ok:

		return _fail("replay_remote_dig must return true on valid seeded carve")

	if delta <= 0.05:

		return _fail("seeded replay must carve terrain (delta=%.4f)" % delta)

	return true





func _test_join_dig_ops_replay_order() -> bool:

	var fixture := await _new_fixture()

	if fixture.is_empty():

		return _fail("fixture build failed (terrain not editable)")

	var gateway: WorldCommandGateway = fixture["gateway"]

	var tool: VoxelTool = (fixture["terrain"] as VoxelTerrain).get_voxel_tool()

	tool.channel = VoxelBuffer.CHANNEL_SDF

	var ops: Array = [

		_wire_op(ORDER_FIRST, true),

		_wire_op(ORDER_SECOND, true),

	]

	var first_before := _sample_sdf(tool, ORDER_FIRST_SAMPLE)

	var second_before := _sample_sdf(tool, ORDER_SECOND_SAMPLE)

	for op_variant: Variant in ops:

		if not gateway.replay_remote_dig(op_variant):

			_free_fixture(fixture)

			return _fail("ordered replay step must return true")

		await get_tree().physics_frame

	var first_delta := _sample_sdf(tool, ORDER_FIRST_SAMPLE) - first_before

	var second_delta := _sample_sdf(tool, ORDER_SECOND_SAMPLE) - second_before

	if first_delta <= 0.05 or second_delta <= 0.05:

		_free_fixture(fixture)

		return _fail(

			"ordered replay must carve both holes (d1=%.4f d2=%.4f)"

			% [first_delta, second_delta]

		)



	var partial_fixture := await _new_fixture()

	if partial_fixture.is_empty():

		_free_fixture(fixture)

		return _fail("partial fixture build failed")

	var partial_gateway: WorldCommandGateway = partial_fixture["gateway"]

	var partial_tool: VoxelTool = (

		(partial_fixture["terrain"] as VoxelTerrain).get_voxel_tool()

	)

	partial_tool.channel = VoxelBuffer.CHANNEL_SDF

	var partial_first_before := _sample_sdf(partial_tool, ORDER_FIRST_SAMPLE)

	if not partial_gateway.replay_remote_dig(ops[1]):

		_free_fixture(fixture)

		_free_fixture(partial_fixture)

		return _fail("single-op replay must return true")

	await get_tree().physics_frame

	var partial_first_delta := (

		_sample_sdf(partial_tool, ORDER_FIRST_SAMPLE) - partial_first_before

	)

	_free_fixture(fixture)

	_free_fixture(partial_fixture)

	if partial_first_delta > 0.05:

		return _fail(

			"second-only replay must not carve the first hole (delta=%.4f)"

			% partial_first_delta

		)

	return true





func _test_replay_discard_yield_no_double_loot() -> bool:

	var fixture := await _new_fixture()

	if fixture.is_empty():

		return _fail("fixture build failed (terrain not editable)")

	var gateway: WorldCommandGateway = fixture["gateway"]

	var world: SimulationWorld = fixture["world"]

	var command := _dig_command(LOOT_TEST_POINT, false)

	var result := _host_dig(gateway, command)

	if float((result.get("data", {}) as Dictionary).get("removed_volume_m3", 0.0)) <= 0.0:

		_free_fixture(fixture)

		return _fail("host dig for loot test removed zero volume")

	var loot_before := world.list_world_loot_piles().size()

	var op := CoopCommandCodec.build_dig_op(command, result)

	if bool((op.get("parameters", {}) as Dictionary).get("discard_yield", true)):

		_free_fixture(fixture)

		return _fail("wire op must preserve host discard_yield=false")

	if not gateway.replay_remote_dig(op):

		_free_fixture(fixture)

		return _fail("replay_remote_dig must return true after host dig")

	var loot_after := world.list_world_loot_piles().size()

	_free_fixture(fixture)

	if loot_after > loot_before:

		return _fail(

			"replay must force discard_yield (loot %d -> %d)"

			% [loot_before, loot_after]

		)

	return true





func _test_replay_skips_path_sweep() -> bool:

	## Host back-to-back digs path-sweep (2nd bite removes more volume). Coop

	## replay must not — 2nd replay bite stays near a lone-sphere volume.

	var host_fixture := await _new_fixture()

	if host_fixture.is_empty():

		return _fail("host fixture build failed (terrain not editable)")

	var host_gateway: WorldCommandGateway = host_fixture["gateway"]

	var host_cmd_a := _dig_command(SWEEP_A, true)

	host_cmd_a["parameters"]["radius"] = SWEEP_RADIUS

	var host_cmd_b := _dig_command(SWEEP_B, true)

	host_cmd_b["parameters"]["radius"] = SWEEP_RADIUS

	_host_dig(host_gateway, host_cmd_a)

	var host_b := _host_dig(host_gateway, host_cmd_b)

	var host_b_vol := float(

		(host_b.get("data", {}) as Dictionary).get("removed_volume_m3", 0.0)

	)

	_free_fixture(host_fixture)

	var alone_fixture := await _new_fixture()

	if alone_fixture.is_empty():

		return _fail("alone fixture build failed")

	var alone_gateway: WorldCommandGateway = alone_fixture["gateway"]

	var alone_b := _host_dig(alone_gateway, host_cmd_b)

	var alone_b_vol := float(

		(alone_b.get("data", {}) as Dictionary).get("removed_volume_m3", 0.0)

	)

	_free_fixture(alone_fixture)

	if host_b_vol <= 0.0 or alone_b_vol <= 0.0:

		return _fail(

			"sweep probe digs must remove volume (host_b=%.4f alone_b=%.4f)"

			% [host_b_vol, alone_b_vol]

		)

	if host_b_vol <= alone_b_vol * 1.2:

		return _fail(

			"host A→B should path-sweep more than lone B (host_b=%.4f alone_b=%.4f)"

			% [host_b_vol, alone_b_vol]

		)

	var replay_fixture := await _new_fixture()

	if replay_fixture.is_empty():

		return _fail("replay fixture build failed (terrain not editable)")

	var replay_gateway: WorldCommandGateway = replay_fixture["gateway"]

	var op_a := _wire_op(SWEEP_A, true)

	(op_a["parameters"] as Dictionary)["radius"] = SWEEP_RADIUS

	var op_b := _wire_op(SWEEP_B, true)

	(op_b["parameters"] as Dictionary)["radius"] = SWEEP_RADIUS

	## Same gate as replay_remote_dig — measure 2nd-bite volume without sweep.

	replay_gateway._replaying_remote_dig = true

	replay_gateway._remove_voxel(op_a, op_a["target"])

	var replay_b: Dictionary = replay_gateway._remove_voxel(op_b, op_b["target"])

	replay_gateway._replaying_remote_dig = false

	var replay_b_vol := float(

		(replay_b.get("data", {}) as Dictionary).get("removed_volume_m3", 0.0)

	)

	_free_fixture(replay_fixture)

	if replay_b_vol <= 0.0:

		return _fail("replay dig B removed no volume")

	if replay_b_vol > alone_b_vol * 1.15:

		return _fail(

			"replay A→B must not path-sweep (replay_b=%.4f alone_b=%.4f)"

			% [replay_b_vol, alone_b_vol]

		)

	if replay_b_vol > host_b_vol * 0.75:

		return _fail(

			"replay dig B must carve less than host path-sweep (host_b=%.4f replay_b=%.4f)"

			% [host_b_vol, replay_b_vol]

		)

	return true





func _wait_for_editable_terrain(terrain: VoxelTerrain) -> bool:

	var tool: VoxelTool = terrain.get_voxel_tool()

	tool.channel = VoxelBuffer.CHANNEL_SDF

	var edit_box := AABB(Vector3(-8.0, -8.0, -8.0), Vector3(16.0, 16.0, 16.0))

	for _frame: int in range(180):

		if tool.is_area_editable(edit_box):

			return true

		await get_tree().physics_frame

	return false





## Direct block write after is_area_editable — avoids reading default SDF from

## blocks that have not streamed yet (see granular_corridor_test.gd).

func _seed_flat_terrain(

	terrain: VoxelTerrain,

	surface_y: float = 0.0

) -> bool:

	var block_size := terrain.get_data_block_size()

	var block_pos := Vector3i.ZERO

	var buffer := VoxelBuffer.new()

	buffer.create(block_size, block_size, block_size)

	var block_origin := terrain.data_block_to_voxel(block_pos)

	for z: int in range(block_size):

		for x: int in range(block_size):

			for y: int in range(block_size):

				var world_y := float(block_origin.y + y)

				buffer.set_voxel_f(

					world_y - surface_y,

					x,

					y,

					z,

					VoxelBuffer.CHANNEL_SDF

				)

	return terrain.try_set_block_data(block_pos, buffer)





func _fail(message: String) -> bool:

	push_error(message)

	print("COOP-DIG-REPLAY: FAIL — %s" % message)

	return false


