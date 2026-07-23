class_name WheelBodyProjectionUtil
extends RefCounted
## WHEEL-BODY-V1: the wheel is a real RigidBody3D on one Generic6DOFJoint3D to
## its strut. Joint frame: X = axle (free spin, velocity motor), Y = suspension
## travel axis pointing up (linear spring = suspension; angular spring = the
## steering servo), Z locked (camber). Jolt semantics verified against
## modules/jolt_physics/joints/jolt_generic_6dof_joint_3d.cpp: enabling a
## spring puts that axis into a Position motor (stiffness/damping toward the
## equilibrium point), `linear_drive_*/force_limit` caps the spring force, and
## rewriting an equilibrium point does not rebuild the joint.

## Steering servo, applied as TORQUE — not through the 6DOF motor.
##
## Jolt's SixDOFConstraint splits rotation into swing and twist, and only the
## twist axis (our X, the axle) actually responds to a motor: the wheel spins
## up and brakes through it every tick. On the swing axis (our Y, the steering
## axis) neither the velocity motor nor the angular spring produced ANY torque
## — the stand measured the wheel flopping freely to ±π with a live servo and
## a stiff spring configured and readable on the joint. So steering is a PD
## servo we integrate ourselves, with the reaction fed back into the strut.
##
## Gains are derived per wheel from its real inertia about the steering axis
## (see steering_torque_nm), so a 0.4 m and a 0.75 m tire behave the same.
const STEER_NATURAL_FREQUENCY_RAD_S := 12.0
const STEER_DAMPING_RATIO := 1.0
## Ceiling as a multiple of the torque needed to hit natural frequency; keeps a
## jammed wheel from dumping unbounded torque into the chassis.
const STEER_TORQUE_HEADROOM := 3.0
## Suspension compression above this reads as "carrying load" → grounded.
const GROUNDED_COMPRESSION_EPS_M := 0.004
## Slip-limited drive: the motor target chases the wheel's CURRENT speed with
## this much surface-speed headroom instead of jumping to max. Full-throttle
## from standstill otherwise commands ~60 m/s of slip — the tires saw at the
## ground, the reaction torque wheelies the chassis, and the rover hops in
## place instead of driving (seen on the stand).
const DRIVE_SLIP_MARGIN_MPS := 1.5
## Tire friction cannot exceed the authored ceiling even if grip tuning grows.
const MAX_TIRE_FRICTION := 4.0


static func mount_pad_anchor_assembly_local(
	element: SimulationElement,
	socket_tag: String
) -> Dictionary:
	if element == null:
		return {}
	var archetype := element.get_archetype()
	if archetype == null:
		return {}
	var wanted := ConnectorRuleTable.normalize_tag(socket_tag)
	for connector: ConnectorDefinition in archetype.effective_connectors():
		if connector == null or connector.normalized_tag() != wanted:
			continue
		# The connector point is the anchor: for a plain grid pad that is the
		# face centre, for a precise part it is wherever the author put it
		# (the hub slot), and pose_offset rides along.
		var metric := GridPoseUtil.element_metric_transform(
			element.origin_cell,
			element.orientation_index,
			element.pose_offset
		)
		return {
			"origin": metric * connector.local_position,
			"direction": (
				metric.basis * connector.direction_normalized()
			).normalized(),
		}
	return {}


## Where this wheel SPINS, in part-local metres — the centre of the tire.
## Mate tip (`wheel_plug`) is a different point: construction seats that on
## the suspension socket. Confusing the two put the tire bulk on the strut.
##
## Priority:
## 1. authored hub from the Wizard tire cylinder (`hub_local_authored`);
## 2. exact `wheel_plug` (legacy / tip==centre models);
## 3. footprint centroid (grid parts).
static func axle_point_local(archetype: ElementArchetype) -> Vector3:
	if archetype == null:
		return Vector3.ZERO
	var definition := archetype.wheel_definition
	if definition != null and definition.hub_local_authored:
		return definition.hub_local
	for pad: StructuralMountPad in archetype.effective_mount_pads():
		if pad != null and pad.socket_tag == "wheel_plug" and pad.exact_point:
			return pad.point_local()
	if archetype.footprint_cells.is_empty():
		return GridMetric.cell_center_meters(Vector3i.ZERO)
	var sum := Vector3.ZERO
	for local_cell: Vector3i in archetype.footprint_cells:
		sum += GridMetric.cell_center_meters(local_cell)
	return sum / float(archetype.footprint_cells.size())


## Mate tip in part-local metres — `wheel_plug` exact point, else the hub.
static func plug_point_local(archetype: ElementArchetype) -> Vector3:
	if archetype == null:
		return Vector3.ZERO
	for pad: StructuralMountPad in archetype.effective_mount_pads():
		if pad != null and pad.socket_tag == "wheel_plug" and pad.exact_point:
			return pad.point_local()
	return axle_point_local(archetype)


