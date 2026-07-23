class_name ConstructionPreviewKernelAccess
extends RefCounted
## Thin GDScript facade over ConstructionPreviewKernel GDExtension.
## Falls back to null when the native library is missing.

static var _kernel: RefCounted = null
static var _checked := false
static var _rules_synced := false
static var _faces_cache: Dictionary = {}
static var _footprint_cache: Dictionary = {}


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
	var kernel := get_kernel()
	if kernel == null or world == null or assembly == null or archetype == null:
		return {}
	var occupancy: Dictionary = ConstructionOccupancyUtil.assembly_occupancy_index(
		world,
		assembly
	)
	var preview_cells := preview_world_cells(
		archetype,
		origin_cell,
		orientation_index
	)
	var neighbour_ids: Array[int] = ConstructionOccupancyUtil.neighbour_element_ids(
		preview_cells,
		occupancy
	)
	var neighbour_sides: Array = []
	for existing_id: int in neighbour_ids:
		var existing: SimulationElement = world.get_element(existing_id)
		if existing == null:
			continue
		neighbour_sides.append({
			"element_id": existing_id,
			"side": side_spec_from_element(existing),
		})
	return kernel.call(
		"find_attach_connections",
		pack_occupancy(occupancy),
		pack_cells(preview_cells),
		side_spec_from_archetype(archetype, origin_cell, orientation_index),
		neighbour_sides
	)


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
