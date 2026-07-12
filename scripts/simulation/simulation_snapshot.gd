class_name SimulationSnapshot
extends RefCounted

const VERSION := 3


static func capture(world) -> Dictionary:
	return {
		"version": VERSION,
		"allocator": world.get_allocator().to_dict(),
		"archetypes": world.get_archetype_registry().definition_rows(),
		"assemblies": _serialize_assemblies(world),
		"elements": _serialize_elements(world),
		"joints": _serialize_joints(world),
		"redirects": _serialize_redirects(world),
		"resource_stores": _serialize_resource_stores(world),
	}


static func create_from_snapshot(snapshot: Dictionary):
	var world = _new_world()
	if world == null or not _validate_and_populate(world, snapshot):
		if world != null:
			world.free()
		return null
	return world


static func semantic_equals(left: Dictionary, right: Dictionary) -> bool:
	return JSON.stringify(_canonicalize(left)) == JSON.stringify(
		_canonicalize(right)
	)


static func _validate_and_populate(world, snapshot: Dictionary) -> bool:
	if int(snapshot.get("version", 0)) != VERSION:
		return false
	var archetype_rows: Variant = snapshot.get("archetypes")
	var assembly_rows: Variant = snapshot.get("assemblies")
	var element_rows: Variant = snapshot.get("elements")
	var joint_rows: Variant = snapshot.get("joints")
	var redirect_rows: Variant = snapshot.get("redirects")
	var store_rows: Variant = snapshot.get("resource_stores")
	var allocator_data: Variant = snapshot.get("allocator")
	if (
		not archetype_rows is Array
		or not assembly_rows is Array
		or not element_rows is Array
		or not joint_rows is Array
		or not redirect_rows is Array
		or not store_rows is Array
		or not allocator_data is Dictionary
	):
		return false

	var registry: ArchetypeRegistry = world.get_archetype_registry()
	var archetype_ids: Dictionary = {}
	for row_variant: Variant in archetype_rows:
		if not row_variant is Dictionary:
			return false
		var row: Dictionary = row_variant
		var archetype_id := str(row.get("archetype_id", ""))
		var resource_path := str(row.get("resource_path", ""))
		var expected_fingerprint := str(row.get("fingerprint", ""))
		if (
			archetype_id.is_empty()
			or archetype_ids.has(archetype_id)
			or resource_path.is_empty()
			or not ResourceLoader.exists(resource_path)
		):
			return false
		archetype_ids[archetype_id] = true
		var archetype := load(resource_path) as ElementArchetype
		if (
			archetype == null
			or archetype.archetype_id != archetype_id
			or not BlueprintValidator.validate_archetype(archetype).ok
			or ArchetypeRegistry.fingerprint_of(archetype) != expected_fingerprint
			or not registry.register(archetype)
		):
			return false

	var assembly_ids: Dictionary = {}
	var active_assembly_ids: Dictionary = {}
	var expected_membership: Dictionary = {}
	var max_assembly_id := 0
	for row_variant: Variant in assembly_rows:
		if not row_variant is Dictionary:
			return false
		var row: Dictionary = row_variant
		var assembly := SimulationAssembly.from_dict(row)
		if (
			assembly.assembly_id <= 0
			or assembly_ids.has(assembly.assembly_id)
			or assembly.topology_revision < 0
			or assembly.grid_frame == null
			or not assembly.grid_frame.is_valid()
			or assembly.motion == null
			or not assembly.motion.is_valid()
		):
			return false
		if assembly.tombstoned:
			if not assembly.element_ids.is_empty() or assembly.redirect_to <= 0:
				return false
		else:
			if assembly.redirect_to != 0 or assembly.element_ids.is_empty():
				return false
			active_assembly_ids[assembly.assembly_id] = true
		assembly_ids[assembly.assembly_id] = assembly
		max_assembly_id = maxi(max_assembly_id, assembly.assembly_id)
		for element_id: int in assembly.element_ids:
			if element_id <= 0 or expected_membership.has(element_id):
				return false
			expected_membership[element_id] = assembly.assembly_id

	var elements: Dictionary = {}
	var max_element_id := 0
	for row_variant: Variant in element_rows:
		if not row_variant is Dictionary:
			return false
		var element_row: Dictionary = row_variant
		if not element_row.get("installed_materials", {}) is Dictionary:
			return false
		var element := SimulationElement.from_dict(element_row)
		var archetype: ElementArchetype = registry.get_archetype(
			element.archetype_id
		)
		if (
			element.element_id <= 0
			or elements.has(element.element_id)
			or archetype == null
			or not active_assembly_ids.has(element.assembly_id)
			or int(expected_membership.get(element.element_id, 0))
			!= element.assembly_id
			or element.orientation_index < 0
			or element.orientation_index >= OrientationUtil.ORIENTATION_COUNT
			or element.build_progress < 0.0
			or element.build_progress > 1.0
			or not is_finite(element.build_progress)
			or element.condition < 0.0
			or element.condition > 1.0
			or not is_finite(element.condition)
			or element.state_revision < 0
			or element.integrity < 0.0
			or element.integrity > archetype.max_integrity
			or not is_finite(element.integrity)
			or not element.bind_archetype(archetype)
		):
			return false
		for resource_id: Variant in element.installed_materials.keys():
			var installed := float(element.installed_materials[resource_id])
			if (
				str(resource_id).is_empty()
				or not is_finite(installed)
				or installed < 0.0
				or installed
				> element.required_material_amount(str(resource_id)) + 0.000001
			):
				return false
		var required_total := element.total_required_material_amount()
		var expected_fraction := element.structural_fraction()
		if not is_equal_approx(expected_fraction, element.build_progress):
			return false
		if not is_equal_approx(
			element.integrity,
			archetype.max_integrity * expected_fraction
		):
			return false
		elements[element.element_id] = element
		max_element_id = maxi(max_element_id, element.element_id)
	if elements.size() != expected_membership.size():
		return false

	var joints: Dictionary = {}
	var canonical_joints: Dictionary = {}
	var max_joint_id := 0
	for row_variant: Variant in joint_rows:
		if not row_variant is Dictionary:
			return false
		var joint := SimulationJoint.from_dict(row_variant)
		if (
			joint.joint_id <= 0
			or joints.has(joint.joint_id)
			or not active_assembly_ids.has(joint.assembly_id)
			or not elements.has(joint.element_a_id)
			or (elements[joint.element_a_id] as SimulationElement).assembly_id
			!= joint.assembly_id
			or joint.port_a_id.is_empty()
			or not _element_has_port(
				elements[joint.element_a_id],
				joint.port_a_id
			)
		):
			return false
		if joint.kind == SimulationJoint.Kind.RIGID:
			if (
				joint.element_b_id <= 0
				or joint.element_b_id == joint.element_a_id
				or not elements.has(joint.element_b_id)
				or (elements[joint.element_b_id] as SimulationElement).assembly_id
				!= joint.assembly_id
				or joint.port_b_id.is_empty()
				or not _element_has_port(
					elements[joint.element_b_id],
					joint.port_b_id
				)
			):
				return false
		elif joint.kind == SimulationJoint.Kind.ANCHOR:
			if joint.element_b_id != 0 or not joint.port_b_id.is_empty():
				return false
		else:
			return false
		var canonical_key := "%d|%s" % [joint.kind, joint.canonical_key()]
		if canonical_joints.has(canonical_key):
			return false
		canonical_joints[canonical_key] = true
		joints[joint.joint_id] = joint
		max_joint_id = maxi(max_joint_id, joint.joint_id)

	for assembly_id: int in _sorted_int_keys(active_assembly_ids):
		var assembly: SimulationAssembly = assembly_ids[assembly_id]
		var occupied: Dictionary = {}
		for element_id: int in assembly.element_ids:
			var element: SimulationElement = elements[element_id]
			for cell: Vector3i in element.occupied_cells():
				var cell_key := "%d,%d,%d" % [cell.x, cell.y, cell.z]
				if occupied.has(cell_key):
					return false
				occupied[cell_key] = element_id
		var assembly_joints: Array[SimulationJoint] = []
		for joint_id: int in _sorted_int_keys(joints):
			var joint: SimulationJoint = joints[joint_id]
			if joint.assembly_id != assembly_id:
				continue
			assembly_joints.append(joint)
			if joint.kind == SimulationJoint.Kind.RIGID:
				if not RuntimeConnectivity.validate_merge_connection(
					elements[joint.element_a_id],
					joint.port_a_id,
					elements[joint.element_b_id],
					joint.port_b_id
				):
					return false
			elif not _element_has_anchor_port(
				elements[joint.element_a_id],
				joint.port_a_id
			):
				return false
		if assembly.element_ids.size() > 1:
			var components := RuntimeConnectivity.connected_components(
				assembly.element_ids,
				elements,
				assembly_joints
			)
			if components.size() != 1:
				return false

	var redirects: Dictionary = {}
	for row_variant: Variant in redirect_rows:
		if not row_variant is Dictionary:
			return false
		var row: Dictionary = row_variant
		var from_id := int(row.get("from_assembly_id", 0))
		var to_id := int(row.get("to_assembly_id", 0))
		if (
			from_id <= 0
			or to_id <= 0
			or from_id == to_id
			or redirects.has(from_id)
			or not assembly_ids.has(from_id)
			or not (assembly_ids[from_id] as SimulationAssembly).tombstoned
			or not assembly_ids.has(to_id)
		):
			return false
		redirects[from_id] = to_id
	for from_id: Variant in redirects.keys():
		var current := int(from_id)
		var visited: Dictionary = {}
		while redirects.has(current):
			if visited.has(current):
				return false
			visited[current] = true
			current = int(redirects[current])
		if not active_assembly_ids.has(current):
			return false
		if (assembly_ids[int(from_id)] as SimulationAssembly).redirect_to != int(
			redirects[from_id]
		):
			return false
	for assembly_id: Variant in assembly_ids.keys():
		var assembly: SimulationAssembly = assembly_ids[assembly_id]
		if assembly.tombstoned and not redirects.has(assembly.assembly_id):
			return false

	var stores: Dictionary = {}
	for row_variant: Variant in store_rows:
		if not row_variant is Dictionary:
			return false
		var store_row: Dictionary = row_variant
		if not store_row.get("amounts", {}) is Dictionary:
			return false
		var store := SimulationResourceStore.from_dict(store_row)
		if (
			store == null
			or store.store_id.is_empty()
			or stores.has(store.store_id)
		):
			return false
		stores[store.store_id] = store

	var next_element_id := int(allocator_data.get("next_element_id", 0))
	var next_assembly_id := int(allocator_data.get("next_assembly_id", 0))
	var next_joint_id := int(allocator_data.get("next_joint_id", 0))
	var next_command_id := int(allocator_data.get("next_command_id", 0))
	if (
		next_element_id <= max_element_id
		or next_assembly_id <= max_assembly_id
		or next_joint_id <= max_joint_id
		or next_command_id <= 0
	):
		return false

	world.get_allocator().load_from_dict(allocator_data)
	for assembly_id: int in _sorted_int_keys(assembly_ids):
		world._register_assembly(assembly_ids[assembly_id])
	for element_id: int in _sorted_int_keys(elements):
		world._register_element(elements[element_id])
	for joint_id: int in _sorted_int_keys(joints):
		world._register_joint(joints[joint_id])
	for from_id: int in _sorted_int_keys(redirects):
		world._register_redirect(from_id, redirects[from_id])
	var store_ids: Array = stores.keys()
	store_ids.sort()
	for store_id: Variant in store_ids:
		world._register_resource_store(stores[store_id])
	return true