static func plug_point_assembly_local(
	wheel_element: SimulationElement
) -> Vector3:
	if wheel_element == null:
		return Vector3.ZERO
	return GridPoseUtil.element_metric_transform(
		wheel_element.origin_cell,
		wheel_element.orientation_index,
		wheel_element.pose_offset
	) * plug_point_local(wheel_element.get_archetype())


static func axle_point_assembly_local(
	wheel_element: SimulationElement
) -> Vector3:
	if wheel_element == null:
		return Vector3.ZERO
	return GridPoseUtil.element_metric_transform(
		wheel_element.origin_cell,
		wheel_element.orientation_index,
		wheel_element.pose_offset
	) * axle_point_local(wheel_element.get_archetype())


## Assembly-local wheel frame: hub (the wheel's own axle point), travel axis,
## axle and forward.
##
## Travel runs along the CHASSIS' own up, never along the wheel socket's face.
## A car-style upright holds its hub sideways while the spring still works
## vertically: the authored `Suspension_Medium` faces its socket at NEG_X,
## straight down the axle. Keying travel to that face lays the spring on its
## side and stands the tire up like a barrel — the rover then sinks onto the
## cylinder's flat end and the wheel spins about the vertical. The raycast
## model carried this same warning; ignoring it cost a round.
##
## Forward comes from the wheel's own orientation (identical to the raycast
## model, so drive_inverted keeps its meaning). The axle falls out of the two:
## perpendicular to both, which is horizontal — a rolling wheel by
## construction, in both the grid and the precise-connector paradigm.
static func wheel_frame_assembly_local(
	wheel_element: SimulationElement
) -> Dictionary:
	var definition := _wheel_definition(wheel_element)
	if definition == null:
		return {}
	var up := Vector3.UP
	var forward_raw := Vector3(
		OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(definition.forward_axis_face),
			wheel_element.orientation_index
		)
	).normalized()
	var axle := forward_raw.cross(up)
	if axle.length_squared() <= 0.000001:
		# Wheel mounted rolling straight up/down: no horizontal axle exists.
		return {}
	axle = axle.normalized()
	return {
		"hub": axle_point_assembly_local(wheel_element),
		"up": up,
		"axle": axle,
		"forward": up.cross(axle).normalized(),
	}


## Joint basis in assembly-local space: X = axle, Y = up, Z = X×Y.
static func joint_basis(frame: Dictionary) -> Basis:
	var x_axis := Vector3(frame["axle"]).normalized()
	var y_axis := Vector3(frame["up"]).normalized()
	return Basis(x_axis, y_axis, x_axis.cross(y_axis).normalized())


## One tire cylinder replaces the wheel's authored colliders on the wheel body.
## Record shape matches ColliderProjectionUtil.build_collision_shapes.
static func build_wheel_collider_record(
	wheel_element: SimulationElement,
	frame: Dictionary
) -> Dictionary:
	var definition := _wheel_definition(wheel_element)
	if definition == null or frame.is_empty():
		return {}
	var shape := CylinderShape3D.new()
	shape.radius = definition.radius_m
	shape.height = definition.width_m
	# CylinderShape3D axis is local Y — rotate it onto the axle.
	var axle := Vector3(frame["axle"]).normalized()
	var up := Vector3(frame["up"]).normalized()
	var collider_basis := Basis(up, axle, up.cross(axle).normalized())
	return {
		"element_id": wheel_element.element_id,
		"shape": shape,
		"local_transform": Transform3D(collider_basis, Vector3(frame["hub"])),
		"collider_index": 0,
		"collider_local_cell": wheel_element.origin_cell,
	}


