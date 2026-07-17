class_name LunarBoulderMeshFactory
extends RefCounted

## Procedural lunar rock meshes + material tints for VoxelInstancer.

const SMALL_PROFILES: Array[Dictionary] = [
	{"seed": 404, "radius": 0.30, "stretch": 1.05},
	{"seed": 511, "radius": 0.27, "stretch": 0.86},
	{"seed": 618, "radius": 0.33, "stretch": 1.20},
]

const LARGE_PROFILES: Array[Dictionary] = [
	{"seed": 472, "radius": 0.50, "stretch": 0.90},
	{"seed": 529, "radius": 0.55, "stretch": 1.10},
]

const MATERIAL_TINTS: Array[Color] = [
	Color(1.0, 1.0, 1.0),
	Color(0.90, 0.93, 0.98),
	Color(0.98, 0.92, 0.88),
]


static func build_small_mesh(profile_index: int = 0) -> ArrayMesh:
	var profile := SMALL_PROFILES[profile_index % SMALL_PROFILES.size()]
	return _build_rock_mesh(profile.seed, profile.radius, profile.stretch)


static func build_large_mesh(profile_index: int = 0) -> ArrayMesh:
	var profile := LARGE_PROFILES[profile_index % LARGE_PROFILES.size()]
	return _build_rock_mesh(profile.seed, profile.radius, profile.stretch)


static func material(tint_index: int = 0) -> StandardMaterial3D:
	var base := load("res://resources/props/lunar_boulder_material.tres") as StandardMaterial3D
	if base == null:
		return StandardMaterial3D.new()
	var mat := base.duplicate() as StandardMaterial3D
	mat.albedo_color = MATERIAL_TINTS[tint_index % MATERIAL_TINTS.size()]
	return mat


static func _build_rock_mesh(seed_i: int, radius: float, stretch: float) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 1.3
	sphere.radial_segments = 8
	sphere.rings = 4
	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	var min_y := 1e9
	for i in verts.size():
		var v := verts[i]
		var nrm := v.normalized()
		var bump := 0.76 + 0.28 * rng.randf() + 0.08 * sin(v.x * 8.0 + seed_i)
		v = Vector3(nrm.x * stretch, nrm.y * 0.65, nrm.z) * radius * bump
		v.y = maxf(v.y, -radius * 0.45)
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
	return st.commit()
