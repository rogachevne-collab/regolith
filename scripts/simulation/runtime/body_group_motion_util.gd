extends RefCounted
## Root assembly.motion plus piston observed state → per-body-group poses.
## assembly.motion is always the root group; child groups are derived or synced.
## Loaded via preload (not class_name) to avoid circular SimulationWorld deps.


static func compile_for_assembly(world, assembly_id: int) -> Dictionary:
	if world == null:
		return {"valid": false, "reason": &"missing_assembly"}
	var assembly = world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return {"valid": false, "reason": &"missing_assembly"}
	var elements_by_id: Dictionary = {}
	for element_id: int in assembly.element_ids:
		var element = world.get_element(element_id)
		if element != null:
			elements_by_id[element_id] = element
	var joints: Array = []
	for joint in world.list_joints():
		if joint.assembly_id == assembly_id:
			joints.append(joint)
	var typed_joints: Array[SimulationJoint] = []
	for joint in joints:
		typed_joints.append(joint as SimulationJoint)
	return BodyGroupCompiler.compile(
		assembly.element_ids,
		elements_by_id,
		typed_joints
	)


static func reconstruct_all_group_motions(world, assembly_id: int) -> Dictionary:
	# Prefer world.compile_body_groups so topology-revision cache is shared with
	# element_group_motion / preview validation (avoids 100s of compiles/s).
	var compiled: Dictionary = (
		world.compile_body_groups(assembly_id)
		if world != null and world.has_method("compile_body_groups")
		else compile_for_assembly(world, assembly_id)
	)
	var result: Dictionary = {}
	if not bool(compiled.get("valid", false)):
		return result
	var assembly = world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.motion == null:
		return result
	var root_group_id := int(compiled.get("root_group_id", 0))
	var root_motion: AssemblyMotionState = assembly.motion.duplicate_state()
	if root_group_id > 0:
		result[root_group_id] = root_motion
	var groups: Dictionary = compiled.get("groups", {})
	for group_id: int in groups.keys():
		if int(group_id) == root_group_id:
			continue
		result[int(group_id)] = root_motion.duplicate_state()
	# Parent driven joints before children so nested hinge/piston bases see
	# the already-spun/extended parent group motion (joint_id order is not
	# a topological guarantee after edits / restore).
	for spec: Dictionary in _driven_specs_parent_before_child(
		compiled.get("driven_specs", []),
		root_group_id
	):
		var base_group_id := int(spec.get("base_group_id", 0))
		var head_group_id := int(spec.get("head_group_id", 0))
		var base_motion: AssemblyMotionState = result.get(base_group_id)
		if base_motion == null:
			continue
		var head_motion: AssemblyMotionState
		if int(spec.get("joint_kind", -1)) == SimulationJoint.Kind.ROTOR:
			head_motion = _reconstruct_top_from_rotor_base(world, spec, base_motion)
		elif int(spec.get("joint_kind", -1)) == SimulationJoint.Kind.HINGE:
			head_motion = _reconstruct_top_from_hinge_base(world, spec, base_motion)
		else:
			head_motion = _reconstruct_head_from_base(world, spec, base_motion)
		if head_motion != null:
			result[head_group_id] = head_motion
	return result


static func _driven_specs_parent_before_child(
	driven_specs_variant: Variant,
	root_group_id: int
) -> Array[Dictionary]:
	var specs: Array[Dictionary] = []
	if not driven_specs_variant is Array:
		return specs
	var children_of: Dictionary = {}
	for spec_variant: Variant in driven_specs_variant:
		if not spec_variant is Dictionary:
			continue
		var spec: Dictionary = spec_variant
		specs.append(spec)
		var base_group_id := int(spec.get("base_group_id", 0))
		if not children_of.has(base_group_id):
			children_of[base_group_id] = []
		(children_of[base_group_id] as Array).append(spec)
	if specs.is_empty():
		return specs
	var ordered: Array[Dictionary] = []
	var visited_heads: Dictionary = {}
	var queue: Array[int] = []
	if root_group_id > 0:
		queue.append(root_group_id)
	else:
		var bases: Array[int] = []
		for spec: Dictionary in specs:
			var base_id := int(spec.get("base_group_id", 0))
			if not bases.has(base_id):
				bases.append(base_id)
		bases.sort()
		queue.append_array(bases)
	var queue_index := 0
	while queue_index < queue.size():
		var group_id := queue[queue_index]
		queue_index += 1
		var child_specs: Array = children_of.get(group_id, [])
		child_specs.sort_custom(func(a, b):
			return int(a.get("joint_id", 0)) < int(b.get("joint_id", 0))
		)
		for child_variant: Variant in child_specs:
			var child: Dictionary = child_variant
			var head_id := int(child.get("head_group_id", 0))
			if visited_heads.has(head_id):
				continue
			visited_heads[head_id] = true
			ordered.append(child)
			queue.append(head_id)
	# Orphans (disconnected from root walk) in stable joint_id order.
	if ordered.size() < specs.size():
		var leftovers: Array[Dictionary] = []
		for spec: Dictionary in specs:
			var head_id := int(spec.get("head_group_id", 0))
			if not visited_heads.has(head_id):
				leftovers.append(spec)
		leftovers.sort_custom(func(a, b):
			return int(a.get("joint_id", 0)) < int(b.get("joint_id", 0))
		)
		ordered.append_array(leftovers)
	return ordered