## Full joint configuration — projection-time only (limit writes rebuild the
## Jolt constraint; per-tick updates go through update_drive_motor /
## update_steering, which never touch limits or springs).
##
## Jolt limits are relative to the body poses at joint creation.
## `bind_compression_m` is the wheel's absolute compression at that moment so
## the travel range and the spring equilibrium stay absolute (droop = 0)
## across a live reproject under load. The wheel body's rotation is snapped to
## the strut frame before binding (see projection), so no angular bind offset
## exists.
static func configure_wheel_joint(
	joint: Generic6DOFJoint3D,
	travel_m: float,
	spring_stiffness: float,
	spring_damping: float,
	max_force_n: float,
	steerable: bool,
	max_steer_rad: float,
	bind_compression_m: float = 0.0
) -> void:
	for axis: String in ["x", "z"]:
		joint.set("linear_limit_%s/enabled" % axis, true)
		joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
	# Droop pose = 0: compression moves the wheel up (+Y) toward the chassis,
	# so the absolute range is [0, travel]. The lower stop is the droop catch
	# (airborne wheel), the upper stop is the bump stop — solid geometry where
	# the raycast model had nothing.
	joint.set("linear_limit_y/enabled", true)
	joint.set("linear_limit_y/lower_distance", 0.0 - bind_compression_m)
	joint.set(
		"linear_limit_y/upper_distance",
		maxf(travel_m, 0.0) - bind_compression_m
	)
	update_suspension_spring(
		joint,
		spring_stiffness,
		spring_damping,
		max_force_n,
		bind_compression_m
	)
	# Spin axis: free, driven by a velocity motor (0 torque = freewheel).
	joint.set("angular_limit_x/enabled", false)
	RotorProjectionUtil.update_angular_motor(joint, "x", 0.0, 0.0)
	# Steering axis. Управляемое колесо держит СЕРВО, а не механический упор:
	# ход руля и так ограничен целью (±max_steer), а жёсткий стоп ровно на этом
	# угле означает, что при полной выкрутке мотор всегда давит в стоп — и
	# обратно колесо из него уже не вытаскивается (поймано стендом). Неуправляемое
	# наоборот жёстко заперто в нуле.
	joint.set("angular_limit_y/enabled", not steerable)
	joint.set("angular_limit_y/lower_angle", 0.0)
	joint.set("angular_limit_y/upper_angle", 0.0)
	joint.set("angular_spring_y/enabled", false)
	RotorProjectionUtil.update_angular_motor(joint, "y", 0.0, 0.0)
	# Camber: locked.
	joint.set("angular_limit_z/enabled", true)
	joint.set("angular_limit_z/lower_angle", 0.0)
	joint.set("angular_limit_z/upper_angle", 0.0)


## Spring retune without touching limits — safe on a live joint (no rebuild).
static func update_suspension_spring(
	joint: Generic6DOFJoint3D,
	spring_stiffness: float,
	spring_damping: float,
	max_force_n: float,
	bind_compression_m: float = 0.0
) -> void:
	joint.set("linear_spring_y/enabled", true)
	joint.set("linear_spring_y/stiffness", maxf(spring_stiffness, 0.0))
	joint.set("linear_spring_y/damping", maxf(spring_damping, 0.0))
	joint.set("linear_spring_y/equilibrium_point", 0.0 - bind_compression_m)
	joint.set("linear_drive_y/force_limit", maxf(max_force_n, 0.0))


## Travel slider moved: rewrite the bump-stop range (Jolt rebuilds the joint —
## fine for a slider, never called per tick).
static func update_travel_limit(
	joint: Generic6DOFJoint3D,
	travel_m: float,
	bind_compression_m: float = 0.0
) -> void:
	joint.set(
		"linear_limit_y/upper_distance",
		maxf(travel_m, 0.0) - bind_compression_m
	)


static func update_steer_limit(
	joint: Generic6DOFJoint3D,
	steerable: bool,
	_max_steer_rad: float
) -> void:
	joint.set("angular_limit_y/enabled", not steerable)


## `forward_rad_s` is the sim convention: positive rolls the wheel along its
## forward axis. Rolling forward is a NEGATIVE right-hand rotation about the
## axle (X = forward × up), and RotorProjectionUtil flips once more for
## Godot's CW motors.
static func update_drive_motor(
	joint: Generic6DOFJoint3D,
	forward_rad_s: float,
	torque_limit_nm: float
) -> void:
	RotorProjectionUtil.update_angular_motor(
		joint,
		"x",
		-forward_rad_s,
		torque_limit_nm
	)


## Slip-limited motor target: bounded headroom over the GROUND speed (not the
## wheel's own speed — chasing that lets the wheel bootstrap itself to max and
## saw at the dirt). Keeps longitudinal slip around DRIVE_SLIP_MARGIN_MPS —
## near the friction peak. Textbook traction control.
static func slip_limited_target_rad_s(
	commanded_rad_s: float,
	ground_speed_mps: float,
	radius_m: float
) -> float:
	var radius := maxf(radius_m, 0.05)
	var ground_rad_s := ground_speed_mps / radius
	var margin := DRIVE_SLIP_MARGIN_MPS / radius
	return clampf(
		commanded_rad_s,
		ground_rad_s - margin,
		ground_rad_s + margin
	)


## PD-момент руля вокруг оси хода, в правой (симуляционной) системе — том же
## соглашении, в котором меряется угол. Возвращает ноль для неуправляемого
## колеса: его держит жёсткий замок оси.
static func steering_torque_nm(
	wheel_body: RigidBody3D,
	up_world: Vector3,
	target_rad: float,
	current_rad: float,
	relative_rate_rad_s: float
) -> float:
	var inertia := RotorProjectionUtil.inertia_about_axis(wheel_body, up_world)
	var stiffness := inertia * STEER_NATURAL_FREQUENCY_RAD_S * (
		STEER_NATURAL_FREQUENCY_RAD_S
	)
	var damping := (
		2.0 * STEER_DAMPING_RATIO * STEER_NATURAL_FREQUENCY_RAD_S * inertia
	)
	var limit := stiffness * STEER_TORQUE_HEADROOM
	return clampf(
		stiffness * (target_rad - current_rad) - damping * relative_rate_rad_s,
		-limit,
		limit
	)


