class_name ConstructionPreviewKernelAccess
extends RefCounted
## Thin GDScript facade over ConstructionPreviewKernel GDExtension.
## Falls back to null when the native library is missing.

const ELEMENT_STRIDE := 8
const FACE_STRIDE := 5

static var _kernel: RefCounted = null
static var _checked := false
static var _rules_synced := false
static var _faces_cache: Dictionary = {}
static var _footprint_cache: Dictionary = {}
static var _flat_archetype_cache: Dictionary = {}
static var _assembly_attach_cache: Dictionary = {}
static var _occupancy_packed_cache: Dictionary = {}


static func available() -> bool:
	return get_kernel() != null


static func get_kernel() -> RefCounted:
	if not _checked:
		_checked = true
		if ClassDB.class_exists("ConstructionPreviewKernel"):
			_kernel = ClassDB.instantiate("ConstructionPreviewKernel")
	if _kernel != null and not _rules_synced:
		_sync_socket_rules(_kernel)
		_rules_synced = true
	return _kernel


static func clear_archetype_cache() -> void:
	_faces_cache.clear()
	_footprint_cache.clear()
	_flat_archetype_cache.clear()


static func clear_assembly_attach_cache(assembly_id: int = 0) -> void:
	if assembly_id <= 0:
		_assembly_attach_cache.clear()
		_occupancy_packed_cache.clear()
		ConstructionPreviewSnapshot.clear_cache()
		return
	_assembly_attach_cache.erase(assembly_id)
	_occupancy_packed_cache.erase(assembly_id)
	ConstructionPreviewSnapshot.clear_cache(assembly_id)


## Revision-cached packed occupancy for native prefilter / snapshot.
## Avoids re-packing a large rover Dictionary on every TOP_K candidate.
static func cached_packed_occupancy(world, assembly: SimulationAssembly) -> PackedInt32Array:
	if world == null or assembly == null:
		return PackedInt32Array()
	var cached: Variant = _occupancy_packed_cache.get(assembly.assembly_id)
	if cached is Dictionary:
		var entry: Dictionary = cached
		if int(entry.get("revision", -1)) == assembly.topology_revision:
			return entry["packed"]
	# Reuse attach-table pack when warm — same occupancy bytes.
	var attach_cached: Variant = _assembly_attach_cache.get(assembly.assembly_id)
	if attach_cached is Dictionary:
		var attach_entry: Dictionary = attach_cached
		if int(attach_entry.get("revision", -1)) == assembly.topology_revision:
			var from_attach: PackedInt32Array = attach_entry.get(
				"occupancy",
				PackedInt32Array()
			)
			_occupancy_packed_cache[assembly.assembly_id] = {
				"revision": assembly.topology_revision,
				"packed": from_attach,
			}
			return from_attach
	var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
		world,
		assembly
	)
	var packed := pack_occupancy(occupancy)
	_occupancy_packed_cache[assembly.assembly_id] = {
		"revision": assembly.topology_revision,
		"packed": packed,
	}
	return packed


static func pack_occupancy(occupancy: Dictionary) -> PackedInt32Array:
	var packed := PackedInt32Array()
	packed.resize(occupancy.size() * 4)
	var i := 0
	for cell_variant: Variant in occupancy.keys():
		var cell: Vector3i = cell_variant
		packed[i] = cell.x
		packed[i + 1] = cell.y
		packed[i + 2] = cell.z
		packed[i + 3] = int(occupancy[cell_variant])
		i += 4
	return packed


static func pack_cells(cells: Array) -> PackedVector3Array:
	var packed := PackedVector3Array()
	packed.resize(cells.size())
	for index: int in range(cells.size()):
		var cell: Vector3i = cells[index]
		packed[index] = Vector3(cell)
	return packed


static func cached_footprint_local(
	archetype: ElementArchetype,
	orientation_index: int
) -> PackedVector3Array:
	if archetype == null:
		return PackedVector3Array()
	var cache_key := _archetype_orientation_key(archetype, orientation_index)
	if _footprint_cache.has(cache_key):
		return _footprint_cache[cache_key]
	var packed := pack_cells(archetype.footprint_cells)
	_footprint_cache[cache_key] = packed
	return packed