static func reconstruct_group_motion(
	world,
	assembly_id: int,
	group_id: int
) -> AssemblyMotionState:
	var all_motions := reconstruct_all_group_motions(world, assembly_id)
	var motion: Variant = all_motions.get(group_id)
	if motion is AssemblyMotionState:
		return (motion as AssemblyMotionState).duplicate_state()
	if world == null:
		return AssemblyMotionState.new()
	var assembly = world.get_assembly_raw(assembly_id)
	if assembly != null and assembly.motion != null:
		return assembly.motion.duplicate_state()
	return AssemblyMotionState.new()


static func _reconstruct_head_from_base(
	world,
	spec: Dictionary,
	base_motion: AssemblyMotionState
) -> AssemblyMotionState:
	var joint = world.get_joint(int(spec.get("joint_id", 0)))
	var base_element = world.get_element(int(spec.get("base_element_id", 0)))
	var head_element = world.get_element(int(spec.get("head_element_id", 0)))
	if (
		joint == null
		or joint.motor == null
		or base_element == null
		or head_element == null
	):
		return base_motion.duplicate_state()
	var definition: PistonDefinition = null
	var archetype = base_element.get_archetype()
	if archetype != null:
		definition = archetype.piston_definition
	if definition == null:
		return base_motion.duplicate_state()
	var axis_local := _piston_axis_assembly_local(base_element, definition)
	if axis_local.length_squared() <= 0.000001:
		return base_motion.duplicate_state()
	var base_anchor := _port_anchor_assembly_local(
		base_element,
		SimulationMotorState.PISTON_DRIVE_PORT
	)
	var head_anchor := _port_anchor_assembly_local(
		head_element,
		SimulationMotorState.PISTON_CARRIAGE_PORT
	)
	var home_extension := (head_anchor - base_anchor).dot(axis_local)
	var observed: float = joint.motor.clamp_observed_position()
	var delta_m := observed - home_extension
	var axis_world: Vector3 = (
		base_motion.transform.basis * axis_local
	).normalized()
	var head: AssemblyMotionState = base_motion.duplicate_state()
	head.transform.origin = (
		base_motion.transform.origin + axis_world * delta_m
	)
	if base_motion.frozen:
		head.linear_velocity = Vector3.ZERO
		head.angular_velocity = Vector3.ZERO
	else:
		var observed_vel: float = joint.motor.observed_velocity_mps
		head.linear_velocity = (
			base_motion.linear_velocity + axis_world * observed_vel
		)
		head.angular_velocity = base_motion.angular_velocity
	head.sleeping = base_motion.sleeping
	head.frozen = false
	return head


