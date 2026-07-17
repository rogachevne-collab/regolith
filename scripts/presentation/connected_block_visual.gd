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
	"rover_frame": true,
}

const RIM_FRACTION := 0.08
const RIM_MIN_M := 0.02
const RIM_MAX_M := 0.10
## Keep 0 so perpendicular faces of one cube share edges. A positive outward
## bias opens visible cracks at cube edges under soft rendering.
const FACE_BIAS_M := 0.0

static var _mesh_cache: Dictionary = {}


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
	for edge: Dictionary in _silhouette_edges():
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


static func rim_thickness(size: Vector3) -> float:
	return clampf(
		minf(size.x, minf(size.y, size.z)) * RIM_FRACTION,
		RIM_MIN_M,
		RIM_MAX_M
	)


static func make_fill_mesh(size: Vector3, face_mask: int) -> ArrayMesh:
	var cached := _cache_get(size, face_mask, "fill")
	if cached != null:
		return cached
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := size * 0.5
	var rim := rim_thickness(size)
	var wrote := false
	for face: OrientationUtil.Face in FACE_ORDER:
		if is_face_occluded(face_mask, face):
			continue
		_add_face_fill(st, face, half, rim, face_mask)
		wrote = true
	var mesh := _commit_or_empty(st, wrote)
	_cache_put(size, face_mask, "fill", mesh)
	return mesh


static func make_rim_mesh(size: Vector3, face_mask: int) -> ArrayMesh:
	var cached := _cache_get(size, face_mask, "rim")
	if cached != null:
		return cached
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := size * 0.5
	var rim := rim_thickness(size)
	var wrote := false
	for face: OrientationUtil.Face in FACE_ORDER:
		if is_face_occluded(face_mask, face):
			continue
		if _add_face_rim(st, face, half, rim, face_mask):
			wrote = true
	var mesh := _commit_or_empty(st, wrote)
	_cache_put(size, face_mask, "rim", mesh)
	return mesh


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


static func _cache_key(size: Vector3, face_mask: int, kind: String) -> String:
	return "%s:%.5f_%.5f_%.5f_%d" % [kind, size.x, size.y, size.z, face_mask]


static func _cache_get(size: Vector3, face_mask: int, kind: String) -> ArrayMesh:
	var key := _cache_key(size, face_mask, kind)
	if _mesh_cache.has(key):
		return _mesh_cache[key] as ArrayMesh
	return null


static func _cache_put(
	size: Vector3,
	face_mask: int,
	kind: String,
	mesh: ArrayMesh
) -> void:
	_mesh_cache[_cache_key(size, face_mask, kind)] = mesh


static func _commit_or_empty(st: SurfaceTool, wrote: bool) -> ArrayMesh:
	if not wrote:
		return ArrayMesh.new()
	return st.commit()


## Face basis: outward normal N, tangent T, bitangent B with N = T × B.
## In-face extents come from half along T/B axes.
static func _face_basis(face: OrientationUtil.Face) -> Dictionary:
	match face:
		OrientationUtil.Face.POS_X:
			return {
				"normal": Vector3.RIGHT,
				"tangent": Vector3.UP,
				"bitangent": Vector3.BACK,
			}
		OrientationUtil.Face.NEG_X:
			return {
				"normal": Vector3.LEFT,
				"tangent": Vector3.UP,
				"bitangent": Vector3.FORWARD,
			}
		OrientationUtil.Face.POS_Y:
			return {
				"normal": Vector3.UP,
				"tangent": Vector3.RIGHT,
				"bitangent": Vector3.FORWARD,
			}
		OrientationUtil.Face.NEG_Y:
			return {
				"normal": Vector3.DOWN,
				"tangent": Vector3.RIGHT,
				"bitangent": Vector3.BACK,
			}
		OrientationUtil.Face.POS_Z:
			return {
				"normal": Vector3.BACK,
				"tangent": Vector3.RIGHT,
				"bitangent": Vector3.UP,
			}
		_:
			return {
				"normal": Vector3.FORWARD,
				"tangent": Vector3.LEFT,
				"bitangent": Vector3.UP,
			}


