extends Node
## Is the native marching-cubes surface watertight, consistently wound, and
## seamless across chunk boundaries?
##
## The triangle table is generated and proven consistent combinatorially
## (`native/regolith_moon_bake/tools/gen_mc_tables.py` checks every pair of
## neighbouring configurations); this test checks the *runtime* end of it, on a
## real settled heap:
##
##   - closed: away from the field border, every triangle edge is shared by
##     exactly two triangles — a hole anywhere is a table or dedup bug;
##   - wound for Godot: front faces are clockwise, so a triangle's geometric
##     cross product must point against its vertices' outward field-gradient
##     normals, for every triangle — one flipped case reads as a black facet;
##   - seamless: the same field meshed as two adjacent boxes must produce
##     bit-identical vertices along the shared face, because both boxes
##     evaluate the same samples from the same inputs in the same order. Not
##     "close" — identical, or the chunk seams of the paste era come back.

const LABEL := "GRANULAR-MESHER"
const CELL := 0.25
## The view's own reconstruction knobs, mirrored so the test marches exactly
## what the game draws.
const SMOOTH_PASSES := 1
const SMOOTH_CENTRE := 4.0
const RENDER_MIN_FILL := 0.15
const SURFACE_ISO := 0.35
const SDF_GAIN := 2.0
const AIR_SDF := 1.0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("GranularVoxelField"):
		_fail("GranularVoxelField (native) is not registered — extension not loaded")
		return
	var field := _settled_heap()
	if not _test_closed_and_wound(field):
		return
	if not _test_seam_bit_identical(field):
		return
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


## A real heap, not a synthetic sphere: poured through the same deposit path
## the game uses and swept to rest, so the mesh under test has the fringe
## values, the rock bedding and the sub-threshold traces that broke things
## historically.
func _settled_heap() -> GranularVoxelField:
	var dims := Vector3i(48, 32, 48)
	var field := GranularVoxelField.create(dims, CELL)
	for z in dims.z:
		for x in dims.x:
			for y in 2:
				field.set_solid(x, y, z, true)
	for step in 10:
		for dz in range(-3, 4):
			for dx in range(-3, 4):
				field.deposit(24 + dx, 2 + step, 24 + dz, 0.8)
	# A second, small pile so the box holds more than one component.
	for step in 3:
		field.deposit(10, 2 + step, 10, 0.9)
	var sweeps := 0
	while not field.is_settled() and sweeps < 20000:
		field.step(0)
		sweeps += 1
	field.take_dirty()
	return field


func _mesh(field: GranularVoxelField, lo: Vector3i, extent: Vector3i) -> Array:
	return field.build_mesh_box(
		lo, extent,
		SMOOTH_PASSES, SMOOTH_CENTRE, RENDER_MIN_FILL,
		SURFACE_ISO, SDF_GAIN, AIR_SDF
	)


func _test_closed_and_wound(field: GranularVoxelField) -> bool:
	var dims: Vector3i = field.size
	var arrays := _mesh(field, Vector3i.ZERO, dims)
	if arrays.is_empty():
		_fail("a ten cubic metre heap meshed to nothing")
		return false
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices.size() % 3 != 0 or normals.size() != vertices.size():
		_fail(
			"malformed arrays: %d vertices, %d normals, %d indices"
			% [vertices.size(), normals.size(), indices.size()]
		)
		return false
	# Every directed edge must be answered by its reverse: that is closed and
	# consistently wound in one test. (The field is entirely interior to the
	# box here, so there is no mesh boundary to excuse.)
	var edges: Dictionary = {}
	var t := 0
	while t < indices.size():
		var a := indices[t]
		var b := indices[t + 1]
		var c := indices[t + 2]
		for pair: Vector2i in [Vector2i(a, b), Vector2i(b, c), Vector2i(c, a)]:
			edges[pair] = int(edges.get(pair, 0)) + 1
		t += 3
	for pair: Vector2i in edges:
		if edges[pair] != 1:
			_fail("directed edge %s used %d times" % [str(pair), edges[pair]])
			return false
		if not edges.has(Vector2i(pair.y, pair.x)):
			_fail("open edge %s — the surface has a hole" % str(pair))
			return false
	# Winding: Godot front faces are clockwise, so cross(b-a, c-a) points into
	# the body — against the outward gradient normals. Degenerate slivers
	# (near-zero cross product) are excused; a genuinely flipped triangle is
	# not.
	var flipped := 0
	var checked := 0
	t = 0
	while t < indices.size():
		var pa := vertices[indices[t]]
		var pb := vertices[indices[t + 1]]
		var pc := vertices[indices[t + 2]]
		var cross := (pb - pa).cross(pc - pa)
		var outward := (
			normals[indices[t]] + normals[indices[t + 1]] + normals[indices[t + 2]]
		)
		if cross.length() > 1e-9 and outward.length() > 1e-6:
			checked += 1
			if cross.dot(outward) > 0.0:
				flipped += 1
		t += 3
	if flipped > 0:
		_fail("%d of %d triangles wound against their normals" % [flipped, checked])
		return false
	print(
		"%s: closed and wound — %d vertices, %d triangles, all edges paired"
		% [LABEL, vertices.size(), indices.size() / 3]
	)
	return true


## Mesh the same heap as two boxes butted along x, exactly as the view meshes
## adjacent chunks, and demand the shared-plane vertices match to the bit.
func _test_seam_bit_identical(field: GranularVoxelField) -> bool:
	var dims: Vector3i = field.size
	var split := 24
	var left := _mesh(field, Vector3i.ZERO, Vector3i(split, dims.y, dims.z))
	var right := _mesh(
		field,
		Vector3i(split, 0, 0),
		Vector3i(dims.x - split, dims.y, dims.z)
	)
	if left.is_empty() or right.is_empty():
		_fail("the split boxes meshed to nothing (the heap straddles x=%d)" % split)
		return false
	var left_seam := _seam_vertices(left, split)
	var right_seam := _seam_vertices(right, split)
	if left_seam.is_empty():
		_fail("no seam vertices at x=%d — the split misses the heap" % split)
		return false
	if left_seam.size() != right_seam.size():
		_fail(
			"seam vertex counts differ: %d left, %d right"
			% [left_seam.size(), right_seam.size()]
		)
		return false
	for key: Vector3 in left_seam:
		if not right_seam.has(key):
			_fail("left seam vertex %s has no bit-identical twin" % str(key))
			return false
	print(
		"%s: seam at x=%d — %d vertices bit-identical from both sides"
		% [LABEL, split, left_seam.size()]
	)
	return true


## Vertices lying exactly on the given x-plane, as a set. Bit-exact keys on
## purpose: bit-exactness is the property under test.
func _seam_vertices(arrays: Array, plane_x: int) -> Dictionary:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var out: Dictionary = {}
	for v in vertices:
		if v.x == float(plane_x):
			out[v] = true
	return out


func _fail(message: String) -> void:
	push_error(message)
	print("%s: FAIL - %s" % [LABEL, message])
	get_tree().quit(1)
