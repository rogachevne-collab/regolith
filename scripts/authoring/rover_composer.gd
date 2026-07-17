class_name RoverComposer
extends RefCounted

## Deterministic rover build from RoverIntent. Agent never picks cells.


static func compose(
	world: SimulationWorld,
	intent: RoverIntent,
	grid_frame: GridTransform = GridTransform.identity(),
	store_id: String = "player"
) -> Dictionary:
	if world == null:
		return {"ok": false, "error": "no_world"}
	if intent == null:
		intent = RoverIntent.defaults()
	var unsupported := intent.unsupported_reason()
	if not unsupported.is_empty():
		return {"ok": false, "error": unsupported}
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)
	var helper := AssemblyBuildHelper.new(world, store_id)
	helper.ensure_materials(800.0)
	if not helper.spawn_anchor(Slice01Archetypes.rover_frame(), grid_frame):
		return {"ok": false, "error": helper.last_error}
	if not _place_chassis(helper, intent):
		return {"ok": false, "error": helper.last_error}
	if not _place_wheels(helper, intent):
		return {"ok": false, "error": helper.last_error}
	if not _place_modules(helper, intent):
		return {"ok": false, "error": helper.last_error}
	helper.weld_all()
	if not _wire_power(helper):
		return {"ok": false, "error": helper.last_error}
	_charge_batteries(world, helper.element_ids)
	_configure_steer(world, helper.element_ids)
	var validate := RoverValidator.validate(world, helper.assembly_id, intent)
	if not bool(validate.get("ok", false)):
		return {
			"ok": false,
			"error": "validate_failed",
			"failures": validate.get("failures", []),
			"assembly_id": helper.assembly_id,
			"element_ids": helper.element_ids,
			"intent": intent.to_dict(),
		}
	return {
		"ok": true,
		"assembly_id": helper.assembly_id,
		"element_ids": helper.element_ids,
		"intent": intent.to_dict(),
		"validate": validate,
	}


static func compose_from_phrase(
	world: SimulationWorld,
	phrase: String,
	grid_frame: GridTransform = GridTransform.identity(),
	store_id: String = "player"
) -> Dictionary:
	return compose(world, RoverIntent.from_phrase(phrase), grid_frame, store_id)


