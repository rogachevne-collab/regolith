class_name MoonGlobeMeshBuilder
extends RefCounted

## Map globe: displaced cube-sphere for orbital readability.
## Heights sampled once per mesh vertex; mesh + deposit texture cached.
## Material is lit regolith (MoonMapGlobe).

const _Relief := preload("res://scripts/simulation/runtime/moon_relief_sampler.gd")
const _Params := preload("res://scripts/simulation/runtime/moon_terrain_params.gd")

const _DepositOverlay := preload(
	"res://scripts/simulation/runtime/moon_map_deposit_overlay.gd"
)

## Vertex grid per cube face (MESH_FACE_RES quads → +1 samples).
const MESH_FACE_RES := 40
const FACE_GRID := MESH_FACE_RES + 1
## Play heights are ~±45 m on R≈9.5 km — need strong exag to read at full disk.
const RELIEF_EXAG := 22.0
const AO_HEIGHT_REF_M := 40.0
## Bump when vertex tint / mesh style changes (invalidates static mesh cache).
const MESH_STYLE := 4
const COL_MARE := Color(0.78, 0.78, 0.80)
const COL_HIGH := Color(0.94, 0.94, 0.95)

static var _face_heights: Array = []
static var _height_span := Vector2.ZERO
static var _cache_key := ""
static var _cached_mesh: Mesh
static var _mesh_cache_key := ""
static var _cached_deposit_cube: Cubemap
static var _deposit_cache_key := ""


static func warm_cache(spawn_world: Vector3 = Vector3.ZERO) -> void:
	build_mesh()
	build_deposit_cubemap(spawn_world)


static func build_mesh() -> Mesh:
	var key := _cache_key_for_heights()
	if _cached_mesh != null and _mesh_cache_key == key:
		return _cached_mesh
	_ensure_face_heights()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r0 := MoonGeometry.active_surface_radius_m()
	for face in 6:
		var grid: PackedFloat32Array = _face_heights[face]
		for y in MESH_FACE_RES:
			for x in MESH_FACE_RES:
				_add_displaced_quad(st, grid, face, x, y, r0)
	st.generate_normals()
	st.generate_tangents()
	_cached_mesh = st.commit()
	_mesh_cache_key = key
	return _cached_mesh


static func build_deposit_cubemap(spawn_world: Vector3 = Vector3.ZERO) -> Cubemap:
	var key := "%s_%.0f_%.0f_%.0f_cube" % [
		_cache_key_for_heights(),
		spawn_world.x,
		spawn_world.y,
		spawn_world.z,
	]
	if _cached_deposit_cube != null and _deposit_cache_key == key:
		return _cached_deposit_cube
	_cached_deposit_cube = _DepositOverlay.build_cubemap(spawn_world)
	_deposit_cache_key = key
	return _cached_deposit_cube


static func _cache_key_for_heights() -> String:
	return "%.0f_v%d_s%d_mapmesh" % [
		MoonGeometry.active_surface_radius_m(),
		_Params.GENERATOR_VERSION,
		MESH_STYLE,
	]


static func _ensure_face_heights() -> void:
	var key := _cache_key_for_heights()
	if not _face_heights.is_empty() and _cache_key == key:
		return
	_cache_key = key
	_face_heights.clear()
	var min_h := INF
	var max_h := -INF
	for face in 6:
		var grid := PackedFloat32Array()
		grid.resize(FACE_GRID * FACE_GRID)
		for y in FACE_GRID:
			var t := lerpf(-1.0, 1.0, float(y) / float(maxi(FACE_GRID - 1, 1)))
			for x in FACE_GRID:
				var s := lerpf(-1.0, 1.0, float(x) / float(maxi(FACE_GRID - 1, 1)))
				var dir := _cube_face_dir(face, s, t)
				var h := _Relief.sample_height_meters(dir, _Relief.Profile.MAP)
				grid[y * FACE_GRID + x] = h
				min_h = minf(min_h, h)
				max_h = maxf(max_h, h)
		_face_heights.append(grid)
	_height_span = Vector2(min_h, max_h)


static func _cube_face_dir(face: int, s: float, t: float) -> Vector3:
	var p: Vector3
	match face:
		0:
			p = Vector3(1.0, t, -s)
		1:
			p = Vector3(-1.0, t, s)
		2:
			p = Vector3(s, 1.0, -t)
		3:
			p = Vector3(s, -1.0, t)
		4:
			p = Vector3(s, t, 1.0)
		_:
			p = Vector3(-s, t, -1.0)
	return p.normalized()


static func _add_displaced_quad(
	st: SurfaceTool,
	grid: PackedFloat32Array,
	face: int,
	x: int,
	y: int,
	r0: float
) -> void:
	var s0 := lerpf(-1.0, 1.0, float(x) / float(MESH_FACE_RES))
	var s1 := lerpf(-1.0, 1.0, float(x + 1) / float(MESH_FACE_RES))
	var t0 := lerpf(-1.0, 1.0, float(y) / float(MESH_FACE_RES))
	var t1 := lerpf(-1.0, 1.0, float(y + 1) / float(MESH_FACE_RES))
	var i00 := y * FACE_GRID + x
	var i10 := y * FACE_GRID + (x + 1)
	var i01 := (y + 1) * FACE_GRID + x
	var i11 := (y + 1) * FACE_GRID + (x + 1)
	var p00 := _vert_at(face, s0, t0, grid[i00], r0)
	var p10 := _vert_at(face, s1, t0, grid[i10], r0)
	var p01 := _vert_at(face, s0, t1, grid[i01], r0)
	var p11 := _vert_at(face, s1, t1, grid[i11], r0)
	_add_tri(st, p00, p01, p11, grid[i00], grid[i01], grid[i11])
	_add_tri(st, p00, p11, p10, grid[i00], grid[i11], grid[i10])


static func _vert_at(face: int, s: float, t: float, h: float, r0: float) -> Vector3:
	var dir := _cube_face_dir(face, s, t)
	return dir * (r0 + h * RELIEF_EXAG)


static func _add_tri(
	st: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	ha: float,
	hb: float,
	hc: float
) -> void:
	_add_vert(st, a, ha)
	_add_vert(st, b, hb)
	_add_vert(st, c, hc)


static func _add_vert(st: SurfaceTool, p: Vector3, h: float) -> void:
	## Height tint breaks mono grey + softens tiling reads (mare vs highland).
	var t := clampf(0.5 + h / AO_HEIGHT_REF_M, 0.0, 1.0)
	var tint := COL_MARE.lerp(COL_HIGH, t)
	var ao := clampf(0.72 + t * 0.28, 0.72, 1.0)
	st.set_normal(p.normalized())
	st.set_color(Color(tint.r * ao, tint.g * ao, tint.b * ao))
	var pn := p.normalized()
	st.set_uv(Vector2(pn.x * 0.5 + 0.5, pn.z * 0.5 + 0.5))
	st.add_vertex(p)
