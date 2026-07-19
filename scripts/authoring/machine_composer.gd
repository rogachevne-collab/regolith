class_name MachineComposer
extends RefCounted

## Deterministic machine/rig build from MachineIntent. Agent never picks cells.


static func compose(
	world: SimulationWorld,
	intent: MachineIntent,
	grid_frame: GridTransform = GridTransform.identity(),
	store_id: String = PlayerIdentity.local_store_id()
) -> Dictionary:
	if world == null:
		return {"ok": false, "error": "no_world"}
	if intent == null:
		intent = MachineIntent.defaults()
	var unsupported := intent.unsupported_reason()
	if not unsupported.is_empty():
		return {"ok": false, "error": unsupported}
	world.begin_structural_batch()
	var result := _compose_batched(world, intent, grid_frame, store_id)
	world.end_structural_batch()
	return result


static func _compose_batched(
	world: SimulationWorld,
	intent: MachineIntent,
	grid_frame: GridTransform,
	store_id: String
) -> Dictionary:
	_register_archetypes(world)
	var helper := AssemblyBuildHelper.new(world, store_id)
	helper.ensure_materials(2000.0)
	if not helper.spawn_anchor(Slice01Archetypes.foundation(), grid_frame):
		return {"ok": false, "error": helper.last_error}
	match intent.recipe:
		"drill_arm":
			if not _place_drill_arm(helper, intent):
				return {"ok": false, "error": helper.last_error}
		_:
			return {"ok": false, "error": "unsupported_recipe"}
	helper.weld_all()
	if not _wire_power(helper):
		return {"ok": false, "error": helper.last_error}
	_enable_power(world, helper.element_ids)
	_soften_actuators(world, helper.element_ids)
	_stop_all_actuators(world, helper.element_ids)
	var validate := MachineValidator.validate(world, helper.assembly_id, intent)
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
	return compose(world, MachineIntent.from_phrase(phrase), grid_frame, store_id)


## Spawn a composed machine seated on terrain. Keeps foundation anchor.
static func spawn_on_terrain(
	session: SimulationSession,
	world_position: Vector3,
	intent: MachineIntent = null,
	store_id: String = PlayerIdentity.local_store_id(),
	terrain: Node3D = null,
	tool: VoxelTool = null,
	space_state: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	if session == null or session.world == null:
		return {"ok": false, "error": "no_session"}
	if intent == null:
		intent = MachineIntent.defaults()
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
	var motion := AssemblyMotionState.from_grid_frame(grid_frame)
	motion.transform.origin.y = assembly_transform.origin.y
	motion.frozen = true
	motion.sleeping = true
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
		MachineIntent.from_phrase(phrase),
		store_id,
		terrain,
		tool,
		space_state
	)


static func _register_archetypes(world: SimulationWorld) -> void:
	for archetype: ElementArchetype in Slice01Archetypes.load_all_required():
		world.get_archetype_registry().register(archetype)
	for archetype: ElementArchetype in Slice01Archetypes.load_actuator_archetypes():
		world.get_archetype_registry().register(archetype)