static func _adjacent_faces(face: OrientationUtil.Face) -> Dictionary:
	## Edges of a face panel: -T, +T, -B, +B → neighbouring cube faces.
	match face:
		OrientationUtil.Face.POS_X, OrientationUtil.Face.NEG_X:
			return {
				"neg_t": OrientationUtil.Face.NEG_Y,
				"pos_t": OrientationUtil.Face.POS_Y,
				"neg_b": (
					OrientationUtil.Face.NEG_Z
					if face == OrientationUtil.Face.POS_X
					else OrientationUtil.Face.POS_Z
				),
				"pos_b": (
					OrientationUtil.Face.POS_Z
					if face == OrientationUtil.Face.POS_X
					else OrientationUtil.Face.NEG_Z
				),
			}
		OrientationUtil.Face.POS_Y, OrientationUtil.Face.NEG_Y:
			return {
				"neg_t": OrientationUtil.Face.NEG_X,
				"pos_t": OrientationUtil.Face.POS_X,
				"neg_b": (
					OrientationUtil.Face.POS_Z
					if face == OrientationUtil.Face.POS_Y
					else OrientationUtil.Face.NEG_Z
				),
				"pos_b": (
					OrientationUtil.Face.NEG_Z
					if face == OrientationUtil.Face.POS_Y
					else OrientationUtil.Face.POS_Z
				),
			}
		OrientationUtil.Face.POS_Z, OrientationUtil.Face.NEG_Z:
			return {
				"neg_t": (
					OrientationUtil.Face.NEG_X
					if face == OrientationUtil.Face.POS_Z
					else OrientationUtil.Face.POS_X
				),
				"pos_t": (
					OrientationUtil.Face.POS_X
					if face == OrientationUtil.Face.POS_Z
					else OrientationUtil.Face.NEG_X
				),
				"neg_b": OrientationUtil.Face.NEG_Y,
				"pos_b": OrientationUtil.Face.POS_Y,
			}
	return {}


static func _half_on_axis(half: Vector3, axis: Vector3) -> float:
	return absf(half.x * axis.x + half.y * axis.y + half.z * axis.z)


static func _face_origin(half: Vector3, normal: Vector3) -> Vector3:
	return normal * (_half_on_axis(half, normal) + FACE_BIAS_M)


static func _add_face_fill(
	st: SurfaceTool,
	face: OrientationUtil.Face,
	half: Vector3,
	rim: float,
	face_mask: int
) -> void:
	var basis := _face_basis(face)
	var normal: Vector3 = basis["normal"]
	var tangent: Vector3 = basis["tangent"]
	var bitangent: Vector3 = basis["bitangent"]
	var extent_t := _half_on_axis(half, tangent)
	var extent_b := _half_on_axis(half, bitangent)
	## Inset fill only where a rim strip is drawn. On connected seams the
	## adjacent face is occluded → no rim → fill must reach the full edge
	## or a rim-width gap appears at the join.
	var adj := _adjacent_faces(face)
	var u0 := -extent_t + (
		rim if not is_face_occluded(face_mask, adj["neg_t"]) else 0.0
	)
	var u1 := extent_t - (
		rim if not is_face_occluded(face_mask, adj["pos_t"]) else 0.0
	)
	var v0 := -extent_b + (
		rim if not is_face_occluded(face_mask, adj["neg_b"]) else 0.0
	)
	var v1 := extent_b - (
		rim if not is_face_occluded(face_mask, adj["pos_b"]) else 0.0
	)
	if u1 <= u0 or v1 <= v0:
		return
	var origin := _face_origin(half, normal)
	_add_quad_outward(
		st,
		origin,
		tangent,
		bitangent,
		u0,
		u1,
		v0,
		v1,
		normal
	)


