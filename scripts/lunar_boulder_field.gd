class_name LunarBoulderField
extends Node3D

## Runtime radial boulder field for the spherical moon.
## ProtonScatter's world-up slope test + sphere meshes were floating/ugly here.

@export var count := 48
@export var radius_m := 42.0
@export var min_radial_dot := 0.78 ## ~38° from upright — skip crater walls
@export var embed_m := 0.12
@export var collision_mask := 1
@export var rng_seed := 404

var _mmi_a: MultiMeshInstance3D
var _mmi_b: MultiMeshInstance3D


func build_around(center: Vector3, space: PhysicsDirectSpaceState3D) -> int:
	if space == null:
		return 0
	var up := center.normalized()
	if up.length_squared() < 0.0001:
		up = Vector3.UP
	var basis := _basis_from_up(up)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var mesh_a := _make_rock_mesh(rng_seed, 0.55, 0.9)
	var mesh_b := _make_rock_mesh(rng_seed + 17, 0.4, 1.15)
	var mat := _make_material()

	_mmi_a = _make_mmi(mesh_a, mat)
	_mmi_b = _make_mmi(mesh_b, mat)
	add_child(_mmi_a)
	add_child(_mmi_b)

	var xforms_a: Array[Transform3D] = []
	var xforms_b: Array[Transform3D] = []
	var attempts := 0
	var max_attempts := count * 14

	while (xforms_a.size() + xforms_b.size()) < count and attempts < max_attempts:
		attempts += 1
		var local := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
		if local.length_squared() > 1.0:
			continue
		local *= radius_m
		var sample := center + basis * local
		var radial := sample.normalized()
		var from := sample + radial * 40.0
		var to := sample - radial * 80.0
		var q := PhysicsRayQueryParameters3D.create(from, to, collision_mask)
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var n: Vector3 = hit.normal
		if n.dot(radial) < min_radial_dot:
			continue
		var pos: Vector3 = hit.position - n * embed_m
		var scale := rng.randf_range(0.65, 1.45)
		var yaw := rng.randf() * TAU
		var rock_basis := _basis_from_up(n).rotated(n, yaw)
		rock_basis = rock_basis.scaled(Vector3(
			scale * rng.randf_range(0.85, 1.25),
			scale * rng.randf_range(0.55, 0.85),
			scale * rng.randf_range(0.85, 1.2)
		))
		var xf := Transform3D(rock_basis, pos)
		if rng.randf() < 0.55:
			xforms_a.append(xf)
		else:
			xforms_b.append(xf)

	_fill_mmi(_mmi_a, xforms_a)
	_fill_mmi(_mmi_b, xforms_b)
	return xforms_a.size() + xforms_b.size()


func _make_mmi(mesh: ArrayMesh, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mmi


func _fill_mmi(mmi: MultiMeshInstance3D, xforms: Array[Transform3D]) -> void:
	var mm: MultiMesh = mmi.multimesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])


func _make_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var albedo := load("res://resources/textures/lunar_rock/albedo.png")
	var normal := load("res://resources/textures/lunar_rock/normal.png")
	if albedo != null:
		mat.albedo_texture = albedo
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
		mat.normal_scale = 1.2
	mat.roughness = 0.9
	mat.metallic = 0.0
	mat.specular = 0.12
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return mat


func _make_rock_mesh(seed_i: int, radius: float, stretch: float) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 1.35
	sphere.radial_segments = 10
	sphere.rings = 6
	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var min_y := 1e9
	for i in verts.size():
		var v := verts[i]
		var nrm := v.normalized()
		var bump := 0.78 + 0.35 * rng.randf() + 0.12 * sin(v.x * 9.1 + seed_i)
		v = Vector3(nrm.x * stretch, nrm.y * 0.7, nrm.z) * radius * bump
		# Chop a flat-ish belly so it sits, not floats on a point.
		v.y = maxf(v.y, -radius * 0.35)
		verts[i] = v
		min_y = minf(min_y, v.y)
	for i in verts.size():
		verts[i].y -= min_y
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var st := SurfaceTool.new()
	st.create_from(mesh, 0)
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


func _basis_from_up(up: Vector3) -> Basis:
	var y := up.normalized()
	var x := y.cross(Vector3.RIGHT)
	if x.length_squared() < 0.0001:
		x = y.cross(Vector3.FORWARD)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)
