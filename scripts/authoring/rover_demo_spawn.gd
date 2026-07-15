class_name RoverDemoSpawn
extends RefCounted

const STORE_ID := "player"
const SKY_PROBE_Y := 120.0
const GROUND_PROBE_MAX_DISTANCE := 200.0
const PARK_CLEARANCE_M := 0.03
const DEFAULT_WHEEL_RADIUS_M := 0.4
const FLAT_SEARCH_RADIUS_M := 24.0
const FLAT_SEARCH_STEP_M := 3.0
const FLAT_SAMPLE_SPAN_M := 2.5
const MAX_FLAT_SLOPE_M := 0.35


static func find_flat_ground_near(
	terrain: VoxelTerrain,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D,
	center_xz: Vector2,
	search_radius_m: float = FLAT_SEARCH_RADIUS_M,
	step_m: float = FLAT_SEARCH_STEP_M
) -> Variant:
	if terrain == null or tool == null or space_state == null:
		return null
	var best_ground: Vector3 = Vector3.ZERO
	var best_slope := INF
	var best_dist_sq := INF
	var steps := maxi(int(ceil(search_radius_m / step_m)), 1)
	for ix: int in range(-steps, steps + 1):
		for iz: int in range(-steps, steps + 1):
			var xz := center_xz + Vector2(
				float(ix) * step_m,
				float(iz) * step_m
			)
			if xz.distance_to(center_xz) > search_radius_m + 0.001:
				continue
			var ground_variant: Variant = _ground_point_at_xz(
				terrain,
				tool,
				space_state,
				xz
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
			var dist_sq := xz.distance_squared_to(center_xz)
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


static func spawn_on_terrain(
	session: SimulationSession,
	world_position: Vector3,
	store_id: String = STORE_ID,
	terrain: VoxelTerrain = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	if session == null or session.world == null:
		return {"ok": false, "error": "no_session"}
	var world := session.world
	world.ensure_resource_store(store_id)
	world.set_resource_amount(store_id, "construction_component", 500.0)
	var assembly_transform := _assembly_transform_on_surface(
		world_position,
		Basis.IDENTITY,
		terrain,
		tool,
		space_state
	)
	var grid_frame := GridSpawnUtil.grid_frame_from_transform(assembly_transform)
	var assembly_id := _spawn_anchor(world, grid_frame, store_id)
	if assembly_id <= 0:
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
			return built
		revision = int(built.get("revision", revision))
		module_ids[str(pair["key"])] = built.get("element_ids", {})
	var placed := _place_chassis(world, assembly_id, revision, store_id)
	if not bool(placed.get("ok", false)):
		return placed
	module_ids.merge(placed.get("element_ids", {}))
	_weld_assembly(world, assembly_id)
	_wire_demo_power(world, module_ids)
	_charge_demo_battery(world, int(module_ids.get("battery", 0)))
	_configure_steerable(world, module_ids)
	# Parked at spawn: expand while !activated; ControlSeat activates drive.
	world.get_locomotion_controller(assembly_id).mark_released_from_anchor()
	var motion := AssemblyMotionState.from_grid_frame(grid_frame)
	# Keep terrain seating Y; grid snap alone can bury/float the chassis ±0.25 m.
	motion.transform.origin.y = assembly_transform.origin.y
	motion.frozen = true
	motion.sleeping = true
	motion.linear_velocity = Vector3.ZERO
	motion.angular_velocity = Vector3.ZERO
	session.projection.project_assembly_now(assembly_id, motion)
	_seat_by_wheel_sockets(
		session,
		assembly_id,
		terrain,
		tool,
		space_state
	)
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


static func _assembly_transform_on_surface(
	surface_point: Vector3,
	basis: Basis = Basis.IDENTITY,
	terrain: VoxelTerrain = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Transform3D:
	# Provisional pose only — final Y comes from _seat_by_wheel_sockets after
	# the wheel pairs exist. Old travel+radius clearance floated the chassis
	# then looked like a sink/clip once visuals raycast to ground.
	var archetype := Slice01Archetypes.rover_frame()
	var contact := GridPoseUtil.ground_contact_local(archetype, 0)
	var wheel := Slice01Archetypes.drive_wheel()
	var provisional_clearance := wheel.wheel_definition.radius_m + 0.15
	var seat_y := _lowest_surface_y_near(
		surface_point,
		terrain,
		tool,
		space_state
	)
	var seated_point := Vector3(surface_point.x, seat_y, surface_point.z)
	return Transform3D(
		basis,
		seated_point - basis * contact + basis.y.normalized() * provisional_clearance
	)


## Parked ride height: match STATIC wheel visuals (no suspension tick yet).
## Socket+travel math buried tires because parked meshes sit on grid pivots.
static func _seat_by_wheel_sockets(
	session: SimulationSession,
	assembly_id: int,
	terrain: VoxelTerrain = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> void:
	if session == null or session.world == null or session.projection == null:
		return
	if assembly_id <= 0:
		return
	var world := session.world
	var assembly := world.get_assembly_raw(assembly_id)
	var body := session.projection.get_physics_body(assembly_id) as PhysicsBody3D
	if assembly == null or body == null:
		return
	if space_state == null and body.is_inside_tree():
		space_state = body.get_world_3d().direct_space_state
	if space_state == null:
		return
	var body_xf := body.global_transform
	var delta_y := -INF
	var found := false
	for pair: Dictionary in WheelSimulationService.discover_pairs(world, assembly_id):
		if not WheelSimulationService.is_complete_pair(pair):
			continue
		var wheel_element: SimulationElement = pair.get("wheel_element")
		if wheel_element == null:
			continue
		var wheel_archetype := wheel_element.get_archetype()
		if wheel_archetype == null:
			continue
		var radius_m := DEFAULT_WHEEL_RADIUS_M
		if wheel_archetype.wheel_definition != null:
			radius_m = wheel_archetype.wheel_definition.radius_m
		var pivot_local := GridPoseUtil.oriented_footprint_pivot(
			wheel_archetype,
			wheel_element.origin_cell,
			wheel_element.orientation_index
		)
		var pivot_world: Vector3 = body_xf * pivot_local
		var surface_variant: Variant = null
		if terrain != null and tool != null:
			surface_variant = _ground_point_at_xz(
				terrain,
				tool,
				space_state,
				Vector2(pivot_world.x, pivot_world.z)
			)
		if not surface_variant is Vector3:
			var physics_y := VoxelSpaceUtil.physics_down_surface_y(
				space_state,
				Vector2(pivot_world.x, pivot_world.z),
				pivot_world.y + 2.0,
				12.0
			)
			if is_finite(physics_y):
				surface_variant = Vector3(pivot_world.x, physics_y, pivot_world.z)
		if not surface_variant is Vector3:
			continue
		var surface: Vector3 = surface_variant
		# Tire mesh radius hangs below the visual pivot (cylinder on SteerRoot).
		var bottom_y := pivot_world.y - radius_m
		var needed := (surface.y + PARK_CLEARANCE_M) - bottom_y
		if not found or needed > delta_y:
			delta_y = needed
			found = true
	if not found:
		return
	if absf(delta_y) >= 0.01:
		var motion := assembly.motion.duplicate_state()
		motion.transform.origin.y += delta_y
		motion.frozen = true
		motion.sleeping = true
		motion.linear_velocity = Vector3.ZERO
		motion.angular_velocity = Vector3.ZERO
		session.projection.project_assembly_now(assembly_id, motion)
		body = session.projection.get_physics_body(assembly_id) as PhysicsBody3D
		if body == null:
			return
		body_xf = body.global_transform
	_seed_parked_wheel_runtime(world, assembly_id, body, body_xf, space_state)


static func _seed_parked_wheel_runtime(
	world: SimulationWorld,
	assembly_id: int,
	body: PhysicsBody3D,
	body_xf: Transform3D,
	space_state: PhysicsDirectSpaceState3D
) -> void:
	if world == null or body == null or space_state == null:
		return
	for pair: Dictionary in WheelSimulationService.discover_pairs(world, assembly_id):
		if not WheelSimulationService.is_complete_pair(pair):
			continue
		var suspension: SimulationElement = pair.get("suspension_element")
		var wheel_element: SimulationElement = pair.get("wheel_element")
		if suspension == null or wheel_element == null:
			continue
		var socket := WheelProjectionUtil.mount_pad_anchor_assembly_local(
			suspension,
			"wheel_socket"
		)
		if socket.is_empty():
			continue
		var travel_m := 0.6
		var sus_def := suspension.get_archetype().suspension_definition
		if sus_def != null:
			travel_m = sus_def.suspension_travel_m
		var state := world.ensure_suspension_instance_state(suspension.element_id)
		if state.travel_m > 0.0:
			travel_m = state.travel_m
		var radius_m := DEFAULT_WHEEL_RADIUS_M
		var wheel_def := wheel_element.get_archetype().wheel_definition
		if wheel_def != null:
			radius_m = wheel_def.radius_m
		var ray_origin: Vector3 = body_xf * Vector3(socket["origin"])
		var ray_dir := (
			body_xf.basis * Vector3(socket["direction"])
		).normalized()
		if ray_dir.length_squared() <= 0.0001:
			continue
		var query := PhysicsRayQueryParameters3D.create(
			ray_origin,
			ray_origin + ray_dir * (travel_m + radius_m)
		)
		query.collision_mask = WheelProjectionUtil.RAYCAST_MASK
		query.exclude = [body.get_rid()]
		var hit := space_state.intersect_ray(query)
		var suspension_length := travel_m
		if not hit.is_empty():
			var distance := ray_origin.distance_to(hit["position"])
			suspension_length = clampf(distance - radius_m, 0.0, travel_m)
		var wheel_center_world := ray_origin + ray_dir * suspension_length
		world.store_wheel_runtime(wheel_element.element_id, suspension.element_id, {
			"wheel_center_body_local": body.to_local(wheel_center_world),
			"suspension_length_m": suspension_length,
			"compression_m": travel_m - suspension_length,
			"steering_angle_rad": 0.0,
			"wheel_speed": 0.0,
			"grounded": not hit.is_empty(),
			"status": &"parked",
		})


static func _lowest_surface_y_near(
	center: Vector3,
	terrain: VoxelTerrain,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D
) -> float:
	var half := FLAT_SAMPLE_SPAN_M * 0.5
	var offsets: Array[Vector2] = [
		Vector2(0.0, 0.0),
		Vector2(-half, -half),
		Vector2(half, -half),
		Vector2(-half, half),
		Vector2(half, half),
	]
	var lowest := center.y
	var found := false
	for offset: Vector2 in offsets:
		var xz := Vector2(center.x + offset.x, center.z + offset.y)
		var ground_variant: Variant = null
		if space_state != null and terrain != null and tool != null:
			ground_variant = _ground_point_at_xz(
				terrain,
				tool,
				space_state,
				xz
			)
		if ground_variant is Vector3:
			var ground: Vector3 = ground_variant
			if not found or ground.y < lowest:
				lowest = ground.y
				found = true
	return lowest if found else center.y


## After load: re-seat released locomotives by wheel sockets on physics ground.
static func reseat_parked_locomotives(
	session: SimulationSession,
	terrain: VoxelTerrain,
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
		_seat_by_wheel_sockets(
			session,
			assembly.assembly_id,
			terrain,
			tool,
			space_state
		)


static func _ground_point_at_xz(
	terrain: VoxelTerrain,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D,
	xz: Vector2
) -> Variant:
	var origin := Vector3(xz.x, SKY_PROBE_Y, xz.y)
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		terrain,
		origin,
		Vector3.DOWN,
		GROUND_PROBE_MAX_DISTANCE
	)
	if hit == null:
		return null
	var sdf_y := (
		origin.y
		- VoxelSpaceUtil.raycast_hit_world_distance(terrain, hit)
	)
	var surface_y := VoxelSpaceUtil.resolve_ground_surface_y(
		space_state,
		xz,
		sdf_y,
		SKY_PROBE_Y,
		GROUND_PROBE_MAX_DISTANCE
	)
	return Vector3(xz.x, surface_y, xz.y)


static func _local_slope_m(
	terrain: VoxelTerrain,
	tool: VoxelTool,
	space_state: PhysicsDirectSpaceState3D,
	center: Vector3,
	sample_span_m: float
) -> float:
	var max_delta := 0.0
	for offset: Vector2 in [
		Vector2(1.0, 0.0),
		Vector2(-1.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(0.0, -1.0),
	]:
		var neighbor_xz := Vector2(center.x, center.z) + offset * sample_span_m
		var neighbor_variant: Variant = _ground_point_at_xz(
			terrain,
			tool,
			space_state,
			neighbor_xz
		)
		if not neighbor_variant is Vector3:
			return INF
		max_delta = maxf(
			max_delta,
			absf((neighbor_variant as Vector3).y - center.y)
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
	if battery_element_id <= 0:
		return
	var element := world.get_element(battery_element_id)
	if element == null:
		return
	var runtime := world.ensure_industry_element_runtime(battery_element_id)
	runtime.battery_kwh = IndustryElectricProfile.battery_max_kwh(element)


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
