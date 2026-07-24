class_name InteractionIndex
extends RefCounted
## World-owned secondary index for Interaction Read-Model Phase 1.
## element_id → structure; both driven-joint endpoints resolve to one joint.
## Invalidate on topology notify; lazy rebuild per assembly on read.

## Max ActuatorDisplayPose writes while moving (PLAYER-INTERACTION-V1).
const DISPLAY_POSE_HZ := 10.0
const _DISPLAY_POSE_MIN_INTERVAL_USEC := int(1_000_000.0 / DISPLAY_POSE_HZ)
const _DISPLAY_POSE_EPS := 0.0001

## element_id → InteractionStructure
var _by_element: Dictionary = {}
## element_id → InteractionCard (live scratch; refreshed in-place)
var _cards: Dictionary = {}
## assembly_id → true when entries for that assembly are stale / missing
var _dirty_assemblies: Dictionary = {}
var _all_dirty := true
## joint_id → { t_usec, status, pose } for Hz / silence
var _display_push: Dictionary = {}
## Test/diag: increments on actual DisplayPose write.
var display_write_count := 0


func clear() -> void:
	_by_element.clear()
	_cards.clear()
	_dirty_assemblies.clear()
	_display_push.clear()
	display_write_count = 0
	_all_dirty = true


func invalidate_assembly(assembly_id: int) -> void:
	if assembly_id <= 0:
		clear()
		return
	var remove_ids: Array[int] = []
	for element_id_variant: Variant in _by_element.keys():
		var element_id := int(element_id_variant)
		var entry: InteractionStructure = _by_element[element_id]
		if entry != null and entry.assembly_id == assembly_id:
			remove_ids.append(element_id)
	for element_id: int in remove_ids:
		_by_element.erase(element_id)
		_cards.erase(element_id)
	_dirty_assemblies[assembly_id] = true


func get_structure(
	world: SimulationWorld,
	element_id: int
) -> InteractionStructure:
	if world == null or element_id <= 0:
		return null
	_ensure_element(world, element_id)
	return _by_element.get(element_id) as InteractionStructure


func get_card(world: SimulationWorld, element_id: int) -> InteractionCard:
	var entry := get_structure(world, element_id)
	if entry == null:
		_cards.erase(element_id)
		return null
	var card: InteractionCard = _cards.get(element_id) as InteractionCard
	if card == null:
		card = InteractionCard.new()
		_cards[element_id] = card
	if not card.refresh(world, entry):
		_cards.erase(element_id)
		return null
	return card


## Phase 2c: actuator pushes DisplayPose onto both joint endpoints.
## force_immediate — status/stop/command flush (bypass Hz).
func patch_actuator_display_pose(
	world: SimulationWorld,
	joint_id: int,
	force_immediate: bool = false
) -> bool:
	if world == null or joint_id <= 0:
		return false
	var joint := world.get_joint(joint_id)
	if joint == null or joint.motor == null or not joint.is_driven():
		return false
	var motor := joint.motor
	var pose := motor.observed_position_m
	var status := _motor_status_name(motor.status)
	var at_rest := motor.status == SimulationMotorState.Status.IDLE
	var now_usec := Time.get_ticks_usec()
	var prev: Variant = _display_push.get(joint_id)
	var status_changed := true
	var pose_changed := true
	if prev is Dictionary:
		var prev_dict := prev as Dictionary
		status_changed = StringName(prev_dict.get("status", &"")) != status
		pose_changed = (
			absf(float(prev_dict.get("pose", pose)) - pose) > _DISPLAY_POSE_EPS
		)
		if not force_immediate and not status_changed:
			if not pose_changed:
				return false
			var elapsed := now_usec - int(prev_dict.get("t_usec", 0))
			if elapsed < _DISPLAY_POSE_MIN_INTERVAL_USEC:
				return false
	_display_push[joint_id] = {
		"t_usec": now_usec,
		"status": status,
		"pose": pose,
	}
	var wrote := false
	for endpoint_id: int in [joint.element_a_id, joint.element_b_id]:
		if endpoint_id <= 0:
			continue
		# Lazy-warm assembly so place→first push does not no-op.
		if not _by_element.has(endpoint_id):
			get_structure(world, endpoint_id)
		var entry: InteractionStructure = _by_element.get(endpoint_id) as InteractionStructure
		if entry == null:
			continue
		entry.driven_joint_id = joint.joint_id
		entry.driven_joint_kind = int(joint.kind)
		entry.display_pose_m = pose
		entry.display_actuator_status = status
		entry.display_at_rest = at_rest
		wrote = true
	if wrote:
		display_write_count += 1
	return wrote


