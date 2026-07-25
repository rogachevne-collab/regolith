class_name ConstructionTerrainAnchorService
extends RefCounted

static func should_reconcile_assembly(world, assembly_id: int) -> bool:
	var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return false
	# Vehicles never terrain-anchor: a construction block bolted onto a rover
	# must not weld the rover to the ground (or churn anchor reconciles with
	# revision bumps every terrain edit).
	if ThrusterSimulationService.is_mobile_assembly(world, assembly_id):
		return false
	for element_id: int in assembly.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		if (
			element != null
			and TerrainAnchorProbe.is_construction_archetype(
				element.archetype_id
			)
		):
			return true
	return false

static func reconcile_terrain_anchors_for_assemblies(world,
	assembly_ids: Array[int]
) -> void:
	if not world._terrain_contact_probe.is_valid():
		return
	var unique_ids: Dictionary = {}
	for assembly_id_variant: Variant in assembly_ids:
		var assembly_id := int(assembly_id_variant)
		if assembly_id <= 0 or unique_ids.has(assembly_id):
			continue
		if not ConstructionTerrainAnchorService.should_reconcile_assembly(world, assembly_id):
			continue
		unique_ids[assembly_id] = true
		var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		var elements: Array[SimulationElement] = []
		for element_id: int in assembly.element_ids:
			var element: SimulationElement = world.get_element(element_id)
			if (
				element != null
				and TerrainAnchorProbe.is_construction_archetype(
					element.archetype_id
				)
			):
				elements.append(element)
		if elements.is_empty():
			continue
		var touching_variant: Variant = world._terrain_contact_probe.call(
			assembly,
			elements
		)
		if touching_variant is not Array:
			continue
		var touching: Array[int] = []
		for entry: Variant in touching_variant:
			touching.append(int(entry))
		# Probe can miss (collider on terrain child, etc.). Never mass-strip anchors
		# when we already know some blocks were grounded.
		if touching.is_empty():
			for joint: SimulationJoint in world._joints_for_assembly(assembly_id):
				if joint.kind != SimulationJoint.Kind.ANCHOR:
					continue
				for element: SimulationElement in elements:
					if element.element_id == joint.element_a_id:
						touching.append(joint.element_a_id)
						break
			touching.sort()
		# Re-verify and persist the terrain-contact fact per block: the terrain is
		# destructible, so a block that used to sit on ground may now float (and
		# vice versa) after a split/dismantle.
		var touching_lookup: Dictionary = {}
		for touching_id: int in touching:
			touching_lookup[touching_id] = true
		for element: SimulationElement in elements:
			element.terrain_contact = touching_lookup.has(element.element_id)
		var result: Dictionary = RuntimeConnectivity.reconcile_terrain_anchors(
			assembly_id,
			elements,
			world._joints_for_assembly(assembly_id),
			touching,
			func() -> int:
				return world._allocator.allocate_joint_id()
		)
		var changed := false
		for removed_id: int in result["removed_joint_ids"]:
			if world._unregister_joint(int(removed_id)):
				changed = true
		for added_joint: SimulationJoint in result["added_joints"]:
			world._register_joint(added_joint)
			changed = true
		if changed:
			assembly.bump_revision()
			world._notify_topology_changed(assembly.assembly_id)

static func record_placement_terrain_contact(world,
	assembly: SimulationAssembly,
	element: SimulationElement,
	joint_ids: Array[int]
) -> void:
	if not TerrainAnchorProbe.is_construction_archetype(element.archetype_id):
		return
	# See should_reconcile_assembly: blocks placed on vehicles never anchor.
	if ThrusterSimulationService.is_mobile_assembly(world, assembly.assembly_id):
		return
	if not world._terrain_contact_probe.is_valid():
		return
	var touching: Array[int] = ConstructionTerrainAnchorService.probe_touching_ids(world, assembly, [element])
	element.terrain_contact = touching.has(element.element_id)
	if not element.terrain_contact:
		return
	if ConstructionTerrainAnchorService.element_anchor_joint_id(world, assembly.assembly_id, element.element_id) != 0:
		return
	var port_id := RuntimeConnectivity.ground_anchor_port_id(element)
	if port_id.is_empty():
		return
	var joint_id: int = world._allocator.allocate_joint_id()
	world._register_joint(SimulationJoint.anchor(
		joint_id,
		assembly.assembly_id,
		element.element_id,
		port_id
	))
	joint_ids.append(joint_id)

static func probe_touching_ids(world,
	assembly: SimulationAssembly,
	elements: Array[SimulationElement]
) -> Array[int]:
	var out: Array[int] = []
	if not world._terrain_contact_probe.is_valid():
		return out
	var touching_variant: Variant = world._terrain_contact_probe.call(
		assembly,
		elements
	)
	if touching_variant is Array:
		for entry: Variant in touching_variant:
			out.append(int(entry))
	return out

static func element_anchor_joint_id(world, assembly_id: int, element_id: int) -> int:
	for joint_variant: Variant in world._joints.values():
		var joint: SimulationJoint = joint_variant
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.ANCHOR
			and joint.element_a_id == element_id
		):
			return joint.joint_id
	return 0

static func assembly_has_anchor(world, assembly_id: int) -> bool:
	for joint_variant: Variant in world._joints.values():
		var joint: SimulationJoint = joint_variant
		if (
			joint.assembly_id == assembly_id
			and joint.kind == SimulationJoint.Kind.ANCHOR
		):
			return true
	return false

## Terrain-anchored builds always attach. Floating locomotives may expand only
## while nearly stopped (parking brake or coast-to-stop).
static func construction_attach_allowed(world, assembly_id: int) -> bool:
	if ConstructionTerrainAnchorService.assembly_has_anchor(world, assembly_id):
		return true
	if not ThrusterSimulationService.is_mobile_assembly(world, assembly_id):
		return false
	var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
	if assembly == null:
		return false
	var eps := AssemblyLocomotionController.PARKING_BRAKE_SPEED_EPS
	return (
		assembly.motion.linear_velocity.length() < eps
		and assembly.motion.angular_velocity.length() < eps
	)
