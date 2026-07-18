class_name RoverDemoSpawn
extends RefCounted

const STORE_ID := "player"
const SKY_PROBE_Y := 120.0
const GROUND_PROBE_MAX_DISTANCE := 200.0
const FLAT_SEARCH_RADIUS_M := 24.0
const FLAT_SEARCH_STEP_M := 3.0
const FLAT_SAMPLE_SPAN_M := 2.5
const MAX_FLAT_SLOPE_M := 0.35


static func find_flat_ground_near(
	terrain: Node3D,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D,
	center_hint: Vector3,
	search_radius_m: float = FLAT_SEARCH_RADIUS_M,
	step_m: float = FLAT_SEARCH_STEP_M,
	stop_on_first: bool = false
) -> Variant:
	if terrain == null or tool == null or space_state == null:
		return null
	var field := GravityField.find_in_tree(terrain)
	var search_center := _search_center_hint(center_hint, field)
	var frame: Basis = (
		field.tangent_basis_at(search_center)
		if field != null
		else Basis.IDENTITY
	)
	var best_ground: Vector3 = Vector3.ZERO
	var best_slope := INF
	var best_dist_sq := INF
	var steps := maxi(int(ceil(search_radius_m / step_m)), 1)
	for ix: int in range(-steps, steps + 1):
		for iz: int in range(-steps, steps + 1):
			var offset := (
				frame.x * (float(ix) * step_m)
				+ frame.z * (float(iz) * step_m)
			)
			if offset.length() > search_radius_m + 0.001:
				continue
			var hint := search_center + offset
			var ground_variant: Variant = _ground_point_along_field(
				terrain,
				tool,
				space_state,
				hint
			)
			if not ground_variant is Vector3:
				continue
			var ground: Vector3 = ground_variant
			var slope := _local_slope_m(
				terrain,
				tool,
				space_state,
				ground,
				FLAT_SAMPLE_SPAN_M
			)
			if slope > MAX_FLAT_SLOPE_M:
				continue
			if stop_on_first:
				return ground
			var dist_sq := offset.length_squared()
			if slope < best_slope - 0.001 or (
				is_equal_approx(slope, best_slope)
				and dist_sq < best_dist_sq
			):
				best_slope = slope
				best_dist_sq = dist_sq
				best_ground = ground
	if best_slope >= INF:
		return null
	return best_ground


static func _search_center_hint(
	center_hint: Vector3,
	field: GravityField
) -> Vector3:
	if field != null and field.mode == GravityField.Mode.RADIAL:
		var hint := center_hint
		if hint.length_squared() <= 0.000001:
			hint = Vector3.UP
		return MoonGeometry.surface_point(hint)
	return Vector3(center_hint.x, 0.0, center_hint.z)