static func _reconstruct_top_from_rotor_base(
	world,
	spec: Dictionary,
	base_motion: AssemblyMotionState
) -> AssemblyMotionState:
	var joint = world.get_joint(int(spec.get("joint_id", 0)))
	var base_element = world.get_element(int(spec.get("base_element_id", 0)))
	if joint == null or joint.motor == null or base_element == null:
		return base_motion.duplicate_state()
	var definition: RotorDefinition = null
	var archetype = base_element.get_archetype()
	if archetype != null:
		definition = archetype.rotor_definition
	if definition == null:
		return base_motion.duplicate_state()
	var axis_local := _rotor_axis_assembly_local(base_element, definition)
	if axis_local.length_squared() <= 0.000001:
		return base_motion.duplicate_state()
	var pivot_local := _port_anchor_assembly_local(
		base_element,
		SimulationMotorState.ROTOR_DRIVE_PORT
	)
	var angle: float = joint.motor.clamp_observed_position()
	var axis_world: Vector3 = (
		base_motion.transform.basis * axis_local
	).normalized()
	var pivot_world: Vector3 = base_motion.transform * pivot_local
	var spin := Basis(axis_world, angle)
	var top: AssemblyMotionState = base_motion.duplicate_state()
	top.transform = Transform3D(
		spin * base_motion.transform.basis,
		pivot_world + spin * (base_motion.transform.origin - pivot_world)
	)
	if base_motion.frozen:
		top.linear_velocity = Vector3.ZERO
		top.angular_velocity = Vector3.ZERO
	else:
		var omega_rel: Vector3 = axis_world * joint.motor.observed_velocity_mps
		top.angular_velocity = base_motion.angular_velocity + omega_rel
		top.linear_velocity = (
			base_motion.linear_velocity
			+ omega_rel.cross(top.transform.origin - pivot_world)
		)
	top.sleeping = base_motion.sleeping
	top.frozen = false
	return top


static func _reconstruct_top_from_hinge_base(
	world,
	spec: Dictionary,
	base_motion: AssemblyMotionState
) -> AssemblyMotionState:
	var joint = world.get_joint(int(spec.get("joint_id", 0)))
	var base_element = world.get_element(int(spec.get("base_element_id", 0)))
	if joint == null or joint.motor == null or base_element == null:
		return base_motion.duplicate_state()
	var definition: HingeDefinition = null
	var archetype = base_element.get_archetype()
	if archetype != null:
		definition = archetype.hinge_definition
	if definition == null:
		return base_motion.duplicate_state()
	var axis_local := HingePlacementUtil.bend_axis_assembly_local(
		base_element,
		definition
	)
	if axis_local.length_squared() <= 0.000001:
		return base_motion.duplicate_state()
	var pivot_local := HingePlacementUtil.pivot_assembly_local(
		base_element,
		definition
	)
	var angle: float = joint.motor.clamp_observed_position()
	var axis_world: Vector3 = (
		base_motion.transform.basis * axis_local
	).normalized()
	var pivot_world: Vector3 = base_motion.transform * pivot_local
	var spin := Basis(axis_world, angle)
	var top: AssemblyMotionState = base_motion.duplicate_state()
	top.transform = Transform3D(
		spin * base_motion.transform.basis,
		pivot_world + spin * (base_motion.transform.origin - pivot_world)
	)
	if base_motion.frozen:
		top.linear_velocity = Vector3.ZERO
		top.angular_velocity = Vector3.ZERO
	else:
		var omega_rel: Vector3 = axis_world * joint.motor.observed_velocity_mps
		top.angular_velocity = base_motion.angular_velocity + omega_rel
		top.linear_velocity = (
			base_motion.linear_velocity
			+ omega_rel.cross(top.transform.origin - pivot_world)
		)
	top.sleeping = base_motion.sleeping
	top.frozen = false
	return top


static func _rotor_axis_assembly_local(
	base_element: SimulationElement,
	definition: RotorDefinition
) -> Vector3:
	var axis_cell: Vector3i = OrientationUtil.rotate_cell(
		definition.top_axis_offset_cell(),
		base_element.orientation_index
	)
	return Vector3(axis_cell).normalized()


static func _piston_axis_assembly_local(
	base_element: SimulationElement,
	definition: PistonDefinition
) -> Vector3:
	var axis_cell: Vector3i = OrientationUtil.rotate_cell(
		definition.head_axis_offset_cell(),
		base_element.orientation_index
	)
	return Vector3(axis_cell).normalized()


static func _port_anchor_assembly_local(
	element: SimulationElement,
	port_id: String
) -> Vector3:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null:
		return GridMetric.cell_center_meters(element.origin_cell)
	for port: PortDefinition in archetype.ports:
		if port == null or port.port_id != port_id:
			continue
		var face_vec: Vector3i = OrientationUtil.rotate_direction(
			OrientationUtil.face_to_vector(port.local_face),
			element.orientation_index
		)
		var world_cell: Vector3i = (
			element.origin_cell
			+ OrientationUtil.rotate_cell(port.local_cell, element.orientation_index)
		)
		return (
			GridMetric.cell_center_meters(world_cell)
			+ Vector3(face_vec) * GridMetric.HALF_CELL_SIZE_M
		)
	return GridMetric.cell_center_meters(element.origin_cell)
