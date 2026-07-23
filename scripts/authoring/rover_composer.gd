class_name RoverComposer
extends RefCounted

## Deterministic rover build from RoverIntent. Agent never picks cells.


static func compose(
	world: SimulationWorld,
	intent: RoverIntent,
	grid_frame: GridTransform = GridTransform.identity(),
	store_id: String = PlayerIdentity.local_store_id()
) -> Dictionary:
	if world == null:
		return {"ok": false, "error": "no_world"}
	if intent == null:
		intent = RoverIntent.defaults()
	var unsupported := intent.unsupported_reason()
	if not unsupported.is_empty():
		return {"ok": false, "error": unsupported}
	## One physics/visual rebuild at spawn end — not per PlaceElement.
	world.begin_structural_batch()
	var result := _compose_batched(world, intent, grid_frame, store_id)
	world.end_structural_batch()
	return result


static func _compose_batched(
	world: SimulationWorld,
	intent: RoverIntent,
	grid_frame: GridTransform,
	store_id: String
) -> Dictionary:
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		world.get_archetype_registry().register(archetype)
	# Пара из интента может быть испечённой визардом — её в ROVER_IDS нет.
	for archetype: ElementArchetype in [
		intent.suspension_archetype(),
		intent.wheel_archetype(),
		Slice01Archetypes.frame(),
		Slice01Archetypes.frame_basalt(),
		Slice01Archetypes.frame_beam(),
		Slice01Archetypes.cargo_pipe(),
	]:
		if archetype != null:
			world.get_archetype_registry().register(archetype)
	var helper := AssemblyBuildHelper.new(world, store_id)
	helper.ensure_materials(800.0)
	if not helper.spawn_anchor(Slice01Archetypes.frame(), grid_frame):
		return {"ok": false, "error": helper.last_error}
	if not _place_chassis(helper, intent):
		return {"ok": false, "error": helper.last_error}
	if not _place_wheels(helper, intent):
		return {"ok": false, "error": helper.last_error}
	if not _place_modules(helper, intent):
		return {"ok": false, "error": helper.last_error}
	if not _place_decor(helper, intent):
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
	store_id: String = PlayerIdentity.local_store_id()
) -> Dictionary:
	return compose(world, RoverIntent.from_phrase(phrase), grid_frame, store_id)


