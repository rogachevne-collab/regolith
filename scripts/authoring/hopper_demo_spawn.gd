class_name HopperDemoSpawn
extends RefCounted

## Flight craft for POC-THRUSTERS-V0: deck + thruster + gyro + seat + power + legs.

const STORE_ID := "player"


static func spawn_at_transform(
	session: SimulationSession,
	assembly_transform: Transform3D,
	store_id: String = STORE_ID
) -> Dictionary:
	if session == null or session.world == null:
		return {"ok": false, "error": "no_session"}
	session.world.begin_structural_batch()
	var result := _spawn_batched(session, assembly_transform, store_id)
	session.world.end_structural_batch()
	if not bool(result.get("ok", false)):
		return result
	var assembly_id := int(result.get("assembly_id", 0))
	var motion := GridSpawnUtil.motion_from_transform(assembly_transform, false)
	if session.projection != null:
		session.projection.project_assembly_now(assembly_id, motion)
	if session.visuals != null:
		session.visuals.rebuild_assembly(assembly_id)
	if session.piston_visuals != null:
		session.piston_visuals.rebuild_assembly(assembly_id)
	if session.wheel_visuals != null:
		session.wheel_visuals.rebuild_assembly(assembly_id)
	return result


static func _spawn_batched(
	session: SimulationSession,
	assembly_transform: Transform3D,
	store_id: String
) -> Dictionary:
	for archetype: ElementArchetype in Slice01Archetypes.load_rover_archetypes():
		session.world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_flight_archetypes():
		session.world.get_archetype_registry().register(archetype)
	var helper := AssemblyBuildHelper.new(session.world, store_id)
	helper.ensure_materials(500.0)
	var grid_frame := GridSpawnUtil.grid_frame_from_transform(assembly_transform)
	if not helper.spawn_anchor(Slice01Archetypes.rover_frame(), grid_frame):
		return {"ok": false, "error": helper.last_error}
	# Deck row x=0..2 at z=0.
	for cell: Vector3i in [Vector3i(1, 0, 0), Vector3i(2, 0, 0)]:
		if not helper.place(Slice01Archetypes.rover_frame(), cell, 0, "deck_%d" % cell.x):
			return {"ok": false, "error": helper.last_error}
	# Cockpit forward (3×2×2 footprint).
	if not helper.place(Slice01Archetypes.cockpit(), Vector3i(0, 0, 1), 0, "cockpit"):
		return {"ok": false, "error": helper.last_error}
	# Thruster under deck center — force +Y; feet sit lower than its collider.
	if not helper.place(Slice01Archetypes.thruster(), Vector3i(1, -1, 0), 0, "thruster"):
		return {"ok": false, "error": helper.last_error}
	# Four landing legs at deck corners — sacrificial Support feet.
	var leg_cells: Array[Vector3i] = [
		Vector3i(0, -1, 0),
		Vector3i(2, -1, 0),
		Vector3i(0, -1, 1),
		Vector3i(2, -1, 1),
	]
	for index: int in range(leg_cells.size()):
		var cell: Vector3i = leg_cells[index]
		if not helper.place(
			Slice01Archetypes.landing_leg(),
			cell,
			0,
			"leg_%d" % index
		):
			return {"ok": false, "error": helper.last_error}
	# Gyro on port side.
	if not helper.place(Slice01Archetypes.gyro(), Vector3i(-1, 0, 0), 0, "gyro"):
		return {"ok": false, "error": helper.last_error}
	# Battery (2×3×2) starboard of deck.
	if not helper.place(
		Slice01Archetypes.power_battery_small(),
		Vector3i(3, 0, 0),
		0,
		"battery"
	):
		return {"ok": false, "error": helper.last_error}
	# Distributor beside battery / cockpit.
	if not helper.place(
		Slice01Archetypes.power_distributor_small(),
		Vector3i(3, 0, 2),
		0,
		"distributor"
	):
		return {"ok": false, "error": helper.last_error}
	helper.weld_all()
	if not helper.connect_ports("battery", "power_out", "distributor", "power_in"):
		return {"ok": false, "error": helper.last_error}
	var battery_id := int(helper.element_ids.get("battery", 0))
	if battery_id > 0:
		IndustryElectricBudget.mark_battery_charged(session.world, battery_id)
	session.world.get_locomotion_controller(
		helper.assembly_id
	).mark_released_from_anchor()
	session.world.get_locomotion_controller(helper.assembly_id).set_parking_brake(
		false
	)
	session.world.get_locomotion_controller(helper.assembly_id).activate()
	IndustryElectricBudget.apply_tick(session.world, 0.25)
	return {
		"ok": true,
		"assembly_id": helper.assembly_id,
		"element_ids": helper.element_ids.duplicate(),
	}


static func wake_flight_body(
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
	if not ThrusterSimulationService.is_flight_assembly(
		session.world,
		assembly_id
	):
		push_warning(
			"HopperDemoSpawn: assembly %d is not flight" % assembly_id
		)
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


static func spawn_on_terrain(
	session: SimulationSession,
	world_position: Vector3,
	store_id: String = STORE_ID,
	terrain: Node3D = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	var assembly_transform := RoverDemoSpawn.assembly_transform_on_surface(
		world_position,
		Basis.IDENTITY,
		terrain,
		tool,
		space_state
	)
	# Lift so landing feet clear the ground at spawn.
	assembly_transform.origin += assembly_transform.basis.y * 1.35
	return spawn_at_transform(session, assembly_transform, store_id)