func driven_joint_id_for(world: SimulationWorld, element_id: int) -> int:
	var entry := get_structure(world, element_id)
	if entry == null:
		return 0
	return entry.driven_joint_id


func interaction_roles_for(
	world: SimulationWorld,
	element_id: int
) -> PackedStringArray:
	var entry := get_structure(world, element_id)
	if entry == null:
		return PackedStringArray()
	return entry.roles


func _ensure_element(world: SimulationWorld, element_id: int) -> void:
	var element := world.get_element(element_id)
	if element == null:
		_by_element.erase(element_id)
		_cards.erase(element_id)
		return
	var assembly_id := element.assembly_id
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		_by_element.erase(element_id)
		_cards.erase(element_id)
		return
	var entry: InteractionStructure = _by_element.get(element_id) as InteractionStructure
	var needs_rebuild := (
		_all_dirty
		or _dirty_assemblies.has(assembly_id)
		or entry == null
		or entry.topology_revision != assembly.topology_revision
		or entry.assembly_id != assembly_id
	)
	if needs_rebuild:
		_rebuild_assembly(world, assembly)


func _rebuild_assembly(
	world: SimulationWorld,
	assembly: SimulationAssembly
) -> void:
	var assembly_id := assembly.assembly_id
	var revision := assembly.topology_revision
	# Drop stale rows for this assembly before rewrite.
	var remove_ids: Array[int] = []
	for element_id_variant: Variant in _by_element.keys():
		var element_id := int(element_id_variant)
		var existing: InteractionStructure = _by_element[element_id]
		if existing != null and existing.assembly_id == assembly_id:
			remove_ids.append(element_id)
	for element_id: int in remove_ids:
		_by_element.erase(element_id)
		_cards.erase(element_id)

	for element_id_variant: Variant in assembly.element_ids:
		var element_id := int(element_id_variant)
		var element := world.get_element(element_id)
		if element == null:
			continue
		_by_element[element_id] = _build_entry(element, assembly_id, revision)

	# Link driven joints (both endpoints → same joint). Assembly-scoped walk —
	# O(joints in this assembly), not O(all joints in the yard).
	for joint_variant: Variant in world.iter_joints_for_assembly(assembly_id):
		var joint := joint_variant as SimulationJoint
		if joint == null or not joint.is_driven():
			continue
		_link_driven_joint(world, joint)

	_dirty_assemblies.erase(assembly_id)
	# First successful rebuild clears global dirty if no other assemblies pending.
	if _dirty_assemblies.is_empty():
		_all_dirty = false


func _build_entry(
	element: SimulationElement,
	assembly_id: int,
	revision: int
) -> InteractionStructure:
	var entry := InteractionStructure.new()
	entry.element_id = element.element_id
	entry.assembly_id = assembly_id
	entry.archetype_id = element.archetype_id
	entry.topology_revision = revision
	var archetype := element.get_archetype()
	if archetype == null:
		return entry
	entry.roles = archetype.roles.duplicate()
	entry.control_seat = archetype.roles.has("ControlSeat")
	if archetype.is_wheel():
		entry.wheel_element_id = element.element_id
		_fill_wheel_authored(entry, archetype)
	elif archetype.is_suspension():
		entry.suspension_element_id = element.element_id
		_fill_suspension_authored(entry, archetype)
	return entry