## Spawn a composed rover seated on terrain (game / session path).
static func spawn_on_terrain(
	session: SimulationSession,
	world_position: Vector3,
	intent: RoverIntent = null,
	store_id: String = PlayerIdentity.local_store_id(),
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
	# Full seated pose — origin.y alone buries the chassis on radial gravity
	# (grid snap keeps XZ while terrain seating is along local up).
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


static func spawn_on_terrain_from_phrase(
	session: SimulationSession,
	world_position: Vector3,
	phrase: String,
	store_id: String = PlayerIdentity.local_store_id(),
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


## Cosmetic 0.5 m Frame blocks: bumpers, side skirts, short sensor mast.
## No new archetypes — only frame / frame_basalt / cargo_pipe.
static func _place_decor(helper: AssemblyBuildHelper, intent: RoverIntent) -> bool:
	var width := intent.width_cells()
	var length := intent.length_cells()
	var axle_set: Dictionary = {}
	for z: int in intent.axle_z_cells():
		axle_set[z] = true
	var basalt := Slice01Archetypes.frame_basalt()
	var frame := Slice01Archetypes.frame()
	var pipe := Slice01Archetypes.cargo_pipe()
	if basalt == null or frame == null or pipe == null:
		helper.last_error = "missing_decor_archetypes"
		return false
	# Front / rear bumpers (basalt contrasts metal deck).
	for x: int in range(width):
		if not helper.place(basalt, Vector3i(x, 0, -1), 0, "bumper_f_%d" % x):
			return false
		if not helper.place(basalt, Vector3i(x, 0, length), 0, "bumper_r_%d" % x):
			return false
	# Side skirts between axles — skip axle Z (suspension owns that bay).
	for z: int in range(length):
		if axle_set.has(z):
			continue
		if not helper.place(basalt, Vector3i(-1, 0, z), 0, "skirt_L_%d" % z):
			return false
		if not helper.place(basalt, Vector3i(width, 0, z), 0, "skirt_R_%d" % z):
			return false
	# Starboard-forward mast on the free outboard column (cockpit is x=0..2).
	if width >= 4 and length >= 5:
		var mast_x := width - 1
		var mast_z := 1
		if not helper.place(frame, Vector3i(mast_x, 1, mast_z), 0, "mast_base"):
			return false
		if not helper.place(frame, Vector3i(mast_x, 2, mast_z), 0, "mast_mid"):
			return false
		if not helper.place(pipe, Vector3i(mast_x, 3, mast_z), 0, "mast_tip"):
			return false
	return true


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
					Slice01Archetypes.frame(),
					Vector3i(x, y, z),
					0,
					"frame_%d_%d_%d" % [x, y, z]
				):
					return false
	return true


static func _place_wheels(helper: AssemblyBuildHelper, intent: RoverIntent) -> bool:
	var suspension := intent.suspension_archetype()
	var wheel := intent.wheel_archetype()
	if suspension == null or wheel == null:
		helper.last_error = "unknown_wheel_archetypes"
		return false
	var width := intent.width_cells()
	var axles := intent.axle_z_cells()
	var axle_index := 0
	for z: int in axles:
		var steerable := axle_index == 0
		for side: int in [-1, 1]:
			var x := -1 if side < 0 else width
			var face := Vector3i.RIGHT if side < 0 else Vector3i.LEFT
			var key := "%s_%d" % ["L" if side < 0 else "R", axle_index]
			# Крепимся к БОРТОВОЙ клетке шасси наружу — ровно так же, как игрок
			# наводится на её грань. Клетку самой стойки не выбираем: её считает
			# тот же снап, что и в превью.
			var chassis_cell := Vector3i(x, 0, z) + face
			var plan := _plan_wheel_pair(
				suspension,
				wheel,
				chassis_cell,
				-face
			)
			if plan.is_empty():
				helper.last_error = "no_wheel_pair_pose:%s+%s" % [
					suspension.archetype_id,
					wheel.archetype_id,
				]
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


## Куда и как повёрнутыми встают стойка и колесо. Ничего не зашито: берём
## площадки самих деталей — «сюда крепится рама», «сюда встаёт колесо», «этой
## гранью колесо садится на стойку» — и считаем позы из них. Стоковая пара
## получается ровно там же, где стояла раньше, а испечённая визардом деталь с
## боковым гнездом встаёт как ей положено, а не «на клетку ниже».
##
## `chassis_cell` — клетка шасси, к грани которой крепимся; `outward` — наружу
## от шасси. Пусто, если для такой пары позы не существует.
static func _plan_wheel_pair(
	suspension: ElementArchetype,
	wheel: ElementArchetype,
	chassis_cell: Vector3i,
	outward: Vector3i
) -> Dictionary:
	var frame_pad := _pad_with_tag(suspension, "")
	var socket_pad := _pad_with_tag(suspension, "wheel_socket")
	var plug_pad := _pad_with_tag(wheel, "wheel_plug")
	if frame_pad == null or socket_pad == null or plug_pad == null:
		return {}

	# Стойку разворачиваем так, чтобы её крепление смотрело на шасси, а ход
	# оставался вертикальным: одного условия мало, у него четыре решения.
	var suspension_orientation := _orientation_for(
		OrientationUtil.face_to_vector(frame_pad.local_face),
		-outward,
		_authored_up_axis(suspension),
		Vector3i.UP
	)
	if suspension_orientation < 0:
		return {}
	# Клетку считает тот же снап, что и превью в игре: точка крепления
	# садится по центру грани, а не «деталь углом к клетке». Для точечных
	# площадок (визард) разница ровно в полклетки по высоте.
	var suspension_origin := GridPoseUtil.snap_origin_for_target_cell(
		suspension,
		chassis_cell,
		outward,
		suspension_orientation
	)
	var socket_direction := OrientationUtil.rotate_direction(
		OrientationUtil.face_to_vector(socket_pad.local_face),
		suspension_orientation
	)
	var socket_cell := (
		suspension_origin
		+ OrientationUtil.rotate_cell(socket_pad.local_cell, suspension_orientation)
	)

	# Колесо садится на гнездо своей площадкой, а ось вращения смотрит вдоль
	# ровера. Ось вперёд/назад равнозначна — за направление отвечает реверс.
	var forward_local := Vector3i.FORWARD
	if wheel.wheel_definition != null:
		forward_local = OrientationUtil.face_to_vector(
			wheel.wheel_definition.forward_axis_face
		)
	var wheel_orientation := -1
	for drive_direction: Vector3i in [Vector3i.FORWARD, Vector3i.BACK]:
		wheel_orientation = _orientation_for(
			OrientationUtil.face_to_vector(plug_pad.local_face),
			-socket_direction,
			forward_local,
			drive_direction
		)
		if wheel_orientation >= 0:
			break
	if wheel_orientation < 0:
		return {}
	return {
		"suspension_origin": suspension_origin,
		"suspension_orientation": suspension_orientation,
		"wheel_origin": GridPoseUtil.snap_origin_for_target_cell(
			wheel,
			socket_cell,
			socket_direction,
			wheel_orientation
		),
		"wheel_orientation": wheel_orientation,
	}


## Ориентация, разворачивающая ОБА локальных направления в мировые, или -1.
## Своя, а не AssemblyBuildHelper.orientation_with_local_faces: та молча
## возвращает 0, когда решения нет, и деталь встаёт куда попало.
static func _orientation_for(
	local_a: Vector3i,
	world_a: Vector3i,
	local_b: Vector3i,
	world_b: Vector3i
) -> int:
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.rotate_direction(local_a, index) != world_a:
			continue
		if OrientationUtil.rotate_direction(local_b, index) == world_b:
			return index
	return -1


## Ось «вверх» детали в её собственных координатах: деталь авторили в позе
## default_orientation_index, значит вверх — то, что этот поворот делает верхом.
static func _authored_up_axis(archetype: ElementArchetype) -> Vector3i:
	var basis := OrientationUtil.orientation_basis(
		archetype.default_orientation_index
	)
	var axis: Vector3 = basis.inverse() * Vector3.UP
	return Vector3i(roundi(axis.x), roundi(axis.y), roundi(axis.z))


static func _pad_with_tag(
	archetype: ElementArchetype,
	socket_tag: String
) -> StructuralMountPad:
	for pad: StructuralMountPad in archetype.structural_mount_pads:
		if pad != null and pad.socket_tag == socket_tag:
			return pad
	return null


static func _place_modules(helper: AssemblyBuildHelper, intent: RoverIntent) -> bool:
	var width := intent.width_cells()
	var length := intent.length_cells()
	var module_y := intent.module_y()
	var cockpit_z := (
		0 if intent.cockpit == "front" else maxi(int(length / 2.0) - 1, 0)
	)
	var battery_count := intent.battery_count()
	var per_row := maxi(int(width / 2.0), 1)
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
	var distributor_z := clampi(
		int(length / 2.0), cockpit_z + 2, rear_z - battery_rows * 2
	)
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
		var row := int(battery_i / float(per_row))
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
	IndustryElectricBudget.mark_battery_charged(world, battery_element_id)


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
