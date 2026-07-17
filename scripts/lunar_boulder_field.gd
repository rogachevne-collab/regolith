class_name LunarBoulderField
extends Node3D

## Runtime radial boulder field for the spherical moon.
## SDF position + radial sink; 2 MultiMesh pools for FPS.

@export var count := 36
@export var radius_m := 44.0
@export var min_radial_dot := 0.72
@export var embed_m := 0.18
@export var min_spacing_m := 1.6
@export var collision_mask := 1
@export var rng_seed := 404

@export var pebble_weight := 0.40
@export var rock_weight := 0.40
@export var boulder_weight := 0.20

static var _small_mesh: ArrayMesh
static var _large_mesh: ArrayMesh
static var _material: StandardMaterial3D

var _mmi_small: MultiMeshInstance3D
var _mmi_large: MultiMeshInstance3D
var _xforms_small: Array[Transform3D] = []
var _xforms_large: Array[Transform3D] = []


func build_around(
	center: Vector3,
	space: PhysicsDirectSpaceState3D,
	_terrain: Node3D = null
) -> int:
	if space == null:
		return 0
	_clear_pools()
	_ensure_assets()

	var up := center.normalized()
	if up.length_squared() < 0.0001:
		up = Vector3.UP
	var tangent_basis := _basis_from_up(up)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var probe_from_r := clampf(
		center.length() + 22.0,
		MoonGeometry.SURFACE_RADIUS_M - MoonTerrainParams.HEIGHT_CLAMP_M + 4.0,
		MoonGeometry.SURFACE_RADIUS_M + MoonTerrainParams.HEIGHT_CLAMP_M + 20.0
	)
	var probe_to_r := clampf(
		center.length() - 55.0,
		MoonGeometry.SURFACE_RADIUS_M - MoonTerrainParams.HEIGHT_CLAMP_M - 30.0,
		probe_from_r - 8.0
	)

	var mmi_small := _make_mmi(_small_mesh)
	var mmi_large := _make_mmi(_large_mesh)
	add_child(mmi_small)
	add_child(mmi_large)
	_mmi_small = mmi_small
	_mmi_large = mmi_large
	_xforms_small = []
	_xforms_large = []

	var placed_positions: Array[Vector3] = []
	var placed := 0
	var attempts := 0
	var max_attempts := count * 16

	while placed < count and attempts < max_attempts:
		attempts += 1
		var local := Vector2(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)
		)
		if local.length_squared() > 1.0:
			continue
		local *= radius_m
		var hint := center + tangent_basis * Vector3(local.x, 0.0, local.y)
		var dir := hint.normalized()
		var from := dir * probe_from_r
		var to := dir * probe_to_r

		var ground := _resolve_ground(from, to, dir, space)
		if ground.is_empty():
			continue

		var n: Vector3 = ground.normal
		var hit_pos: Vector3 = ground.position
		if n.dot(dir) < min_radial_dot:
			continue

		var tier := _pick_tier(rng)
		var scale := _scale_for_tier(tier, rng)
		if not _has_spacing(hit_pos, placed_positions, min_spacing_m * scale):
			continue

		## Embed along surface normal (physics contact), not radial SDF shell.
		var sink := embed_m * scale * rng.randf_range(0.95, 1.45)
		var pos: Vector3 = hit_pos - n * sink

		var yaw := rng.randf() * TAU
		var rock_basis := _basis_from_up(n).rotated(n, yaw)
		rock_basis = rock_basis.scaled(Vector3(
			scale * rng.randf_range(0.82, 1.22),
			scale * rng.randf_range(0.48, 0.78),
			scale * rng.randf_range(0.82, 1.18)
		))
		var xf := Transform3D(rock_basis, pos)
		if tier == "pebble":
			_xforms_small.append(xf)
		else:
			_xforms_large.append(xf)
		placed_positions.append(pos)
		placed += 1

	_fill_mmi(_mmi_small, _xforms_small)
	_fill_mmi(_mmi_large, _xforms_large)
	return placed


func remove_near(world_point: Vector3, radius_m: float) -> int:
	if _mmi_small == null or radius_m <= 0.0:
		return 0
	var radius_sq := radius_m * radius_m
	var before := _xforms_small.size() + _xforms_large.size()
	_xforms_small = _drop_within_radius(_xforms_small, world_point, radius_sq)
	_xforms_large = _drop_within_radius(_xforms_large, world_point, radius_sq)
	_fill_mmi(_mmi_small, _xforms_small)
	_fill_mmi(_mmi_large, _xforms_large)
	return before - (_xforms_small.size() + _xforms_large.size())


func _drop_within_radius(
	xforms: Array[Transform3D],
	world_point: Vector3,
	radius_sq: float
) -> Array[Transform3D]:
	var kept: Array[Transform3D] = []
	for xf: Transform3D in xforms:
		if xf.origin.distance_squared_to(world_point) > radius_sq:
			kept.append(xf)
	return kept


func _clear_pools() -> void:
	for child in get_children():
		child.queue_free()
	_mmi_small = null
	_mmi_large = null
	_xforms_small = []
	_xforms_large = []


func _resolve_ground(
	from: Vector3,
	to: Vector3,
	dir: Vector3,
	space: PhysicsDirectSpaceState3D
) -> Dictionary:
	var inward := (to - from).normalized()
	var probe_len := from.distance_to(to)

	## Scaled VoxelLodTerrain: SDF shell sits above collider — physics only.
	var q := PhysicsRayQueryParameters3D.create(from, from + inward * probe_len)
	q.collision_mask = collision_mask
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}

	var n: Vector3 = hit.normal
	if n.length_squared() < 0.0001:
		n = dir
	else:
		n = n.normalized()
	return {"position": hit.position as Vector3, "normal": n}


func _pick_tier(rng: RandomNumberGenerator) -> String:
	var roll := rng.randf()
	if roll < pebble_weight:
		return "pebble"
	if roll < pebble_weight + rock_weight:
		return "rock"
	return "boulder"


func _scale_for_tier(tier: String, rng: RandomNumberGenerator) -> float:
	match tier:
		"pebble":
			return rng.randf_range(0.38, 0.68)
		"boulder":
			return rng.randf_range(1.0, 1.65)
		_:
			return rng.randf_range(0.62, 1.05)


func _has_spacing(pos: Vector3, placed: Array[Vector3], min_dist: float) -> bool:
	var min_dist_sq := min_dist * min_dist
	for other in placed:
		if pos.distance_squared_to(other) < min_dist_sq:
			return false
	return true


func _make_mmi(mesh: ArrayMesh) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mmi


func _fill_mmi(mmi: MultiMeshInstance3D, xforms: Array[Transform3D]) -> void:
	var mm: MultiMesh = mmi.multimesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	mmi.visible = not xforms.is_empty()


static func _ensure_assets() -> void:
	if _material != null:
		return
	_material = load("res://resources/props/lunar_boulder_material.tres") as StandardMaterial3D
	if _material == null:
		_material = StandardMaterial3D.new()
	_small_mesh = _build_rock_mesh(404, 0.34, 1.0)
	_large_mesh = _build_rock_mesh(472, 0.52, 0.94)


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


func _basis_from_up(up: Vector3) -> Basis:
	var y := up.normalized()
	var x := y.cross(Vector3.RIGHT)
	if x.length_squared() < 0.0001:
		x = y.cross(Vector3.FORWARD)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)