static func _place_drill_arm(
	helper: AssemblyBuildHelper,
	intent: MachineIntent
) -> bool:
	# Boom along −X (away from power on +X). Hinge/piston: local +Y → −X,
	# bend +X → +Z (pitch).
	#
	# stationary_drill is a 180 kg 2×2×2 ground tool — hanging it on the tip
	# yaws sideways, detaches, and kinetic-explodes. Keep it on the pad; tip
	# is a light frame end-effector.
	var boom_ori := AssemblyBuildHelper.orientation_with_local_face(
		Vector3i(0, 1, 0),
		Vector3i(-1, 0, 0)
	)

	if not helper.place(
		Slice01Archetypes.power_source(),
		Vector3i(4, 0, 0),
		0,
		"power"
	):
		return false
	if not helper.place(
		Slice01Archetypes.load_required("power_distributor"),
		Vector3i(7, 0, 1),
		0,
		"distributor"
	):
		return false
	# Ground drill on the pad (+Z), clear of boom and power.
	if not helper.place(
		Slice01Archetypes.stationary_drill(),
		Vector3i(1, 0, 4),
		0,
		"drill"
	):
		return false
	if not helper.place(
		Slice01Archetypes.rotor_base(),
		Vector3i(1, 1, 1),
		0,
		"rotor"
	):
		return false
	if not helper.place(
		Slice01Archetypes.frame(),
		Vector3i(1, 3, 1),
		0,
		"mast"
	):
		return false
	# Hinge on mast −X: MountNy (−Y) → +X toward mast. Top at (−1,3,1).
	if not helper.place(
		Slice01Archetypes.hinge_base(),
		Vector3i(0, 3, 1),
		boom_ori,
		"hinge"
	):
		return false
	var next_x := -2
	for boom_i: int in range(intent.boom_frame_count()):
		if not helper.place(
			Slice01Archetypes.frame(),
			Vector3i(next_x, 3, 1),
			0,
			"boom_%d" % boom_i
		):
			return false
		next_x -= 1
	if intent.feed:
		if not helper.place(
			Slice01Archetypes.piston_base(),
			Vector3i(next_x, 3, 1),
			boom_ori,
			"piston"
		):
			return false
		var head_x := next_x - 1
		if intent.wrist:
			if not helper.place(
				Slice01Archetypes.hinge_base(),
				Vector3i(head_x - 1, 3, 1),
				boom_ori,
				"wrist"
			):
				return false
			if not helper.place(
				Slice01Archetypes.frame(),
				Vector3i(head_x - 3, 3, 1),
				0,
				"tip"
			):
				return false
		else:
			if not helper.place(
				Slice01Archetypes.frame(),
				Vector3i(head_x - 1, 3, 1),
				0,
				"tip"
			):
				return false
	elif intent.wrist:
		if not helper.place(
			Slice01Archetypes.hinge_base(),
			Vector3i(next_x, 3, 1),
			boom_ori,
			"wrist"
		):
			return false
		if not helper.place(
			Slice01Archetypes.frame(),
			Vector3i(next_x - 2, 3, 1),
			0,
			"tip"
		):
			return false
	else:
		if not helper.place(
			Slice01Archetypes.frame(),
			Vector3i(next_x, 3, 1),
			0,
			"tip"
		):
			return false
	return true


static func _wire_power(helper: AssemblyBuildHelper) -> bool:
	return helper.connect_ports("power", "power_out", "distributor", "power_in")


static func _enable_power(world: SimulationWorld, element_ids: Dictionary) -> void:
	for key: Variant in ["power", "distributor"]:
		var element_id := int(element_ids.get(str(key), 0))
		if element_id <= 0:
			continue
		var runtime := world.ensure_industry_element_runtime(element_id)
		runtime.machine_enabled = true
		runtime.powered = true
	for key: Variant in ["rotor", "hinge", "piston", "wrist", "drill"]:
		var element_id := int(element_ids.get(str(key), 0))
		if element_id <= 0:
			continue
		var consumer := world.ensure_industry_element_runtime(element_id)
		consumer.machine_enabled = true


## Stock piston force is 30 kN — enough to yeet a light tip through terrain.
## Compose uses soft demo tuning; player can raise limits in the E panel.
static func _soften_actuators(
	world: SimulationWorld,
	element_ids: Dictionary
) -> void:
	var piston_id := int(element_ids.get("piston_joint", 0))
	if piston_id > 0:
		var piston_cfg := ConfigureActuatorCommand.new()
		piston_cfg.joint_id = piston_id
		piston_cfg.extend_velocity_mps = 0.05
		piston_cfg.retract_velocity_mps = 0.05
		piston_cfg.force_limit_n = 800.0
		world.apply_configure_actuator(piston_cfg)
	for key: Variant in ["rotor", "hinge", "wrist"]:
		var joint_id := int(element_ids.get("%s_joint" % str(key), 0))
		if joint_id <= 0:
			continue
		var cfg := ConfigureActuatorCommand.new()
		cfg.joint_id = joint_id
		cfg.extend_velocity_mps = 0.25
		cfg.retract_velocity_mps = 0.25
		cfg.force_limit_n = 500.0
		world.apply_configure_actuator(cfg)


static func _stop_all_actuators(
	world: SimulationWorld,
	element_ids: Dictionary
) -> void:
	for key: Variant in ["rotor", "hinge", "piston", "wrist"]:
		var joint_id := int(element_ids.get("%s_joint" % str(key), 0))
		if joint_id <= 0:
			continue
		var command := SetActuatorTargetCommand.new()
		command.joint_id = joint_id
		command.mode = SimulationMotorState.ControlMode.STOP
		command.target_velocity_mps = 0.0
		world.apply_set_actuator_target(command)