static func preview_world_cells(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if archetype == null:
		return cells
	for local_cell: Vector3i in archetype.footprint_cells:
		cells.append(
			origin_cell + OrientationUtil.rotate_cell(local_cell, orientation_index)
		)
	return cells


static func side_spec_from_archetype(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Dictionary:
	return {
		"origin_cell": origin_cell,
		"orientation_index": orientation_index,
		"footprint_size": (
			archetype.footprint_cells.size() if archetype != null else 0
		),
		"faces": _cached_faces(archetype, orientation_index),
	}


static func side_spec_from_element(element: SimulationElement) -> Dictionary:
	if element == null:
		return {}
	var archetype := element.get_archetype()
	if archetype == null:
		return {}
	return side_spec_from_archetype(
		archetype,
		element.origin_cell,
		element.orientation_index
	)


static func find_attach_connections(
	world,
	assembly: SimulationAssembly,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Dictionary:
	var native_result := validate_attach_preview(
		world,
		assembly,
		archetype,
		origin_cell,
		orientation_index
	)
	if native_result.is_empty():
		return {}
	var connections: Array = []
	var existing_ids: PackedInt32Array = native_result.get(
		"existing_element_ids",
		PackedInt32Array()
	)
	var existing_ports: PackedStringArray = native_result.get(
		"existing_port_ids",
		PackedStringArray()
	)
	var new_ports: PackedStringArray = native_result.get(
		"new_port_ids",
		PackedStringArray()
	)
	for index: int in range(existing_ids.size()):
		connections.append({
			"existing_element_id": int(existing_ids[index]),
			"existing_port_id": (
				str(existing_ports[index]) if index < existing_ports.size() else ""
			),
			"new_port_id": str(new_ports[index]) if index < new_ports.size() else "",
		})
	return {
		"overlap": str(native_result.get("reason", "")) == "overlap",
		"ok": bool(native_result.get("ok", false)),
		"reason": native_result.get("reason", &"invalid_target"),
		"connections": connections,
	}


## Full attach validate in one native call (flat packed, revision-cached assembly).
## Returns {} when native unavailable; otherwise {ok, reason, existing_*, new_*}.
static func validate_attach_preview(
	world,
	assembly: SimulationAssembly,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Dictionary:
	var kernel := get_kernel()
	if kernel == null or world == null or assembly == null or archetype == null:
		return {}
	var t_pack := ConstructionPerf.begin()
	var packed_assembly := _packed_assembly_attach(world, assembly)
	if packed_assembly.is_empty():
		ConstructionPerf.end(&"pack_attach_us", t_pack)
		return {}
	var packed_preview := _packed_archetype_attach(archetype, orientation_index)
	if packed_preview.is_empty():
		ConstructionPerf.end(&"pack_attach_us", t_pack)
		return {}
	ConstructionPerf.end(&"pack_attach_us", t_pack)
	var group_pack := _packed_body_groups(world, assembly.assembly_id)
	var t_call := ConstructionPerf.begin()
	var result: Dictionary = kernel.call(
		"validate_attach_preview",
		packed_assembly["occupancy"],
		packed_assembly["elements"],
		packed_assembly["faces"],
		packed_assembly["port_ids"],
		packed_assembly["socket_tags"],
		origin_cell,
		orientation_index,
		int(packed_preview["footprint_size"]),
		packed_preview["footprint"],
		packed_preview["faces"],
		packed_preview["port_ids"],
		packed_preview["socket_tags"],
		group_pack["element_to_group"],
		group_pack["driven_bridges"]
	)
	ConstructionPerf.end(&"validate_native_us", t_call)
	ConstructionPerf.count(&"native_validates")
	if kernel.has_method("get_last_kernel_us"):
		ConstructionPerf.note_kernel_us(
			&"validate_attach_preview",
			int(kernel.call("get_last_kernel_us"))
		)
	return result


static func _packed_assembly_attach(world, assembly: SimulationAssembly) -> Dictionary:
	var cached: Variant = _assembly_attach_cache.get(assembly.assembly_id)
	if cached is Dictionary:
		var entry: Dictionary = cached
		if int(entry.get("revision", -1)) == assembly.topology_revision:
			return entry
	var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
		world,
		assembly
	)
	var elements := PackedInt32Array()
	var faces := PackedInt32Array()
	var port_ids := PackedStringArray()
	var socket_tags := PackedStringArray()
	var port_index_by_key: Dictionary = {}
	for element_id: int in assembly.element_ids:
		var element: SimulationElement = world.get_element(element_id)
		if element == null:
			continue
		var element_archetype := element.get_archetype()
		if element_archetype == null:
			continue
		var face_start := faces.size() / FACE_STRIDE
		var face_count := 0
		for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
			GridSurfaceUtil.get_surface_descriptors(
				element_archetype,
				element.orientation_index
			)
		):
			var port_key := "%s|%s" % [descriptor.structural_id, descriptor.socket_tag]
			var port_index: int
			if port_index_by_key.has(port_key):
				port_index = int(port_index_by_key[port_key])
			else:
				port_index = port_ids.size()
				port_index_by_key[port_key] = port_index
				port_ids.append(descriptor.structural_id)
				socket_tags.append(descriptor.socket_tag)
			faces.append(descriptor.local_cell.x)
			faces.append(descriptor.local_cell.y)
			faces.append(descriptor.local_cell.z)
			faces.append(int(descriptor.local_face))
			faces.append(port_index)
			face_count += 1
		elements.append(element_id)
		elements.append(element.origin_cell.x)
		elements.append(element.origin_cell.y)
		elements.append(element.origin_cell.z)
		elements.append(element.orientation_index)
		elements.append(element_archetype.footprint_cells.size())
		elements.append(face_start)
		elements.append(face_count)
	var packed := {
		"revision": assembly.topology_revision,
		"occupancy": pack_occupancy(occupancy),
		"elements": elements,
		"faces": faces,
		"port_ids": port_ids,
		"socket_tags": socket_tags,
	}
	_assembly_attach_cache[assembly.assembly_id] = packed
	return packed


static func _packed_archetype_attach(
	archetype: ElementArchetype,
	orientation_index: int
) -> Dictionary:
	var cache_key := _archetype_orientation_key(archetype, orientation_index)
	if _flat_archetype_cache.has(cache_key):
		return _flat_archetype_cache[cache_key]
	var footprint := PackedInt32Array()
	for local_cell: Vector3i in archetype.footprint_cells:
		footprint.append(local_cell.x)
		footprint.append(local_cell.y)
		footprint.append(local_cell.z)
	var faces := PackedInt32Array()
	var port_ids := PackedStringArray()
	var socket_tags := PackedStringArray()
	for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
		GridSurfaceUtil.get_surface_descriptors(archetype, orientation_index)
	):
		var port_index := port_ids.size()
		port_ids.append(descriptor.structural_id)
		socket_tags.append(descriptor.socket_tag)
		faces.append(descriptor.local_cell.x)
		faces.append(descriptor.local_cell.y)
		faces.append(descriptor.local_cell.z)
		faces.append(int(descriptor.local_face))
		faces.append(port_index)
	var packed := {
		"footprint_size": archetype.footprint_cells.size(),
		"footprint": footprint,
		"faces": faces,
		"port_ids": port_ids,
		"socket_tags": socket_tags,
	}
	_flat_archetype_cache[cache_key] = packed
	return packed


static func _packed_body_groups(world, assembly_id: int) -> Dictionary:
	var t0 := ConstructionPerf.begin()
	var empty := {
		"element_to_group": PackedInt32Array(),
		"driven_bridges": PackedInt32Array(),
	}
	if world == null or not world.has_method("compile_body_groups"):
		ConstructionPerf.end(&"body_groups_us", t0)
		return empty
	var compiled: Dictionary = world.compile_body_groups(assembly_id)
	if not bool(compiled.get("valid", false)):
		ConstructionPerf.end(&"body_groups_us", t0)
		return empty
	var element_to_group_dict: Dictionary = compiled.get("element_to_group", {})
	var element_to_group := PackedInt32Array()
	element_to_group.resize(element_to_group_dict.size() * 2)
	var i := 0
	for element_id_variant: Variant in element_to_group_dict.keys():
		element_to_group[i] = int(element_id_variant)
		element_to_group[i + 1] = int(element_to_group_dict[element_id_variant])
		i += 2
	var driven_bridges := PackedInt32Array()
	for spec_variant: Variant in compiled.get("driven_specs", []):
		if not spec_variant is Dictionary:
			continue
		var spec: Dictionary = spec_variant
		driven_bridges.append(int(spec.get("base_group_id", 0)))
		driven_bridges.append(int(spec.get("head_group_id", 0)))
	ConstructionPerf.end(&"body_groups_us", t0)
	return {
		"element_to_group": element_to_group,
		"driven_bridges": driven_bridges,
	}


static func _cached_faces(
	archetype: ElementArchetype,
	orientation_index: int
) -> Array:
	var cache_key := _archetype_orientation_key(archetype, orientation_index)
	if _faces_cache.has(cache_key):
		return _faces_cache[cache_key]
	var faces: Array = []
	for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
		GridSurfaceUtil.get_surface_descriptors(archetype, orientation_index)
	):
		faces.append({
			"local_cell": descriptor.local_cell,
			"local_face": int(descriptor.local_face),
			"port_id": descriptor.structural_id,
			"socket_tag": descriptor.socket_tag,
		})
	_faces_cache[cache_key] = faces
	return faces


static func _archetype_orientation_key(
	archetype: ElementArchetype,
	orientation_index: int
) -> String:
	return "%s|%d" % [archetype.archetype_id, orientation_index]


static func _sync_socket_rules(kernel: RefCounted) -> void:
	var pairs := PackedStringArray()
	var table := ConnectorRuleTable.default_table()
	if table == null:
		kernel.call("set_compatible_tag_pairs", pairs)
		return
	for rule: ConnectorRule in table.rules:
		if rule == null:
			continue
		var a := ConnectorRuleTable.normalize_tag(rule.tag_a)
		var b := ConnectorRuleTable.normalize_tag(rule.tag_b)
		pairs.append("%s|%s" % [a, b])
	kernel.call("set_compatible_tag_pairs", pairs)
