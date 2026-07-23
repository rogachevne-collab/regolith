class_name ConstructionPreviewSnapshot
extends RefCounted
## Builds a POD snapshot of attach-relevant assemblies for native magnet scan.
## C++ never holds a SimulationWorld pointer.


static func build(world: SimulationWorld) -> Dictionary:
	var assemblies: Array = []
	if world == null:
		return {"assemblies": assemblies}
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly == null or assembly.tombstoned:
			continue
		var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
			world,
			assembly
		)
		if occupancy.is_empty():
			continue
		var elements: Dictionary = {}
		var single_group := world.assembly_is_single_body_group(assembly.assembly_id)
		for element_id_variant: Variant in assembly.element_ids:
			var element_id := int(element_id_variant)
			var element := world.get_element(element_id)
			if element == null:
				continue
			elements[str(element_id)] = {
				"group_transform": world.element_group_transform(element_id),
				"driven_path_at_home": ConstructionCommandService.is_driven_path_at_home(
					world,
					element_id
				),
				"origin_cell": element.origin_cell,
				"orientation_index": element.orientation_index,
			}
		# attach_allowed is intentionally not evaluated here — joint-scan cost
		# must stay on assemblies the aim actually hits (CONSTRUCTION-V1).
		assemblies.append({
			"assembly_id": assembly.assembly_id,
			"topology_revision": assembly.topology_revision,
			"attach_allowed": true,
			"single_group": single_group,
			"root_transform": assembly.motion.transform,
			"occupancy": ConstructionPreviewKernelAccess.pack_occupancy(occupancy),
			"elements": elements,
		})
	return {"assemblies": assemblies}
