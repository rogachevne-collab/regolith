class_name ConnectedBlockVisual
extends RefCounted

## Procedural SE-style connected cube visuals for frame / large_frame PoC.
## Spec: docs/specs/CONNECTED-BLOCK-VISUAL-POC.md

const FACE_ORDER: Array[OrientationUtil.Face] = [
	OrientationUtil.Face.POS_X,
	OrientationUtil.Face.NEG_X,
	OrientationUtil.Face.POS_Y,
	OrientationUtil.Face.NEG_Y,
	OrientationUtil.Face.POS_Z,
	OrientationUtil.Face.NEG_Z,
]

const CONNECTED_ARCHETYPES := {
	"frame": true,
	"frame_basalt": true,
	"large_frame": true,
}

const FACE_INSET_M := 0.0005
const RIM_FRACTION := 0.08
const RIM_MIN_M := 0.015
const RIM_MAX_M := 0.08


static func is_connected_archetype(archetype_id: String) -> bool:
	return CONNECTED_ARCHETYPES.has(archetype_id)


static func build_occupancy(
	world: SimulationWorld,
	assembly: SimulationAssembly
) -> Dictionary:
	var occupancy: Dictionary = {}
	var archetype_by_element: Dictionary = {}
	if world == null or assembly == null:
		return {"cells": occupancy, "archetypes": archetype_by_element}
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null:
			continue
		var archetype := element.get_archetype()
		if archetype == null:
			continue
		archetype_by_element[element_id] = element.archetype_id
		for cell: Vector3i in archetype.get_occupied_cells(
			element.origin_cell,
			element.orientation_index
		):
			occupancy[cell] = element_id
	return {"cells": occupancy, "archetypes": archetype_by_element}


static func face_occlusion_mask(
	element: SimulationElement,
	occupancy_cells: Dictionary,
	archetype_by_element: Dictionary
) -> int:
	if element == null:
		return 0
	var archetype := element.get_archetype()
	if archetype == null:
		return 0
	var occupied: Dictionary = {}
	var cells: Array[Vector3i] = archetype.get_occupied_cells(
		element.origin_cell,
		element.orientation_index
	)
	for cell: Vector3i in cells:
		occupied[cell] = true
	var mask := 0
	for face: OrientationUtil.Face in FACE_ORDER:
		var offset := OrientationUtil.face_to_vector(face)
		var external: Array[Vector3i] = []
		for cell: Vector3i in cells:
			if occupied.has(cell + offset):
				continue
			external.append(cell)
		if external.is_empty():
			continue
		var fully_covered := true
		for cell: Vector3i in external:
			var neighbour_id: Variant = occupancy_cells.get(cell + offset)
			if neighbour_id == null or int(neighbour_id) == element.element_id:
				fully_covered = false
				break
			var neighbour_archetype := String(
				archetype_by_element.get(int(neighbour_id), "")
			)
			if not _same_merge_family(element.archetype_id, neighbour_archetype):
				fully_covered = false
				break
		if fully_covered:
			mask |= 1 << int(face)
	return mask


static func is_face_occluded(mask: int, face: OrientationUtil.Face) -> bool:
	return (mask & (1 << int(face))) != 0


static func visible_edge_count(face_mask: int) -> int:
	var count := 0
	for edge: Dictionary in _cube_edges():
		var face_a: OrientationUtil.Face = edge["face_a"]
		var face_b: OrientationUtil.Face = edge["face_b"]
		if is_face_occluded(face_mask, face_a):
			continue
		if is_face_occluded(face_mask, face_b):
			continue
		count += 1
	return count


static func visible_face_count(face_mask: int) -> int:
	var count := 0
	for face: OrientationUtil.Face in FACE_ORDER:
		if not is_face_occluded(face_mask, face):
			count += 1
	return count


