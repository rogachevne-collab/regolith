class_name RoverDemoSpawn
extends RefCounted

static var STORE_ID: String:
	get:
		return PlayerIdentity.local_store_id()
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
	var clearance := Slice01Archetypes.rover_wheel_clearance_m()
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
	var clearance := Slice01Archetypes.rover_wheel_clearance_m()
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
		rigid.linear_velocity = Vector3.ZERO
		rigid.angular_velocity = Vector3.ZERO
		# Wheel bodies included — a root-only wake leaves them frozen.
		session.projection.wake_assembly_bodies(assembly_id)