static func spawn_on_terrain(
	session: SimulationSession,
	world_position: Vector3,
	store_id: String = STORE_ID,
	terrain: Node3D = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	if session == null or session.world == null:
		return {"ok": false, "error": "no_session"}
	var world := session.world
	world.ensure_resource_store(store_id)
	for item_id: String in [
		"plate_metal",
		"girder",
		"mechanism",
		"conduit",
		"plate_basalt",
		"sintered_basalt",
		"plate_alloy",
	]:
		world.set_resource_amount(store_id, item_id, 500.0)
	var assembly_transform := _assembly_transform_on_surface(
		world_position,
		Basis.IDENTITY,
		terrain,
		tool,
		space_state
	)
	var grid_frame := GridSpawnUtil.grid_frame_from_transform(assembly_transform)
	world.begin_structural_batch()
	var assembly_id := _spawn_anchor(world, grid_frame, store_id)
	if assembly_id <= 0:
		world.end_structural_batch()
		return {"ok": false, "error": "anchor_failed"}
	var revision := _assembly_revision(world, assembly_id)
	var module_ids: Dictionary = {}
	revision = _place_deck_frames(world, assembly_id, revision, store_id)
	var pairs := [
		{
			"suspension_cell": Vector3i(-1, 0, -2),
			"suspension_face": Vector3i.RIGHT,
			"wheel_cell": Vector3i(-1, -1, -2),
			"steerable": true,
			"key": "fl",
		},
		{
			"suspension_cell": Vector3i(3, 0, -2),
			"suspension_face": Vector3i.LEFT,
			"wheel_cell": Vector3i(3, -1, -2),
			"steerable": true,
			"key": "fr",
		},
		{
			"suspension_cell": Vector3i(-1, 0, 3),
			"suspension_face": Vector3i.RIGHT,
			"wheel_cell": Vector3i(-1, -1, 3),
			"steerable": false,
			"key": "rl",
		},
		{
			"suspension_cell": Vector3i(3, 0, 3),
			"suspension_face": Vector3i.LEFT,
			"wheel_cell": Vector3i(3, -1, 3),
			"steerable": false,
			"key": "rr",
		},
	]
	for pair: Dictionary in pairs:
		var built := _place_wheel_pair(
			world,
			assembly_id,
			revision,
			store_id,
			pair
		)
		if not bool(built.get("ok", false)):
			world.end_structural_batch()
			return built
		revision = int(built.get("revision", revision))
		module_ids[str(pair["key"])] = built.get("element_ids", {})
	var placed := _place_chassis(world, assembly_id, revision, store_id)
	if not bool(placed.get("ok", false)):
		world.end_structural_batch()
		return placed
	module_ids.merge(placed.get("element_ids", {}))
	_weld_assembly(world, assembly_id)
	_wire_demo_power(world, module_ids)
	_charge_demo_battery(world, int(module_ids.get("battery", 0)))
	_configure_steerable(world, module_ids)
	# Floating on wheels with parking brake; no freeze monolith.
	world.get_locomotion_controller(assembly_id).mark_released_from_anchor()
	var locomotion := world.get_locomotion_controller(assembly_id)
	locomotion.set_parking_brake(true)
	var motion := AssemblyMotionState.from_grid_frame(grid_frame)
	# Keep terrain seating pose; grid snap alone can bury/float the chassis.
	motion.transform.origin = assembly_transform.origin
	motion.transform.basis = assembly_transform.basis
	motion.frozen = false
	motion.sleeping = false
	motion.linear_velocity = Vector3.ZERO
	motion.angular_velocity = Vector3.ZERO
	world.end_structural_batch()
	session.projection.project_assembly_now(assembly_id, motion)
	if session.visuals != null:
		session.visuals.rebuild_assembly(assembly_id)
	if session.piston_visuals != null:
		session.piston_visuals.rebuild_assembly(assembly_id)
	if session.wheel_visuals != null:
		session.wheel_visuals.rebuild_assembly(assembly_id)
	return {
		"ok": true,
		"assembly_id": assembly_id,
		"element_ids": module_ids,
	}


static func assembly_transform_on_surface(
	surface_point: Vector3,
	basis: Basis = Basis.IDENTITY,
	terrain: Node3D = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Transform3D:
	return _assembly_transform_on_surface(
		surface_point,
		basis,
		terrain,
		tool,
		space_state
	)


static func _assembly_transform_on_surface(
	surface_point: Vector3,
	basis: Basis = Basis.IDENTITY,
	terrain: Node3D = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Transform3D:
	var archetype := Slice01Archetypes.rover_frame()
	var contact := GridPoseUtil.ground_contact_local(archetype, 0)
	var suspension := Slice01Archetypes.wheel_suspension()
	var wheel := Slice01Archetypes.drive_wheel()
	var clearance := (
		suspension.suspension_definition.suspension_travel_m
		+ wheel.wheel_definition.radius_m
	)
	var up := GravityField.resolve_up(terrain, surface_point)
	var field := GravityField.find_in_tree(terrain)
	var seated_basis := basis
	if field != null and field.mode == GravityField.Mode.RADIAL:
		if basis.is_equal_approx(Basis.IDENTITY) or basis.y.dot(up) < 0.85:
			seated_basis = field.tangent_basis_at(surface_point)
	var seat_point := _lowest_surface_point_near(
		surface_point,
		terrain,
		tool,
		space_state
	)
	return Transform3D(
		seated_basis,
		seat_point - seated_basis * contact + seated_basis.y.normalized() * clearance
	)


static func _lowest_surface_y_near(
	center: Vector3,
	terrain: Node3D,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D
) -> float:
	return _lowest_surface_point_near(
		center,
		terrain,
		tool,
		space_state
	).dot(GravityField.resolve_up(terrain, center))


static func _lowest_surface_point_near(
	center: Vector3,
	terrain: Node3D,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D
) -> Vector3:
	var half := FLAT_SAMPLE_SPAN_M * 0.5
	var up := GravityField.resolve_up(terrain, center)
	var field := GravityField.find_in_tree(terrain)
	var frame: Basis = (
		field.tangent_basis_at(center)
		if field != null
		else Basis.IDENTITY
	)
	var offsets: Array[Vector2] = [
		Vector2(0.0, 0.0),
		Vector2(-half, -half),
		Vector2(half, -half),
		Vector2(-half, half),
		Vector2(half, half),
	]
	var lowest := center
	var lowest_height := center.dot(up)
	var found := false
	for offset: Vector2 in offsets:
		var hint := center + frame.x * offset.x + frame.z * offset.y
		var ground_variant: Variant = null
		if space_state != null and terrain != null and tool != null:
			ground_variant = _ground_point_along_field(
				terrain,
				tool,
				space_state,
				hint
			)
		if ground_variant is Vector3:
			var ground: Vector3 = ground_variant
			var height := ground.dot(up)
			if not found or height < lowest_height:
				lowest_height = height
				lowest = ground
				found = true
	return lowest if found else center


## After load: re-seat released locomotives to physics ground under the footprint.
static func reseat_parked_locomotives(
	session: SimulationSession,
	terrain: Node3D,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D
) -> void:
	if (
		session == null
		or session.world == null
		or session.projection == null
		or terrain == null
		or tool == null
		or space_state == null
	):
		return
	var world := session.world
	var archetype := Slice01Archetypes.rover_frame()
	var contact := GridPoseUtil.ground_contact_local(archetype, 0)
	var suspension := Slice01Archetypes.wheel_suspension()
	var wheel := Slice01Archetypes.drive_wheel()
	var clearance := (
		suspension.suspension_definition.suspension_travel_m
		+ wheel.wheel_definition.radius_m
	)
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly == null or assembly.tombstoned:
			continue
		if not WheelSimulationService.is_locomotive_assembly(
			world,
			assembly.assembly_id
		):
			continue
		var locomotion := world.get_locomotion_controller(assembly.assembly_id)
		if (
			not locomotion.has_released_from_anchor()
			and world.assembly_has_anchor(assembly.assembly_id)
		):
			continue
		if not locomotion.has_released_from_anchor():
			locomotion.mark_released_from_anchor()
		var motion := assembly.motion.duplicate_state()
		var origin := motion.transform.origin
		var up := GravityField.resolve_up(terrain, origin)
		var seat_point := _lowest_surface_point_near(
			origin,
			terrain,
			tool,
			space_state
		)
		var basis := motion.transform.basis
		var field := GravityField.find_in_tree(terrain)
		if field != null and field.mode == GravityField.Mode.RADIAL:
			if basis.y.normalized().dot(up) < 0.85:
				basis = field.tangent_basis_at(seat_point)
		var desired := (
			seat_point
			- basis * contact
			+ basis.y.normalized() * clearance
		)
		var delta := desired - origin
		if delta.length() < 0.02 and not motion.frozen:
			continue
		motion.transform.basis = basis
		motion.transform.origin = desired
		motion.frozen = false
		motion.sleeping = false
		motion.linear_velocity = Vector3.ZERO
		motion.angular_velocity = Vector3.ZERO
		locomotion.set_parking_brake(true)
		session.projection.project_assembly_now(assembly.assembly_id, motion)


static func _ground_point_at_xz(
	terrain: Node3D,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D,
	xz: Vector2
) -> Variant:
	return _ground_point_along_field(
		terrain,
		tool,
		space_state,
		Vector3(xz.x, 0.0, xz.y)
	)


static func _ground_point_along_field(
	terrain: Node3D,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D,
	hint: Vector3
) -> Variant:
	var up := GravityField.resolve_up(terrain, hint)
	var down := -up
	var field := GravityField.find_in_tree(terrain)
	var origin: Vector3
	if field != null and field.mode == GravityField.Mode.RADIAL:
		var radial_hint := hint
		if radial_hint.length_squared() <= 0.000001:
			radial_hint = Vector3.UP
		origin = (
			radial_hint.normalized()
			* (MoonGeometry.SURFACE_RADIUS_M + MoonGeometry.SPAWN_SKY_OFFSET_M)
		)
		up = field.up_at(origin)
		down = -up
	else:
		origin = Vector3(hint.x, SKY_PROBE_Y, hint.z)
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		terrain,
		origin,
		down,
		GROUND_PROBE_MAX_DISTANCE
	)
	if hit == null:
		return null
	var sdf_point := VoxelSpaceUtil.raycast_hit_world_point(
		terrain,
		origin,
		down,
		hit
	)
	return VoxelSpaceUtil.resolve_ground_surface_along_ray(
		space_state,
		origin,
		down,
		sdf_point,
		GROUND_PROBE_MAX_DISTANCE
	)


static func _local_slope_m(
	terrain: Node3D,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D,
	center: Vector3,
	sample_span_m: float
) -> float:
	var up := GravityField.resolve_up(terrain, center)
	var field := GravityField.find_in_tree(terrain)
	var frame: Basis = (
		field.tangent_basis_at(center)
		if field != null
		else Basis.IDENTITY
	)
	var max_delta := 0.0
	var center_height := center.dot(up)
	for offset: Vector2 in [
		Vector2(1.0, 0.0),
		Vector2(-1.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(0.0, -1.0),
	]:
		var hint := (
			center
			+ frame.x * (offset.x * sample_span_m)
			+ frame.z * (offset.y * sample_span_m)
		)
		var neighbor_variant: Variant = _ground_point_along_field(
			terrain,
			tool,
			space_state,
			hint
		)
		if not neighbor_variant is Vector3:
			return INF
		max_delta = maxf(
			max_delta,
			absf((neighbor_variant as Vector3).dot(up) - center_height)
		)
	return max_delta


static func _wake_locomotive_body(
	session: SimulationSession,
	assembly_id: int
) -> void:
	if (
		session == null
		or session.world == null
		or session.projection == null
		or assembly_id <= 0
	):
		return
	if not WheelSimulationService.is_locomotive_assembly(
		session.world,
		assembly_id
	):
		push_warning("RoverDemoSpawn: assembly %d is not locomotive" % assembly_id)
		return
	var body := session.projection.get_physics_body(assembly_id)
	if body is StaticBody3D:
		var assembly := session.world.get_assembly_raw(assembly_id)
		if assembly != null:
			var motion := assembly.motion.duplicate_state()
			motion.frozen = false
			motion.sleeping = false
			session.projection.project_assembly_now(assembly_id, motion)
			body = session.projection.get_physics_body(assembly_id)
	if body is RigidBody3D:
		var rigid := body as RigidBody3D
		rigid.freeze = false
		rigid.sleeping = false
		rigid.linear_velocity = Vector3.ZERO
		rigid.angular_velocity = Vector3.ZERO


static func _spawn_anchor(
	world: SimulationWorld,
	grid_frame: GridTransform,
	store_id: String
) -> int:
	var place := PlaceElementCommand.new()
	place.assembly_id = 0
	place.origin_cell = Vector3i.ZERO
	place.orientation_index = 0
	place.archetype = Slice01Archetypes.rover_frame()
	place.new_assembly_grid_frame = grid_frame
	place.initial_motion = AssemblyMotionState.from_grid_frame(grid_frame)
	place.store_id = store_id
	var result := world.apply_structural_command_now(place)
	if not result.is_ok():
		return 0
	return int(result.data.get("assembly_id", 0))


static func _place_deck_frames(
	world: SimulationWorld,
	assembly_id: int,
	revision: int,
	store_id: String
) -> int:
	var deck_cells: Array[Vector3i] = []
	for z: int in [0, -1, -2, 1, 2, 3]:
		deck_cells.append(Vector3i(1, 0, z))
		if z in [-2, 0, 1, 3]:
			if z != 0:
				deck_cells.append(Vector3i(0, 0, z))
			deck_cells.append(Vector3i(2, 0, z))
	for cell: Vector3i in deck_cells:
		var placed := _place(
			world,
			assembly_id,
			revision,
			Slice01Archetypes.rover_frame(),
			cell,
			0,
			store_id
		)
		if not placed.is_ok():
			push_warning(
				"RoverDemoSpawn: deck frame %s failed: %s" % [cell, placed.reason]
			)
			continue
		revision = int(placed.data["topology_revision"])
	return revision


static func _place_chassis(
	world: SimulationWorld,
	assembly_id: int,
	revision: int,
	store_id: String
) -> Dictionary:
	var element_ids := {"center": 0}
	var cockpit := _place(
		world,
		assembly_id,
		revision,
		Slice01Archetypes.cockpit(),
		Vector3i(0, 1, 0),
		0,
		store_id
	)
	if not cockpit.is_ok():
		return {"ok": false, "error": "cockpit: %s" % cockpit.reason}
	revision = int(cockpit.data["topology_revision"])
	element_ids["cockpit"] = int(cockpit.data["element_id"])
	var battery := _place(
		world,
		assembly_id,
		revision,
		Slice01Archetypes.power_battery_small(),
		Vector3i(0, 1, 2),
		0,
		store_id
	)
	if not battery.is_ok():
		return {"ok": false, "error": "battery: %s" % battery.reason}
	revision = int(battery.data["topology_revision"])
	element_ids["battery"] = int(battery.data["element_id"])
	var distributor := _place(
		world,
		assembly_id,
		revision,
		Slice01Archetypes.power_distributor_small(),
		Vector3i(1, 1, -2),
		0,
		store_id
	)
	if not distributor.is_ok():
		return {"ok": false, "error": "distributor: %s" % distributor.reason}
	revision = int(distributor.data["topology_revision"])
	element_ids["distributor"] = int(distributor.data["element_id"])
	return {
		"ok": true,
		"revision": revision,
		"element_ids": element_ids,
	}


static func _place_wheel_pair(
	world: SimulationWorld,
	assembly_id: int,
	revision: int,
	store_id: String,
	spec: Dictionary
) -> Dictionary:
	var suspension_orientation := _orientation_with_local_face(
		Vector3i.RIGHT,
		spec["suspension_face"]
	)
	var suspension := _place(
		world,
		assembly_id,
		revision,
		Slice01Archetypes.wheel_suspension(),
		spec["suspension_cell"],
		suspension_orientation,
		store_id
	)
	if not suspension.is_ok():
		return {"ok": false, "error": "suspension: %s" % suspension.reason}
	revision = int(suspension.data["topology_revision"])
	var wheel := _place(
		world,
		assembly_id,
		revision,
		Slice01Archetypes.drive_wheel(),
		spec["wheel_cell"],
		0,
		store_id
	)
	if not wheel.is_ok():
		return {"ok": false, "error": "wheel: %s" % wheel.reason}
	revision = int(wheel.data["topology_revision"])
	return {
		"ok": true,
		"revision": revision,
		"element_ids": {
			"suspension": int(suspension.data["element_id"]),
			"wheel": int(wheel.data["element_id"]),
			"steerable": bool(spec.get("steerable", false)),
		},
	}


static func _wire_demo_power(
	world: SimulationWorld,
	element_ids: Dictionary
) -> void:
	var battery_id := int(element_ids.get("battery", 0))
	var distributor_id := int(element_ids.get("distributor", 0))
	if battery_id <= 0 or distributor_id <= 0:
		return
	var result := world.connect_network(
		battery_id,
		"power_out",
		distributor_id,
		"power_in"
	)
	if not result.is_ok():
		push_warning(
			"RoverDemoSpawn: battery→distributor wire failed: %s"
			% result.reason
		)


static func _charge_demo_battery(
	world: SimulationWorld,
	battery_element_id: int
) -> void:
	IndustryElectricBudget.mark_battery_charged(world, battery_element_id)


static func _configure_steerable(
	world: SimulationWorld,
	module_ids: Dictionary
) -> void:
	for key: String in ["fl", "fr"]:
		var pair_variant: Variant = module_ids.get(key, {})
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


static func _weld_assembly(world: SimulationWorld, assembly_id: int) -> void:
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null:
			continue
		var weld := WeldElementCommand.new()
		weld.element_id = element_id
		weld.expected_state_revision = element.state_revision
		weld.max_material_amount = 100.0
		weld.store_id = STORE_ID
		world.apply_structural_command_now(weld)


static func _place(
	world: SimulationWorld,
	assembly_id: int,
	revision: int,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int,
	store_id: String
) -> StructuralCommandResult:
	var place := PlaceElementCommand.new()
	place.assembly_id = assembly_id
	place.expected_assembly_revision = revision
	place.archetype = archetype
	place.origin_cell = origin_cell
	place.orientation_index = orientation_index
	place.store_id = store_id
	return world.apply_structural_command_now(place)


static func _assembly_revision(world: SimulationWorld, assembly_id: int) -> int:
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return 0
	return assembly.topology_revision


static func _orientation_with_local_face(
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
