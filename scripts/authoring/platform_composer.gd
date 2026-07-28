class_name PlatformComposer
extends RefCounted

## 6×8 large_frame deck on 4× Ø4.5 m Platform wheels. Separate from RoverComposer.

const DECK_COUNT_X := 6
const DECK_COUNT_Z := 8
const LARGE_STEP_CELLS := 5
const WHEEL_ARCHETYPE_ID := "Wheel_Platform_01"
const SUSPENSION_ARCHETYPE_ID := "Suspension_Platform"
const BATTERY_COUNT := 2


static func wheel_clearance_m() -> float:
	var suspension := Slice01Archetypes.load_required(SUSPENSION_ARCHETYPE_ID)
	var wheel := Slice01Archetypes.load_required(WHEEL_ARCHETYPE_ID)
	if (
		suspension == null
		or wheel == null
		or suspension.suspension_definition == null
		or wheel.wheel_definition == null
	):
		return 0.0
	return (
		suspension.suspension_definition.suspension_travel_m
		+ wheel.wheel_definition.radius_m
	)


static func compose(
	world: SimulationWorld,
	grid_frame: GridTransform = GridTransform.identity(),
	store_id: String = PlayerIdentity.local_store_id()
) -> Dictionary:
	if world == null:
		return {"ok": false, "error": "no_world"}
	world.begin_structural_batch()
	var result := _compose_batched(world, grid_frame, store_id)
	world.end_structural_batch()
	return result


static func _compose_batched(
	world: SimulationWorld,
	grid_frame: GridTransform,
	store_id: String
) -> Dictionary:
	var large := Slice01Archetypes.large_frame()
	var suspension := Slice01Archetypes.load_required(SUSPENSION_ARCHETYPE_ID)
	var wheel := Slice01Archetypes.load_required(WHEEL_ARCHETYPE_ID)
	if large == null or suspension == null or wheel == null:
		return {"ok": false, "error": "missing_platform_archetypes"}
	for archetype: ElementArchetype in [
		large,
		suspension,
		wheel,
		Slice01Archetypes.cockpit(),
		Slice01Archetypes.power_battery_small(),
		Slice01Archetypes.power_distributor_small(),
	]:
		if archetype != null:
			world.get_archetype_registry().register(archetype)
	var helper := AssemblyBuildHelper.new(world, store_id)
	helper.ensure_materials()
	if not helper.spawn_anchor(large, grid_frame):
		return {"ok": false, "error": helper.last_error}
	if not _place_deck(helper, large):
		return {"ok": false, "error": helper.last_error}
	if not _place_wheels(helper, suspension, wheel):
		return {"ok": false, "error": helper.last_error}
	if not _place_modules(helper):
		return {"ok": false, "error": helper.last_error}
	helper.weld_all()
	if not helper.last_error.is_empty():
		return {"ok": false, "error": helper.last_error}
	if not _wire_power(helper):
		return {"ok": false, "error": helper.last_error}
	_charge_batteries(world, helper.element_ids)
	_configure_steer(world, helper.element_ids)
	world.get_locomotion_controller(helper.assembly_id).mark_released_from_anchor()
	world.get_locomotion_controller(helper.assembly_id).set_parking_brake(true)
	# Seed electric graph so corner wheels are powered on the first drive tick.
	IndustryElectricBudget.apply_tick(world, 0.25)
	return {
		"ok": true,
		"assembly_id": helper.assembly_id,
		"element_ids": helper.element_ids.duplicate(),
	}