static func _add_face_rim(
	st: SurfaceTool,
	face: OrientationUtil.Face,
	half: Vector3,
	rim: float,
	face_mask: int
) -> bool:
	var basis := _face_basis(face)
	var normal: Vector3 = basis["normal"]
	var tangent: Vector3 = basis["tangent"]
	var bitangent: Vector3 = basis["bitangent"]
	var extent_t := _half_on_axis(half, tangent)
	var extent_b := _half_on_axis(half, bitangent)
	if extent_t <= rim or extent_b <= rim:
		return false
	var adj := _adjacent_faces(face)
	var draw_neg_t := not is_face_occluded(face_mask, adj["neg_t"])
	var draw_pos_t := not is_face_occluded(face_mask, adj["pos_t"])
	var draw_neg_b := not is_face_occluded(face_mask, adj["neg_b"])
	var draw_pos_b := not is_face_occluded(face_mask, adj["pos_b"])
	var origin := _face_origin(half, normal)
	var wrote := false

	## Strip span: inset by rim only when that end has a corner pad.
	## On a connected seam the adjacent face is occluded → strip runs to
	## the face edge so the outer perimeter stays continuous.
	var t_lo := -extent_t + (rim if draw_neg_t else 0.0)
	var t_hi := extent_t - (rim if draw_pos_t else 0.0)
	var b_lo := -extent_b + (rim if draw_neg_b else 0.0)
	var b_hi := extent_b - (rim if draw_pos_b else 0.0)

	if draw_neg_t and b_hi > b_lo:
		_add_quad_outward(
			st,
			origin,
			tangent,
			bitangent,
			-extent_t,
			-extent_t + rim,
			b_lo,
			b_hi,
			normal
		)
		wrote = true
	if draw_pos_t and b_hi > b_lo:
		_add_quad_outward(
			st,
			origin,
			tangent,
			bitangent,
			extent_t - rim,
			extent_t,
			b_lo,
			b_hi,
			normal
		)
		wrote = true
	if draw_neg_b and t_hi > t_lo:
		_add_quad_outward(
			st,
			origin,
			tangent,
			bitangent,
			t_lo,
			t_hi,
			-extent_b,
			-extent_b + rim,
			normal
		)
		wrote = true
	if draw_pos_b and t_hi > t_lo:
		_add_quad_outward(
			st,
			origin,
			tangent,
			bitangent,
			t_lo,
			t_hi,
			extent_b - rim,
			extent_b,
			normal
		)
		wrote = true

	if draw_neg_t and draw_neg_b:
		_add_quad_outward(
			st,
			origin,
			tangent,
			bitangent,
			-extent_t,
			-extent_t + rim,
			-extent_b,
			-extent_b + rim,
			normal
		)
		wrote = true
	if draw_neg_t and draw_pos_b:
		_add_quad_outward(
			st,
			origin,
			tangent,
			bitangent,
			-extent_t,
			-extent_t + rim,
			extent_b - rim,
			extent_b,
			normal
		)
		wrote = true
	if draw_pos_t and draw_neg_b:
		_add_quad_outward(
			st,
			origin,
			tangent,
			bitangent,
			extent_t - rim,
			extent_t,
			-extent_b,
			-extent_b + rim,
			normal
		)
		wrote = true
	if draw_pos_t and draw_pos_b:
		_add_quad_outward(
			st,
			origin,
			tangent,
			bitangent,
			extent_t - rim,
			extent_t,
			extent_b - rim,
			extent_b,
			normal
		)
		wrote = true
	return wrote


## Emit a face-aligned quad. Vertex order is clockwise from outside when
## N = T × B and u0 < u1, v0 < v1 (Godot front-face winding).
static func _add_quad_outward(
	st: SurfaceTool,
	origin: Vector3,
	tangent: Vector3,
	bitangent: Vector3,
	u0: float,
	u1: float,
	v0: float,
	v1: float,
	normal: Vector3
) -> void:
	var a := origin + tangent * u0 + bitangent * v0
	var b := origin + tangent * u0 + bitangent * v1
	var c := origin + tangent * u1 + bitangent * v1
	var d := origin + tangent * u1 + bitangent * v0
	st.set_normal(normal)
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.set_normal(normal)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)


static func _silhouette_edges() -> Array[Dictionary]:
	return [
		{
			"face_a": OrientationUtil.Face.POS_Y,
			"face_b": OrientationUtil.Face.POS_Z,
		},
		{
			"face_a": OrientationUtil.Face.POS_Y,
			"face_b": OrientationUtil.Face.NEG_Z,
		},
		{
			"face_a": OrientationUtil.Face.NEG_Y,
			"face_b": OrientationUtil.Face.POS_Z,
		},
		{
			"face_a": OrientationUtil.Face.NEG_Y,
			"face_b": OrientationUtil.Face.NEG_Z,
		},
		{
			"face_a": OrientationUtil.Face.POS_X,
			"face_b": OrientationUtil.Face.POS_Z,
		},
		{
			"face_a": OrientationUtil.Face.POS_X,
			"face_b": OrientationUtil.Face.NEG_Z,
		},
		{
			"face_a": OrientationUtil.Face.NEG_X,
			"face_b": OrientationUtil.Face.POS_Z,
		},
		{
			"face_a": OrientationUtil.Face.NEG_X,
			"face_b": OrientationUtil.Face.NEG_Z,
		},
		{
			"face_a": OrientationUtil.Face.POS_X,
			"face_b": OrientationUtil.Face.POS_Y,
		},
		{
			"face_a": OrientationUtil.Face.POS_X,
			"face_b": OrientationUtil.Face.NEG_Y,
		},
		{
			"face_a": OrientationUtil.Face.NEG_X,
			"face_b": OrientationUtil.Face.POS_Y,
		},
		{
			"face_a": OrientationUtil.Face.NEG_X,
			"face_b": OrientationUtil.Face.NEG_Y,
		},
	]