## Spawn a composed rover seated on terrain (game / session path).
static func spawn_on_terrain(
	session: SimulationSession,
	world_position: Vector3,
	intent: RoverIntent = null,
	store_id: String = "player",
	terrain: Node3D = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	if session == null or session.world == null:
		return {"ok": false, "error": "no_session"}
	if intent == null:
		intent = RoverIntent.defaults()
	var assembly_transform := RoverDemoSpawn.assembly_transform_on_surface(
		world_position,
		Basis.IDENTITY,
		terrain,
		tool,
		space_state
	)
	var grid_frame := GridSpawnUtil.grid_frame_from_transform(assembly_transform)
	var result := compose(session.world, intent, grid_frame, store_id)
	if not bool(result.get("ok", false)):
		return result
	var assembly_id := int(result.get("assembly_id", 0))
	if assembly_id <= 0:
		return {"ok": false, "error": "no_assembly"}
	session.world.get_locomotion_controller(assembly_id).mark_released_from_anchor()
	var locomotion := session.world.get_locomotion_controller(assembly_id)
	locomotion.set_parking_brake(true)
	var motion := AssemblyMotionState.from_grid_frame(grid_frame)
	motion.transform.origin.y = assembly_transform.origin.y
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
	if session.wheel_visuals != null:
		session.wheel_visuals.rebuild_assembly(assembly_id)
	result["spawn_transform"] = assembly_transform
	return result


static func spawn_on_terrain_from_phrase(
	session: SimulationSession,
	world_position: Vector3,
	phrase: String,
	store_id: String = "player",
	terrain: Node3D = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	return spawn_on_terrain(
		session,
		world_position,
		RoverIntent.from_phrase(phrase),
		store_id,
		terrain,
		tool,
		space_state
	)


static func _place_chassis(helper: AssemblyBuildHelper, intent: RoverIntent) -> bool:
	var width := intent.width_cells()
	var length := intent.length_cells()
	var max_y := 1 if intent.needs_deck_stack() else 0
	for y: int in range(max_y + 1):
		for x: int in range(width):
			for z: int in range(length):
				if x == 0 and y == 0 and z == 0:
					continue
				if not helper.place(
					Slice01Archetypes.rover_frame(),
					Vector3i(x, y, z),
					0,
					"frame_%d_%d_%d" % [x, y, z]
				):
					return false
	return true


static func _place_wheels(helper: AssemblyBuildHelper, intent: RoverIntent) -> bool:
	var width := intent.width_cells()
	var axles := intent.axle_z_cells()
	var axle_index := 0
	for z: int in axles:
		var steerable := axle_index == 0
		for side: int in [-1, 1]:
			var x := -1 if side < 0 else width
			var face := Vector3i.RIGHT if side < 0 else Vector3i.LEFT
			var key := "%s_%d" % ["L" if side < 0 else "R", axle_index]
			var ori := AssemblyBuildHelper.orientation_with_local_face(
				Vector3i.RIGHT,
				face
			)
			if not helper.place(
				Slice01Archetypes.wheel_suspension(),
				Vector3i(x, 0, z),
				ori,
				"suspension_%s" % key
			):
				return false
			if not helper.place(
				Slice01Archetypes.drive_wheel(),
				Vector3i(x, -1, z),
				0,
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


static func _place_modules(helper: AssemblyBuildHelper, intent: RoverIntent) -> bool:
	var width := intent.width_cells()
	var length := intent.length_cells()
	var module_y := intent.module_y()
	var cockpit_z := 0 if intent.cockpit == "front" else maxi(length / 2 - 1, 0)
	var battery_count := intent.battery_count()
	var per_row := maxi(width / 2, 1)
	var battery_rows := maxi(ceili(float(battery_count) / float(per_row)), 1)
	var rear_z := length - 2
	# Keep battery rows clear of cockpit (2-cell deep).
	var min_battery_z := cockpit_z + 2 + (0 if battery_rows <= 1 else 0)
	if rear_z - (battery_rows - 1) * 2 < min_battery_z:
		helper.last_error = "chassis_too_short_for_batteries"
		return false
	if not helper.place(
		Slice01Archetypes.cockpit(),
		Vector3i(0, module_y, cockpit_z),
		0,
		"cockpit"
	):
		return false
	# Center distributor on long sausages so wheels stay in supply_radius_m.
	var distributor_z := clampi(length / 2, cockpit_z + 2, rear_z - battery_rows * 2)
	if distributor_z < cockpit_z + 2:
		distributor_z = cockpit_z + 2
	var distributor_x := 2 if intent.power != "side" else maxi(width - 2, 2)
	if not helper.place(
		Slice01Archetypes.power_distributor_small(),
		Vector3i(distributor_x, module_y, distributor_z),
		0,
		"distributor"
	):
		return false
	for battery_i: int in range(battery_count):
		var key := "battery" if battery_i == 0 else "battery_%d" % (battery_i + 1)
		var row := battery_i / per_row
		var col := battery_i % per_row
		var battery_x := col * 2
		var battery_z := rear_z - row * 2
		if battery_x + 1 >= width or battery_z < cockpit_z + 2:
			helper.last_error = "no_space_for_battery_%d" % battery_i
			return false
		if (
			battery_z <= distributor_z + 1
			and battery_z + 1 >= distributor_z
			and battery_x <= distributor_x + 1
			and battery_x + 1 >= distributor_x
		):
			# Nudge battery row forward of distributor overlap.
			battery_z = distributor_z - 2
			if battery_z < cockpit_z + 2:
				helper.last_error = "battery_distributor_overlap_%d" % battery_i
				return false
		if not helper.place(
			Slice01Archetypes.power_battery_small(),
			Vector3i(battery_x, module_y, battery_z),
			0,
			key
		):
			return false
	return true


static func _wire_power(helper: AssemblyBuildHelper) -> bool:
	var keys: Array[String] = []
	for key: Variant in helper.element_ids.keys():
		var key_str := str(key)
		if key_str == "battery" or key_str.begins_with("battery_"):
			keys.append(key_str)
	keys.sort()
	for key_str: String in keys:
		if int(helper.element_ids.get(key_str, 0)) <= 0:
			continue
		if not helper.connect_ports(key_str, "power_out", "distributor", "power_in"):
			return false
	return true


static func _charge_batteries(world: SimulationWorld, element_ids: Dictionary) -> void:
	for key: Variant in element_ids.keys():
		var key_str := str(key)
		if key_str != "battery" and not key_str.begins_with("battery_"):
			continue
		_charge_battery(world, int(element_ids.get(key_str, 0)))


static func _charge_battery(world: SimulationWorld, battery_element_id: int) -> void:
	if battery_element_id <= 0:
		return
	var element := world.get_element(battery_element_id)
	if element == null:
		return
	var runtime := world.ensure_industry_element_runtime(battery_element_id)
	runtime.battery_kwh = IndustryElectricProfile.battery_max_kwh(element)


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