## Tire friction from authored grip × player slider (ceiling = authored).
static func tire_friction(
	definition: WheelDefinition,
	grip_scale: float
) -> float:
	if definition == null:
		return 1.0
	return clampf(
		definition.longitudinal_grip * clampf(grip_scale, 0.0, 1.0),
		0.0,
		MAX_TIRE_FRICTION
	)


## Everything the tick needs, measured from the two bodies. All quantities in
## the sim conventions the old telemetry used: wheel_speed positive = rolling
## along forward, steer angle right-hand CCW about up.
##
## `socket_local` / `hub_local` are assembly-frame points on the strut and
## wheel respectively. They coincide only when tip==centre; authored tires
## keep the hub outboard of the mate tip.
static func measure_wheel_state(
	strut_body: PhysicsBody3D,
	wheel_body: RigidBody3D,
	hub_local: Vector3,
	up_local: Vector3,
	axle_local: Vector3,
	radius_m: float,
	travel_m: float,
	socket_local: Vector3 = Vector3(INF, INF, INF)
) -> Dictionary:
	if strut_body == null or wheel_body == null:
		return {}
	var strut_anchor := hub_local if not socket_local.is_finite() else socket_local
	var socket_world: Vector3 = strut_body.to_global(strut_anchor)
	var hub_world: Vector3 = wheel_body.to_global(hub_local)
	var up_world: Vector3 = (
		strut_body.global_transform.basis * up_local
	).normalized()
	var compression := clampf(
		(hub_world - socket_world).dot(up_world),
		0.0,
		maxf(travel_m, 0.0)
	)
	var strut_omega := Vector3.ZERO
	var strut_point_velocity := Vector3.ZERO
	if strut_body is RigidBody3D:
		var strut_rigid := strut_body as RigidBody3D
		strut_omega = strut_rigid.angular_velocity
		strut_point_velocity = (
			strut_rigid.linear_velocity
			+ strut_omega.cross(
				socket_world - strut_rigid.to_global(strut_rigid.center_of_mass)
			)
		)
	var compression_rate := (
		wheel_body.linear_velocity - strut_point_velocity
	).dot(up_world)
	var axle_world: Vector3 = (
		wheel_body.global_transform.basis * axle_local
	).normalized()
	var omega_rel := wheel_body.angular_velocity - strut_omega
	var wheel_speed_forward := -omega_rel.dot(axle_world)
	# Угол руля меряем по САМОЙ оси ступицы, а не разложением кватерниона
	# вокруг вертикали: колесо крутится вокруг этой оси, и как только оно
	# накрутит оборотов, разложение начинает врать (стенд ловил «руль не
	# вернулся» при живом серво). Направление оси к качению невосприимчиво.
	var neutral_axle_world: Vector3 = (
		strut_body.global_transform.basis * axle_local
	).normalized()
	var steer_angle := _signed_angle_about(
		neutral_axle_world,
		axle_world,
		up_world
	)
	var forward_world := up_world.cross(axle_world).normalized()
	var ground_speed := wheel_body.linear_velocity.dot(forward_world)
	return {
		"hub_world": hub_world,
		"socket_world": socket_world,
		"up_world": up_world,
		"forward_world": forward_world,
		"compression_m": compression,
		"compression_rate_mps": compression_rate,
		"wheel_speed_rad_s": wheel_speed_forward,
		"steering_angle_rad": steer_angle,
		"contact_world": hub_world - up_world * radius_m,
		"slip_speed_mps": wheel_speed_forward * radius_m - ground_speed,
		"ground_speed_mps": ground_speed,
	}


## Угол поворота `to_vec` относительно `from_vec` вокруг `axis`, со знаком.
static func _signed_angle_about(
	from_vec: Vector3,
	to_vec: Vector3,
	axis: Vector3
) -> float:
	var a := from_vec - axis * from_vec.dot(axis)
	var b := to_vec - axis * to_vec.dot(axis)
	if a.length_squared() <= 0.000001 or b.length_squared() <= 0.000001:
		return 0.0
	a = a.normalized()
	b = b.normalized()
	return atan2(a.cross(b).dot(axis), a.dot(b))


static func _wheel_definition(element: SimulationElement) -> WheelDefinition:
	var archetype := element.get_archetype() if element != null else null
	return archetype.wheel_definition if archetype != null else null
