class_name ConstructionPreviewKernelAccess
extends RefCounted
## Thin GDScript facade over ConstructionPreviewKernel GDExtension.
## Falls back to null when the native library is missing.

static var _kernel: RefCounted = null
static var _checked := false
static var _rules_synced := false


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


static func side_spec_from_archetype(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Dictionary:
	var faces: Array = []
	if archetype != null:
		for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
			GridSurfaceUtil.get_surface_descriptors(archetype, orientation_index)
		):
			faces.append({
				"local_cell": descriptor.local_cell,
				"local_face": int(descriptor.local_face),
				"port_id": descriptor.structural_id,
				"socket_tag": descriptor.socket_tag,
			})
	return {
		"origin_cell": origin_cell,
		"orientation_index": orientation_index,
		"footprint_size": (
			archetype.footprint_cells.size() if archetype != null else 0
		),
		"faces": faces,
	}


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