static func make_fill_mesh(size: Vector3, face_mask: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := size * 0.5
	for face: OrientationUtil.Face in FACE_ORDER:
		if is_face_occluded(face_mask, face):
			continue
		_add_face_quad(st, face, half, FACE_INSET_M)
	st.generate_normals()
	return st.commit()


static func make_rim_mesh(size: Vector3, face_mask: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := size * 0.5
	var rim := clampf(
		minf(size.x, minf(size.y, size.z)) * RIM_FRACTION,
		RIM_MIN_M,
		RIM_MAX_M
	)
	for edge: Dictionary in _cube_edges():
		var face_a: OrientationUtil.Face = edge["face_a"]
		var face_b: OrientationUtil.Face = edge["face_b"]
		if is_face_occluded(face_mask, face_a):
			continue
		if is_face_occluded(face_mask, face_b):
			continue
		_add_edge_box(st, edge, half, rim)
	st.generate_normals()
	return st.commit()


static func attach_element_visual(
	body: PhysicsBody3D,
	assembly_id: int,
	element: SimulationElement,
	collider: ColliderDefinition,
	collider_index: int,
	face_mask: int,
	fill_material: Material,
	rim_material: Material
) -> void:
	var root := Node3D.new()
	root.name = "ElementVisual_%d_%d" % [element.element_id, collider_index]
	root.set_meta("element_visual", true)
	root.set_meta("assembly_id", assembly_id)
	root.set_meta("connected_block_visual", true)
	root.transform = GridPoseUtil.collider_local_transform(
		element.origin_cell,
		element.orientation_index,
		collider
	)

	var fill := MeshInstance3D.new()
	fill.name = "Fill"
	fill.mesh = make_fill_mesh(collider.size, face_mask)
	fill.material_override = fill_material
	root.add_child(fill)

	var rim := MeshInstance3D.new()
	rim.name = "Rim"
	rim.mesh = make_rim_mesh(collider.size, face_mask)
	rim.material_override = rim_material
	root.add_child(rim)

	body.add_child(root)


static func _same_merge_family(a: String, b: String) -> bool:
	return not a.is_empty() and a == b


static func _cube_edges() -> Array[Dictionary]:
	return [
		{
			"face_a": OrientationUtil.Face.POS_Y,
			"face_b": OrientationUtil.Face.POS_Z,
			"axis": 0,
			"sy": 1,
			"sz": 1,
		},
		{
			"face_a": OrientationUtil.Face.POS_Y,
			"face_b": OrientationUtil.Face.NEG_Z,
			"axis": 0,
			"sy": 1,
			"sz": -1,
		},
		{
			"face_a": OrientationUtil.Face.NEG_Y,
			"face_b": OrientationUtil.Face.POS_Z,
			"axis": 0,
			"sy": -1,
			"sz": 1,
		},
		{
			"face_a": OrientationUtil.Face.NEG_Y,
			"face_b": OrientationUtil.Face.NEG_Z,
			"axis": 0,
			"sy": -1,
			"sz": -1,
		},
		{
			"face_a": OrientationUtil.Face.POS_X,
			"face_b": OrientationUtil.Face.POS_Z,
			"axis": 1,
			"sx": 1,
			"sz": 1,
		},
		{
			"face_a": OrientationUtil.Face.POS_X,
			"face_b": OrientationUtil.Face.NEG_Z,
			"axis": 1,
			"sx": 1,
			"sz": -1,
		},
		{
			"face_a": OrientationUtil.Face.NEG_X,
			"face_b": OrientationUtil.Face.POS_Z,
			"axis": 1,
			"sx": -1,
			"sz": 1,
		},
		{
			"face_a": OrientationUtil.Face.NEG_X,
			"face_b": OrientationUtil.Face.NEG_Z,
			"axis": 1,
			"sx": -1,
			"sz": -1,
		},
		{
			"face_a": OrientationUtil.Face.POS_X,
			"face_b": OrientationUtil.Face.POS_Y,
			"axis": 2,
			"sx": 1,
			"sy": 1,
		},
		{
			"face_a": OrientationUtil.Face.POS_X,
			"face_b": OrientationUtil.Face.NEG_Y,
			"axis": 2,
			"sx": 1,
			"sy": -1,
		},
		{
			"face_a": OrientationUtil.Face.NEG_X,
			"face_b": OrientationUtil.Face.POS_Y,
			"axis": 2,
			"sx": -1,
			"sy": 1,
		},
		{
			"face_a": OrientationUtil.Face.NEG_X,
			"face_b": OrientationUtil.Face.NEG_Y,
			"axis": 2,
			"sx": -1,
			"sy": -1,
		},
	]


static func _add_face_quad(
	st: SurfaceTool,
	face: OrientationUtil.Face,
	half: Vector3,
	inset: float
) -> void:
	var hx := half.x - inset
	var hy := half.y - inset
	var hz := half.z - inset
	match face:
		OrientationUtil.Face.POS_X:
			_add_quad(
				st,
				Vector3(half.x - inset, -hy, -hz),
				Vector3(half.x - inset, -hy, hz),
				Vector3(half.x - inset, hy, hz),
				Vector3(half.x - inset, hy, -hz),
				Vector3.RIGHT
			)
		OrientationUtil.Face.NEG_X:
			_add_quad(
				st,
				Vector3(-half.x + inset, -hy, hz),
				Vector3(-half.x + inset, -hy, -hz),
				Vector3(-half.x + inset, hy, -hz),
				Vector3(-half.x + inset, hy, hz),
				Vector3.LEFT
			)
		OrientationUtil.Face.POS_Y:
			_add_quad(
				st,
				Vector3(-hx, half.y - inset, -hz),
				Vector3(hx, half.y - inset, -hz),
				Vector3(hx, half.y - inset, hz),
				Vector3(-hx, half.y - inset, hz),
				Vector3.UP
			)
		OrientationUtil.Face.NEG_Y:
			_add_quad(
				st,
				Vector3(-hx, -half.y + inset, hz),
				Vector3(hx, -half.y + inset, hz),
				Vector3(hx, -half.y + inset, -hz),
				Vector3(-hx, -half.y + inset, -hz),
				Vector3.DOWN
			)
		OrientationUtil.Face.POS_Z:
			_add_quad(
				st,
				Vector3(-hx, -hy, half.z - inset),
				Vector3(hx, -hy, half.z - inset),
				Vector3(hx, hy, half.z - inset),
				Vector3(-hx, hy, half.z - inset),
				Vector3.BACK
			)
		OrientationUtil.Face.NEG_Z:
			_add_quad(
				st,
				Vector3(hx, -hy, -half.z + inset),
				Vector3(-hx, -hy, -half.z + inset),
				Vector3(-hx, hy, -half.z + inset),
				Vector3(hx, hy, -half.z + inset),
				Vector3.FORWARD
			)


static func _add_quad(
	st: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3
) -> void:
	st.set_normal(normal)
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)


static func _add_edge_box(
	st: SurfaceTool,
	edge: Dictionary,
	half: Vector3,
	rim: float
) -> void:
	var axis: int = edge["axis"]
	var hx := rim * 0.5
	var corners: Array[Vector3] = []
	match axis:
		0:
			var y: float = float(edge["sy"]) * half.y
			var z: float = float(edge["sz"]) * half.z
			var x0 := -half.x + rim
			var x1 := half.x - rim
			if x1 <= x0:
				return
			corners = _box_corners(
				Vector3(x0, y - hx, z - hx),
				Vector3(x1, y + hx, z + hx)
			)
		1:
			var x: float = float(edge["sx"]) * half.x
			var z: float = float(edge["sz"]) * half.z
			var y0 := -half.y + rim
			var y1 := half.y - rim
			if y1 <= y0:
				return
			corners = _box_corners(
				Vector3(x - hx, y0, z - hx),
				Vector3(x + hx, y1, z + hx)
			)
		_:
			var x: float = float(edge["sx"]) * half.x
			var y: float = float(edge["sy"]) * half.y
			var z0 := -half.z + rim
			var z1 := half.z - rim
			if z1 <= z0:
				return
			corners = _box_corners(
				Vector3(x - hx, y - hx, z0),
				Vector3(x + hx, y + hx, z1)
			)
	_add_box_triangles(st, corners)


static func _box_corners(min_v: Vector3, max_v: Vector3) -> Array[Vector3]:
	return [
		Vector3(min_v.x, min_v.y, min_v.z),
		Vector3(max_v.x, min_v.y, min_v.z),
		Vector3(max_v.x, max_v.y, min_v.z),
		Vector3(min_v.x, max_v.y, min_v.z),
		Vector3(min_v.x, min_v.y, max_v.z),
		Vector3(max_v.x, min_v.y, max_v.z),
		Vector3(max_v.x, max_v.y, max_v.z),
		Vector3(min_v.x, max_v.y, max_v.z),
	]


static func _add_box_triangles(st: SurfaceTool, c: Array[Vector3]) -> void:
	_add_quad(st, c[0], c[3], c[2], c[1], Vector3.FORWARD)
	_add_quad(st, c[4], c[5], c[6], c[7], Vector3.BACK)
	_add_quad(st, c[0], c[1], c[5], c[4], Vector3.DOWN)
	_add_quad(st, c[3], c[7], c[6], c[2], Vector3.UP)
	_add_quad(st, c[0], c[4], c[7], c[3], Vector3.LEFT)
	_add_quad(st, c[1], c[2], c[6], c[5], Vector3.RIGHT)
