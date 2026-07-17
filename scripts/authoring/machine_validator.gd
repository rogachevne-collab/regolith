class_name MachineValidator
extends RefCounted

## Functional oracles for composed machines. Failures are machine-readable.


static func validate(
	world: SimulationWorld,
	assembly_id: int,
	intent: MachineIntent = null
) -> Dictionary:
	var failures: Array[String] = []
	if world == null or assembly_id <= 0:
		return {"ok": false, "failures": ["no_assembly"]}
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return {"ok": false, "failures": ["missing_assembly"]}
	if intent == null:
		intent = MachineIntent.defaults()

	if not _has_archetype(world, assembly, "foundation"):
		failures.append("missing_foundation")
	if not _has_archetype(world, assembly, "power_source"):
		failures.append("missing_power_source")
	if not _has_archetype(world, assembly, "power_distributor"):
		failures.append("missing_distributor")
	if not _has_archetype(world, assembly, "stationary_drill"):
		failures.append("missing_drill")

	var rotor_n := _count_kind(world, assembly_id, SimulationJoint.Kind.ROTOR)
	var hinge_n := _count_kind(world, assembly_id, SimulationJoint.Kind.HINGE)
	var piston_n := _count_kind(world, assembly_id, SimulationJoint.Kind.PISTON)
	var driven_n := rotor_n + hinge_n + piston_n

	if rotor_n != 1:
		failures.append("rotor_count:%d" % rotor_n)
	var expected_piston := 1 if intent.feed else 0
	if piston_n != expected_piston:
		failures.append("piston_count:%d!=%d" % [piston_n, expected_piston])
	if hinge_n != intent.expected_hinge_count():
		failures.append(
			"hinge_count:%d!=%d" % [hinge_n, intent.expected_hinge_count()]
		)
	if driven_n != intent.expected_driven_count():
		failures.append(
			"driven_count:%d!=%d" % [driven_n, intent.expected_driven_count()]
		)
	if driven_n > 4:
		failures.append("driven_chain_too_long:%d" % driven_n)

	var boom_frames := _count_archetype(world, assembly, "frame")
	# mast + reach boom + tip frame.
	var expected_frames := 1 + intent.boom_frame_count() + 1
	if boom_frames < expected_frames:
		failures.append(
			"frame_count:%d<%d" % [boom_frames, expected_frames]
		)

	var tip_ok := false
	if intent.feed:
		for joint: SimulationJoint in world.list_joints():
			if joint.assembly_id != assembly_id:
				continue
			if joint.kind != SimulationJoint.Kind.PISTON:
				continue
			var head_group := world.body_group_id_for_element(joint.element_b_id)
			var root_group := world.root_body_group_id(assembly_id)
			if head_group > 0 and head_group != root_group:
				tip_ok = true
				break
	else:
		tip_ok = boom_frames >= expected_frames
	if not tip_ok:
		failures.append("missing_tip_branch")

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"rotor_count": rotor_n,
		"hinge_count": hinge_n,
		"piston_count": piston_n,
		"driven_count": driven_n,
	}


static func _has_archetype(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	archetype_id: String
) -> bool:
	return _find_archetype_id(world, assembly, archetype_id) > 0


static func _find_archetype_id(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	archetype_id: String
) -> int:
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element != null and element.archetype_id == archetype_id:
			return element_id
	return 0


static func _count_archetype(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	archetype_id: String
) -> int:
	var count := 0
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element != null and element.archetype_id == archetype_id:
			count += 1
	return count


static func _count_kind(
	world: SimulationWorld,
	assembly_id: int,
	kind: int
) -> int:
	var count := 0
	for joint: SimulationJoint in world.list_joints():
		if joint.assembly_id != assembly_id:
			continue
		if joint.kind == kind:
			count += 1
	return count