static func spawn_on_terrain(
	session: SimulationSession,
	world_position: Vector3,
	store_id: String = AssemblyBuildHelper.AUTHORING_STORE_ID,
	terrain: Node3D = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	if session == null or session.world == null:
		return {"ok": false, "error": "no_session"}
	var assembly_transform := _assembly_transform_on_surface(
		world_position,
		terrain,
		tool,
		space_state
	)
	var grid_frame := GridSpawnUtil.grid_frame_from_transform(assembly_transform)
	var result := compose(session.world, grid_frame, store_id)
	if not bool(result.get("ok", false)):
		return result
	var assembly_id := int(result.get("assembly_id", 0))
	if assembly_id <= 0:
		return {"ok": false, "error": "no_assembly"}
	var motion := AssemblyMotionState.from_grid_frame(grid_frame)
	motion.transform.origin = assembly_transform.origin
	motion.transform.basis = assembly_transform.basis
	motion.frozen = false
	motion.sleeping = false
	motion.linear_velocity = Vector3.ZERO
	motion.angular_velocity = Vector3.ZERO
	if session.projection != null:
		session.projection.project_assembly_now(assembly_id, motion)
	if session.visuals != null:
		session.visuals.rebuild_assembly(assembly_id)
	if session.piston_visuals != null:
		session.piston_visuals.rebuild_assembly(assembly_id)
	result["spawn_transform"] = assembly_transform
	return result


static func _assembly_transform_on_surface(
	surface_point: Vector3,
	terrain: Node3D,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D
) -> Transform3D:
	var archetype := Slice01Archetypes.large_frame()
	var contact := GridPoseUtil.ground_contact_local(archetype, 0)
	var clearance := wheel_clearance_m()
	var up := GravityField.resolve_up(terrain, surface_point)
	var field := GravityField.find_in_tree(terrain)
	var seated_basis := Basis.IDENTITY
	if field != null and field.mode == GravityField.Mode.RADIAL:
		seated_basis = field.tangent_basis_at(surface_point)
	var seat_point := RoverDemoSpawn._lowest_surface_point_near(
		surface_point,
		terrain,
		tool,
		space_state
	)
	return Transform3D(
		seated_basis,
		seat_point - seated_basis * contact + seated_basis.y.normalized() * clearance
	)


static func _place_deck(helper: AssemblyBuildHelper, large: ElementArchetype) -> bool:
	for iz: int in range(DECK_COUNT_Z):
		for ix: int in range(DECK_COUNT_X):
			if ix == 0 and iz == 0:
				continue
			var origin := Vector3i(ix * LARGE_STEP_CELLS, 0, iz * LARGE_STEP_CELLS)
			if not helper.place(large, origin, 0, "deck_%d_%d" % [ix, iz]):
				return false
	return true


static func _place_wheels(
	helper: AssemblyBuildHelper,
	suspension: ElementArchetype,
	wheel: ElementArchetype
) -> bool:
	var max_x := DECK_COUNT_X * LARGE_STEP_CELLS - 1
	var max_z := DECK_COUNT_Z * LARGE_STEP_CELLS - 1
	# Mid-face of the corner large_frame blocks (cell 2 inside each 5-cell cube).
	var axle_z: Array[int] = [2, max_z - 2]
	var axle_index := 0
	for z: int in axle_z:
		var steerable := axle_index == 0
		for side: int in [-1, 1]:
			var chassis_cell := (
				Vector3i(0, 0, z) if side < 0 else Vector3i(max_x, 0, z)
			)
			var outward := Vector3i.LEFT if side < 0 else Vector3i.RIGHT
			var key := "%s_%d" % ["L" if side < 0 else "R", axle_index]
			var plan := RoverComposer._plan_wheel_pair(
				suspension,
				wheel,
				chassis_cell,
				outward
			)
			if plan.is_empty():
				helper.last_error = "no_wheel_pair_pose:%s" % key
				return false
			if not helper.place(
				suspension,
				plan["suspension_origin"],
				int(plan["suspension_orientation"]),
				"suspension_%s" % key
			):
				return false
			if not helper.place(
				wheel,
				plan["wheel_origin"],
				int(plan["wheel_orientation"]),
				"wheel_%s" % key
			):
				return false
			helper.element_ids["pair_%s" % key] = {
				"suspension": helper.element_ids.get("suspension_%s" % key, 0),
				"wheel": helper.element_ids.get("wheel_%s" % key, 0),
				"steerable": steerable,
			}
		axle_index += 1
	return true


static func _place_modules(helper: AssemblyBuildHelper) -> bool:
	# Deck top = y=5 (large_frame occupies y=0..4).
	const DECK_Y := 5
	var mid_x := int((DECK_COUNT_X * LARGE_STEP_CELLS) / 2.0) - 1
	var mid_z := int((DECK_COUNT_Z * LARGE_STEP_CELLS) / 2.0) - 1
	var max_x := DECK_COUNT_X * LARGE_STEP_CELLS - 1
	var max_z := DECK_COUNT_Z * LARGE_STEP_CELLS - 1
	if not helper.place(
		Slice01Archetypes.cockpit(),
		Vector3i(mid_x - 1, DECK_Y, 2),
		0,
		"cockpit"
	):
		return false
	# Small distributor supply_radius = 6 m. Deck is 15×20 m — center hubs
	# leave corner wheels on no_power (drive torque zeroed every tick).
	# One hub next to each wheel keeps every tire inside the bubble.
	var axle_z: Array[int] = [2, max_z - 2]
	var dist_i := 0
	for z: int in axle_z:
		for x: int in [1, max_x - 2]:
			var key := "distributor" if dist_i == 0 else "distributor_%d" % dist_i
			if not helper.place(
				Slice01Archetypes.power_distributor_small(),
				Vector3i(x, DECK_Y, z),
				0,
				key
			):
				return false
			dist_i += 1
	for battery_i: int in range(BATTERY_COUNT):
		var key := "battery" if battery_i == 0 else "battery_%d" % (battery_i + 1)
		if not helper.place(
			Slice01Archetypes.power_battery_small(),
			Vector3i(mid_x + 4, DECK_Y, mid_z + battery_i * 3),
			0,
			key
		):
			return false
	return true


static func _wire_power(helper: AssemblyBuildHelper) -> bool:
	# Stiff port wires, not hanging ropes: 2×4 connect_cable on a 15×20 m
	# deck flooded the rope freeze path and spammed freed-instance errors
	# every frame when bodies rebuilt. Distributors still cover wheels
	# wirelessly within supply_radius_m.
	var batteries: Array[String] = []
	var distributors: Array[String] = []
	for key: Variant in helper.element_ids.keys():
		var key_str := str(key)
		if key_str == "battery" or key_str.begins_with("battery_"):
			batteries.append(key_str)
		elif key_str == "distributor" or key_str.begins_with("distributor_"):
			distributors.append(key_str)
	batteries.sort()
	distributors.sort()
	if batteries.is_empty() or distributors.is_empty():
		helper.last_error = "missing_power_parts"
		return false
	# One battery → all hubs; second battery → first hub (backup feed).
	for dist_key: String in distributors:
		if not helper.connect_ports(
			batteries[0], "power_out", dist_key, "power_in"
		):
			return false
	if batteries.size() > 1:
		if not helper.connect_ports(
			batteries[1], "power_out", distributors[0], "power_in"
		):
			return false
	return true


static func _charge_batteries(world: SimulationWorld, element_ids: Dictionary) -> void:
	for key: Variant in element_ids.keys():
		var key_str := str(key)
		if key_str != "battery" and not key_str.begins_with("battery_"):
			continue
		IndustryElectricBudget.mark_battery_charged(
			world, int(element_ids.get(key_str, 0))
		)


static func _configure_steer(world: SimulationWorld, element_ids: Dictionary) -> void:
	for key: Variant in element_ids.keys():
		var key_str := str(key)
		if not key_str.begins_with("pair_"):
			continue
		var pair_variant: Variant = element_ids[key]
		if not pair_variant is Dictionary:
			continue
		var pair: Dictionary = pair_variant
		if not bool(pair.get("steerable", false)):
			continue
		var wheel_id := int(pair.get("wheel", 0))
		if wheel_id <= 0:
			continue
		var command := ConfigureWheelCommand.new()
		command.wheel_element_id = wheel_id
		command.steerable_set = true
		command.steerable = true
		world.apply_configure_wheel(command)
