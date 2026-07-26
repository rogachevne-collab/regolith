class_name AssemblyParkingFreezeCoordinator
extends RefCounted
## Parking settle-freeze cluster extracted from SimulationPhysicsProjection.
## Owns freeze/thaw of parked locomotive assemblies and dig/seat wake paths.
## Hot-path order stays in SimulationPhysicsProjection._physics_process;
## settle-frame counters live on projection (_park_settle_frames).


## Physics frames a parked rover must stay below the brake eps before its
## body is frozen (~0.5s at 60Hz).
const PARK_FREEZE_SETTLE_FRAMES := 30
const WAKE_DIG_MARGIN_M := 3.0


## Once a parked rover has settled under the parking brake, freeze every body
## of the assembly (static pose, zero per-frame cost) and stop ticking wheels.
## Wake paths: driver input / brake release (here), seat entry
## (gateway._wake_rover_body → wake_assembly_bodies), terrain digs nearby
## (wake_frozen_near).
static func update_parking_freeze(projection, assembly_id: int) -> void:
	if (
		projection._world == null
		or not WheelSimulationService.is_locomotive_assembly(
			projection._world,
			assembly_id
		)
	):
		return
	var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
	if body is not RigidBody3D:
		return
	var rigid: RigidBody3D = body as RigidBody3D
	var locomotion: AssemblyLocomotionController = (
		projection._world.get_locomotion_controller(assembly_id)
	)
	if locomotion == null:
		return
	# Brake command does not block freezing: the seat-exit flow keeps
	# brake_command at 1.0 while parked, and "braking while already still"
	# is exactly the state we want to freeze.
	var parked: bool = (
		locomotion.is_parking_brake()
		and absf(locomotion.drive_command) <= 0.001
		and absf(locomotion.steering_command) <= 0.001
		and locomotion.translate_magnitude() <= 0.001
		and absf(locomotion.pitch_command) <= 0.001
		and absf(locomotion.yaw_command) <= 0.001
		and absf(locomotion.roll_command) <= 0.001
	)
	if rigid.freeze:
		if not parked:
			AssemblyParkingFreezeCoordinator.set_assembly_bodies_frozen(
				projection,
				assembly_id,
				false
			)
			projection._park_settle_frames[assembly_id] = 0
		return
	if not parked:
		projection._park_settle_frames[assembly_id] = 0
		return
	var eps: float = AssemblyLocomotionController.PARKING_BRAKE_SPEED_EPS
	# Every body of the assembly must be quiet — a spinning wheel body under a
	# still chassis is exactly the state the brake has not finished with yet.
	for body_variant: Variant in (
		AssemblyParkingFreezeCoordinator.assembly_rigid_bodies(
			projection,
			assembly_id
		)
	):
		var group_rigid: RigidBody3D = body_variant as RigidBody3D
		if (
			group_rigid.linear_velocity.length() >= eps
			or group_rigid.angular_velocity.length() >= eps
		):
			projection._park_settle_frames[assembly_id] = 0
			return
	var settled: int = (
		int(projection._park_settle_frames.get(assembly_id, 0)) + 1
	)
	projection._park_settle_frames[assembly_id] = settled
	if settled < PARK_FREEZE_SETTLE_FRAMES:
		return
	AssemblyParkingFreezeCoordinator.set_assembly_bodies_frozen(
		projection,
		assembly_id,
		true
	)


## Every dynamic body of the assembly: the root/single body plus all group
## bodies (wheels, carriages). Static roots are skipped.
static func assembly_rigid_bodies(
	projection,
	assembly_id: int
) -> Array[RigidBody3D]:
	var bodies: Array[RigidBody3D] = []
	var groups: Variant = projection._assembly_group_bodies.get(assembly_id)
	if groups is Dictionary:
		for body_variant: Variant in (groups as Dictionary).values():
			if body_variant is RigidBody3D and is_instance_valid(body_variant):
				bodies.append(body_variant as RigidBody3D)
		return bodies
	var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
	if body is RigidBody3D and is_instance_valid(body):
		bodies.append(body as RigidBody3D)
	return bodies


static func set_assembly_bodies_frozen(
	projection,
	assembly_id: int,
	frozen: bool
) -> void:
	# Пишем в тело только на реальной смене состояния. Путь езды зовёт wake
	# каждый тик (has_active_input); без этих гардов каждый такой вызов
	# переписывал freeze/sleeping на всех телах сборки в физсервер — лишний
	# шторм на уже-разбуженных телах во время движения.
	for rigid: RigidBody3D in (
		AssemblyParkingFreezeCoordinator.assembly_rigid_bodies(
			projection,
			assembly_id
		)
	):
		if frozen:
			if not rigid.freeze:
				rigid.linear_velocity = Vector3.ZERO
				rigid.angular_velocity = Vector3.ZERO
				rigid.freeze = true
		else:
			if rigid.freeze:
				rigid.freeze = false
			if rigid.sleeping:
				rigid.sleeping = false


## Wake every dynamic body of the assembly (seat entry, drive input, dig).
## Root-only wakes leave wheel bodies frozen mid-air with the chassis live —
## the constraint then drags a static wheel around.
static func wake_assembly_bodies(projection, assembly_id: int) -> void:
	AssemblyParkingFreezeCoordinator.set_assembly_bodies_frozen(
		projection,
		assembly_id,
		false
	)
	projection._park_settle_frames[assembly_id] = 0


## Frozen parked vehicles must not keep floating when the ground under them
## is dug away — unfreeze anything frozen near a terrain edit and let physics
## re-settle it.
static func wake_frozen_near(
	projection,
	center: Vector3,
	radius: float
) -> void:
	for assembly_id: int in AssemblyTeardownCoordinator.sorted_int_keys(projection._bodies):
		var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
		if body is not RigidBody3D:
			continue
		var rigid: RigidBody3D = body as RigidBody3D
		if not rigid.freeze:
			continue
		if not WheelSimulationService.is_locomotive_assembly(
			projection._world,
			assembly_id
		):
			continue
		if rigid.global_position.distance_to(center) > radius + WAKE_DIG_MARGIN_M:
			continue
		AssemblyParkingFreezeCoordinator.wake_assembly_bodies(
			projection,
			assembly_id
		)


static func is_assembly_frozen(projection, assembly_id: int) -> bool:
	var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
	return body is RigidBody3D and (body as RigidBody3D).freeze


static func has_live_actuator_assembly(
	projection,
	constraints: Dictionary
) -> bool:
	if projection._world == null or constraints.is_empty():
		return false
	for assembly_id: int in AssemblyTeardownCoordinator.sorted_int_keys(constraints):
		var assembly: SimulationAssembly = (
			projection._world.get_assembly_raw(assembly_id)
		)
		if assembly == null or assembly.tombstoned:
			continue
		if not AssemblyParkingFreezeCoordinator.is_assembly_frozen(
			projection,
			assembly_id
		):
			return true
	return false
