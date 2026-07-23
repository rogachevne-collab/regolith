extends MeshInstance3D
# Internal rope visual: one continuous tube swept along a Catmull-Rom curve
# through the particles — no per-segment seams. Parallel-transport frames
# prevent twisting; vertex colors show tension (green -> red at tension_ref).
# Strictly a read-only view of the sim: interpolates between the two latest
# physics states, feeds nothing back.
#
# Topology is DERIVED from the state pushed in, never configured separately:
# a rope that re-seeds to a different particle count simply pushes a new
# state and the mesh follows. There is no "configured but unfed" state to
# desync (ADR 0004).
#
# The mesh arrays are rebuilt every frame (fine at demo scale in GDScript;
# the native renderer will reuse buffers).

const RADIAL := 8
const SUBDIV := 2  # curve samples per rope segment

var _prev := PackedVector3Array()
var _curr := PackedVector3Array()
var _tensions := PackedFloat64Array()
var _radius := 0.02
var _tension_ref := 1.0

var _mesh: ArrayMesh
var _indices := PackedInt32Array()
var _particles := 0
var _rings := 0


## Visual parameters only — safe to call at any time.
func configure(rope_radius: float, tension_ref: float) -> void:
	top_level = true
	transform = Transform3D.IDENTITY
	_radius = rope_radius
	_tension_ref = maxf(tension_ref, 0.001)
	if _mesh == null:
		_mesh = ArrayMesh.new()
		mesh = _mesh
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.7
		material_override = mat


func push_state(prev: PackedVector3Array, curr: PackedVector3Array,
		tensions: PackedFloat64Array) -> void:
	if curr.size() != _particles:
		_resize_topology(curr.size())
	_prev = prev if prev.size() == curr.size() else curr
	_curr = curr
	_tensions = tensions


func update_visual(fraction: float) -> void:
	if _mesh == null or _particles < 2 or _curr.size() != _particles:
		return
	var pts := PackedVector3Array()
	pts.resize(_particles)
	for i in _particles:
		pts[i] = _prev[i].lerp(_curr[i], fraction)

	# Per-particle tension (avg of adjacent segments) for smooth coloring.
	var pt_tension := PackedFloat64Array()
	pt_tension.resize(_particles)
	for i in _particles:
		var lo := maxi(i - 1, 0)
		var hi := mini(i, _tensions.size() - 1)
		pt_tension[i] = 0.0 if hi < 0 else (_tensions[lo] + _tensions[hi]) * 0.5

	# Catmull-Rom curve through particles.
	var curve := PackedVector3Array()
	var curve_t := PackedFloat64Array()
	curve.resize(_rings)
	curve_t.resize(_rings)
	var out := 0
	for j in _particles - 1:
		var p0 := pts[maxi(j - 1, 0)]
		var p1 := pts[j]
		var p2 := pts[j + 1]
		var p3 := pts[mini(j + 2, _particles - 1)]
		for s in SUBDIV:
			var t := float(s) / SUBDIV
			curve[out] = _catmull_rom(p0, p1, p2, p3, t)
			curve_t[out] = lerpf(pt_tension[j], pt_tension[j + 1], t)
			out += 1
	curve[out] = pts[_particles - 1]
	curve_t[out] = pt_tension[_particles - 1]

	_build_tube(curve, curve_t)


func _resize_topology(particle_count: int) -> void:
	_particles = particle_count
	_rings = maxi(particle_count - 1, 0) * SUBDIV + 1
	_build_indices()


func _build_tube(curve: PackedVector3Array, curve_t: PackedFloat64Array) -> void:
	var rings := curve.size()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(rings * RADIAL + 2)
	normals.resize(rings * RADIAL + 2)
	colors.resize(rings * RADIAL + 2)

	# Parallel-transport frame along the curve.
	var tangent := _tangent_at(curve, 0)
	var normal := Vector3.RIGHT if absf(tangent.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	normal = (normal - tangent * normal.dot(tangent)).normalized()
	for i in rings:
		var new_tangent := _tangent_at(curve, i)
		var d := tangent.dot(new_tangent)
		if d < -0.9999:
			normal = -normal
		elif d < 0.9999:
			normal = Quaternion(tangent, new_tangent) * normal
			normal = (normal - new_tangent * normal.dot(new_tangent)).normalized()
		tangent = new_tangent
		var binormal := tangent.cross(normal)
		var color := _tension_color(curve_t[i])
		for k in RADIAL:
			var ang := TAU * float(k) / RADIAL
			var radial := normal * cos(ang) + binormal * sin(ang)
			var idx := i * RADIAL + k
			verts[idx] = curve[i] + radial * _radius
			normals[idx] = radial
			colors[idx] = color

	# Cap centers.
	var cap_a := rings * RADIAL
	var cap_b := cap_a + 1
	verts[cap_a] = curve[0]
	normals[cap_a] = -_tangent_at(curve, 0)
	colors[cap_a] = _tension_color(curve_t[0])
	verts[cap_b] = curve[rings - 1]
	normals[cap_b] = _tangent_at(curve, rings - 1)
	colors[cap_b] = _tension_color(curve_t[rings - 1])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = _indices
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _build_indices() -> void:
	_indices.clear()
	if _rings < 2:
		return
	for i in _rings - 1:
		for k in RADIAL:
			var k2 := (k + 1) % RADIAL
			var a := i * RADIAL + k
			var b := i * RADIAL + k2
			var c := (i + 1) * RADIAL + k
			var d := (i + 1) * RADIAL + k2
			_indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
	var cap_a := _rings * RADIAL
	var cap_b := cap_a + 1
	var base := (_rings - 1) * RADIAL
	for k in RADIAL:
		var k2 := (k + 1) % RADIAL
		_indices.append_array(PackedInt32Array([cap_a, k2, k]))
		_indices.append_array(PackedInt32Array([cap_b, base + k, base + k2]))


func _tangent_at(curve: PackedVector3Array, i: int) -> Vector3:
	var a := curve[maxi(i - 1, 0)]
	var b := curve[mini(i + 1, curve.size() - 1)]
	var d := b - a
	var len_sq := d.length_squared()
	if len_sq < 1e-16:
		return Vector3.DOWN
	return d / sqrt(len_sq)


func _tension_color(tension: float) -> Color:
	var t := clampf(tension / _tension_ref, 0.0, 1.0)
	return Color.from_hsv(0.33 * (1.0 - t), 0.85, 0.9)


func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1)
			+ (-p0 + p2) * t
			+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