func _link_driven_joint(world: SimulationWorld, joint: SimulationJoint) -> void:
	var status: StringName = &""
	var pose := 0.0
	var at_rest := true
	if joint.motor != null:
		pose = joint.motor.observed_position_m
		status = _motor_status_name(joint.motor.status)
		at_rest = joint.motor.status == SimulationMotorState.Status.IDLE
	var authored := _authored_for_driven_joint(world, joint)
	for endpoint_id: int in [joint.element_a_id, joint.element_b_id]:
		if endpoint_id <= 0:
			continue
		var entry: InteractionStructure = _by_element.get(endpoint_id) as InteractionStructure
		if entry == null:
			continue
		entry.driven_joint_id = joint.joint_id
		entry.driven_joint_kind = int(joint.kind)
		entry.display_pose_m = pose
		entry.display_actuator_status = status
		entry.display_at_rest = at_rest
		if not authored.is_empty():
			# Base endpoint owns definition; copy authored onto both ends.
			for key: Variant in authored.keys():
				entry.authored[key] = authored[key]


func _authored_for_driven_joint(
	world: SimulationWorld,
	joint: SimulationJoint
) -> Dictionary:
	var base := world.get_element(joint.element_a_id)
	if base == null:
		return {}
	var archetype := base.get_archetype()
	if archetype == null:
		return {}
	var out: Dictionary = {}
	match joint.kind:
		SimulationJoint.Kind.PISTON:
			var definition: PistonDefinition = archetype.piston_definition
			if definition == null:
				return out
			out["piston_authored_lower_limit_m"] = definition.lower_limit_m
			out["piston_authored_upper_limit_m"] = definition.upper_limit_m
			out["piston_max_velocity_mps"] = definition.max_velocity_mps
			out["piston_max_force_limit_n"] = definition.max_force_limit_n
		SimulationJoint.Kind.ROTOR:
			var rotor_def: RotorDefinition = archetype.rotor_definition
			if rotor_def == null:
				return out
			out["rotor_max_velocity_rad_s"] = rotor_def.max_velocity_rad_s
			out["rotor_max_torque_limit_nm"] = rotor_def.max_torque_limit_nm
		SimulationJoint.Kind.HINGE:
			var hinge_def: HingeDefinition = archetype.hinge_definition
			if hinge_def == null:
				return out
			out["hinge_authored_lower_limit_rad"] = hinge_def.min_angle_rad
			out["hinge_authored_upper_limit_rad"] = hinge_def.max_angle_rad
			out["hinge_max_velocity_rad_s"] = hinge_def.max_velocity_rad_s
			out["hinge_max_torque_limit_nm"] = hinge_def.max_torque_limit_nm
	return out


func _fill_wheel_authored(
	entry: InteractionStructure,
	archetype: ElementArchetype
) -> void:
	var definition: WheelDefinition = archetype.wheel_definition
	if definition == null:
		return
	entry.authored["wheel_max_brake_torque_n_m"] = definition.brake_torque_n_m
	entry.authored["wheel_authored_max_steering_angle_rad"] = (
		definition.max_steering_angle_rad
	)


func _fill_suspension_authored(
	entry: InteractionStructure,
	archetype: ElementArchetype
) -> void:
	var definition: SuspensionDefinition = archetype.suspension_definition
	if definition == null:
		return
	entry.authored["suspension_min_travel_m"] = definition.min_travel_m
	entry.authored["suspension_max_travel_m"] = definition.max_travel_m


## Local copy of status tokens — avoid importing ActuatorSimulationService
## (load cycle: World → Index → ActuatorService → World).
static func _motor_status_name(status: SimulationMotorState.Status) -> StringName:
	match status:
		SimulationMotorState.Status.ELEMENT_INCOMPLETE:
			return &"element_incomplete"
		SimulationMotorState.Status.NO_POWER:
			return &"no_power"
		SimulationMotorState.Status.OVERLOADED:
			return &"overloaded"
		SimulationMotorState.Status.STUCK:
			return &"stuck"
		SimulationMotorState.Status.JOINT_LIMIT:
			return &"joint_limit"
		SimulationMotorState.Status.MOVING:
			return &"moving"
		_:
			return &"idle"