static func _new_world():
	var script := load(
		"res://scripts/simulation/simulation_world.gd"
	) as Script
	return script.new() if script != null else null


static func _serialize_assemblies(world) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for assembly: SimulationAssembly in world.list_assemblies():
		rows.append(assembly.to_dict())
	return rows


static func _serialize_elements(world) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for element: SimulationElement in world.list_elements():
		rows.append(element.to_dict())
	return rows


static func _serialize_joints(world) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for joint: SimulationJoint in world.list_joints():
		rows.append(joint.to_dict())
	return rows


static func _serialize_redirects(world) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for from_id: int in world.list_redirect_from_ids():
		rows.append({
			"from_assembly_id": from_id,
			"to_assembly_id": world.get_redirect_target_raw(from_id),
		})
	return rows


static func _serialize_resource_stores(world) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for store: SimulationResourceStore in world.list_resource_stores():
		rows.append(store.to_dict())
	return rows


static func _element_has_port(
	element: SimulationElement,
	port_id: String
) -> bool:
	var archetype := element.get_archetype()
	for port: PortDefinition in archetype.ports:
		if port.port_id == port_id:
			return true
	return false


static func _element_has_anchor_port(
	element: SimulationElement,
	port_id: String
) -> bool:
	return RuntimeConnectivity.ground_anchor_port_id(element) == port_id


static func _sorted_int_keys(values: Dictionary) -> Array[int]:
	var keys: Array[int] = []
	for key: Variant in values.keys():
		keys.append(int(key))
	keys.sort()
	return keys


static func _canonicalize(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var result: Dictionary = {}
		for key: Variant in keys:
			result[str(key)] = _canonicalize(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_canonicalize(item))
		return result
	return value
