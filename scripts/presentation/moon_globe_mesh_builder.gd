class_name MoonGlobeMeshBuilder
extends RefCounted

## Displaced cube-sphere from baked crust heightmap for the moon map globe.
## Cube-sphere avoids UV-sphere polar pinch ("anus"); UV still NODE_SDF
## panorama via MoonHeightmapUtil so deposits/hillshade line up.

const HEIGHT_W := 256
const HEIGHT_H := 128
## Quads per cube-face edge. 6 faces × N² × 2 tris — no pole singularity.
const FACE_RES := 28


static func build_mesh(height_image: Image) -> Mesh:
	if height_image == null or height_image.get_width() <= 0:
		return _unit_sphere_fallback()
	var heights := _sample_heights(height_image)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in 6:
		_add_cube_face(st, heights, face)
	st.generate_tangents()
	return st.commit()


## Face resolution for DEM/deposit cubemaps (6 × N²).
const CUBE_FACE_SIZE := 192
## Near poles, skip height derivatives (equirect DEM is undersampled → swirl).
const POLE_SMOOTH_ABS_Y := 0.86
const _Field := preload(
	"res://scripts/simulation/runtime/moon_material_field.gd"
)
const _DepositOverlay := preload(
	"res://scripts/simulation/runtime/moon_map_deposit_overlay.gd"
)


static func build_hillshade_cubemap(height_image: Image) -> Cubemap:
	var heights := _heights_or_flat(height_image)
	var min_h := INF
	var max_h := -INF
	for i in heights.size():
		min_h = minf(min_h, heights[i])
		max_h = maxf(max_h, heights[i])
	var span := maxf(max_h - min_h, 0.001)
	var light := Vector3(-0.55, 0.35, 0.75).normalized()
	var r0 := MoonGeometry.SURFACE_RADIUS_M
	return _cubemap_from_faces(func(face: int) -> Image:
		return _bake_hillshade_cube_face(heights, face, min_h, span, light, r0)
	)


static func build_deposit_cubemap(spawn_world: Vector3 = Vector3.ZERO) -> Cubemap:
	var field: MoonMaterialField = _Field.new()
	return _cubemap_from_faces(func(face: int) -> Image:
		return _bake_deposit_cube_face(field, face, spawn_world)
	)


static func _cubemap_from_faces(face_baker: Callable) -> Cubemap:
	var images: Array[Image] = []
	for face in 6:
		images.append(face_baker.call(face) as Image)
	var cube := Cubemap.new()
	var err := cube.create_from_images(images)
	if err != OK:
		push_warning("MoonGlobeMeshBuilder: cubemap bake failed (%s)" % error_string(err))
	return cube


static func _heights_or_flat(height_image: Image) -> PackedFloat32Array:
	if height_image == null or height_image.get_width() <= 0:
		var flat := PackedFloat32Array()
		flat.resize(HEIGHT_W * HEIGHT_H)
		flat.fill(0.0)
		return flat
	return _sample_heights(height_image)


static func _bake_hillshade_cube_face(
	heights: PackedFloat32Array,
	face: int,
	min_h: float,
	span: float,
	light: Vector3,
	r0: float
) -> Image:
	var n := CUBE_FACE_SIZE
	var out := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var col_mare := Color(0.22, 0.23, 0.25)
	var col_mid := Color(0.42, 0.40, 0.37)
	var col_high := Color(0.78, 0.74, 0.68)
	for y in n:
		var t := lerpf(1.0, -1.0, float(y) / float(maxi(n - 1, 1)))
		for x in n:
			var s := lerpf(-1.0, 1.0, float(x) / float(maxi(n - 1, 1)))
			var dir := _cube_face_dir(face, s, t)
			var uv := MoonHeightmapUtil.node_uv_from_direction(dir)
			var h_m := _sample_h(heights, uv.x, uv.y)
			var h01 := clampf((h_m - min_h) / span, 0.0, 1.0)
			## Poles: radial shade only — derivative hillshade swirls on thin DEM.
			var nrm := dir
			if absf(dir.y) < POLE_SMOOTH_ABS_Y:
				nrm = _continuous_normal(heights, dir, h_m, r0)
			var ndotl := clampf(nrm.dot(light), 0.0, 1.0)
			var shade := 0.32 + 0.68 * ndotl
			var base: Color
			if h01 < 0.40:
				base = col_mare.lerp(col_mid, h01 / 0.40)
			else:
				base = col_mid.lerp(col_high, (h01 - 0.40) / 0.60)
			out.set_pixel(
				x,
				y,
				Color(base.r * shade, base.g * shade, base.b * shade * 1.03, 1.0)
			)
	return out


static func _bake_deposit_cube_face(
	field: MoonMaterialField,
	face: int,
	spawn_world: Vector3
) -> Image:
	var n := CUBE_FACE_SIZE
	var raw := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		var t := lerpf(1.0, -1.0, float(y) / float(maxi(n - 1, 1)))
		for x in n:
			var s := lerpf(-1.0, 1.0, float(x) / float(maxi(n - 1, 1)))
			var dir := _cube_face_dir(face, s, t)
			var material_id := _DepositOverlay.sample_near_surface(field, dir, spawn_world)
			raw.set_pixel(x, y, _DepositOverlay.color_for(material_id))
	## Soften on the face (keeps cube topology — no equirect stretch).
	return _soften_image(raw)


static func _soften_image(src: Image) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var acc := Color(0, 0, 0, 0)
			var weight := 0.0
			for oy in range(-1, 2):
				for ox in range(-1, 2):
					var xx := clampi(x + ox, 0, w - 1)
					var yy := clampi(y + oy, 0, h - 1)
					var c := src.get_pixel(xx, yy)
					if c.a <= 0.001:
						continue
					var wgt := 1.0 if ox == 0 and oy == 0 else 0.4
					acc += Color(c.r * wgt, c.g * wgt, c.b * wgt, c.a * wgt)
					weight += wgt
			if weight <= 0.001:
				out.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				out.set_pixel(
					x,
					y,
					Color(
						acc.r / weight,
						acc.g / weight,
						acc.b / weight,
						clampf(acc.a / weight, 0.0, 1.0)
					)
				)
	return out


static func _add_cube_face(st: SurfaceTool, heights: PackedFloat32Array, face: int) -> void:
	var r0 := MoonGeometry.SURFACE_RADIUS_M
	for y in FACE_RES:
		var t0 := lerpf(-1.0, 1.0, float(y) / float(FACE_RES))
		var t1 := lerpf(-1.0, 1.0, float(y + 1) / float(FACE_RES))
		for x in FACE_RES:
			var s0 := lerpf(-1.0, 1.0, float(x) / float(FACE_RES))
			var s1 := lerpf(-1.0, 1.0, float(x + 1) / float(FACE_RES))
			var v00 := _displaced_vert(heights, face, s0, t0, r0)
			var v10 := _displaced_vert(heights, face, s1, t0, r0)
			var v01 := _displaced_vert(heights, face, s0, t1, r0)
			var v11 := _displaced_vert(heights, face, s1, t1, r0)
			## Winding so face normals point outward after cube→sphere.
			_add_tri(
				st,
				v00, v01, v11
			)
			_add_tri(
				st,
				v00, v11, v10
			)


static func _displaced_vert(
	heights: PackedFloat32Array,
	face: int,
	s: float,
	t: float,
	r0: float
) -> Dictionary:
	var dir := _cube_face_dir(face, s, t)
	var uv := MoonHeightmapUtil.node_uv_from_direction(dir)
	var h := _sample_h(heights, uv.x, uv.y)
	## Slight exaggerate so DEM relief reads under orthographic map view.
	var pos := dir * (r0 + h * 1.65)
	## Normals from a sphere-tangent frame (not face s/t) so cube edges don't
	## light-crease — face-local derivatives disagree on shared boundaries.
	var nrm := _continuous_normal(heights, dir, h, r0)
	## Height shade for shader (basins darker) — no equirect needed.
	var ao := clampf(0.70 + h * 0.014, 0.45, 1.18)
	return {"pos": pos, "nrm": nrm, "uv": uv, "ao": ao}


static func _continuous_normal(
	heights: PackedFloat32Array,
	dir: Vector3,
	h: float,
	r0: float
) -> Vector3:
	var e1 := dir.cross(Vector3.UP)
	if e1.length_squared() < 0.0001:
		e1 = dir.cross(Vector3.RIGHT)
	e1 = e1.normalized()
	var e2 := dir.cross(e1).normalized()
	## ~one mesh cell of arc; independent of which cube face owns the vert.
	var eps := (2.0 / float(FACE_RES)) * 0.85
	var dir_a := (dir + e1 * eps).normalized()
	var dir_b := (dir + e2 * eps).normalized()
	var uv_a := MoonHeightmapUtil.node_uv_from_direction(dir_a)
	var uv_b := MoonHeightmapUtil.node_uv_from_direction(dir_b)
	var h_a := _sample_h(heights, uv_a.x, uv_a.y)
	var h_b := _sample_h(heights, uv_b.x, uv_b.y)
	var p := dir * (r0 + h)
	var p_a := dir_a * (r0 + h_a)
	var p_b := dir_b * (r0 + h_b)
	var nrm := (p_a - p).cross(p_b - p)
	if nrm.length_squared() < 0.000001:
		return dir
	nrm = nrm.normalized()
	if nrm.dot(dir) < 0.0:
		nrm = -nrm
	return nrm


static func _cube_face_dir(face: int, s: float, t: float) -> Vector3:
	## s,t ∈ [-1,1] on a cube face → unit direction (normalized cube coords).
	var p: Vector3
	match face:
		0:
			p = Vector3(1.0, t, -s) ## +X
		1:
			p = Vector3(-1.0, t, s) ## -X
		2:
			p = Vector3(s, 1.0, -t) ## +Y
		3:
			p = Vector3(s, -1.0, t) ## -Y
		4:
			p = Vector3(s, t, 1.0) ## +Z
		_:
			p = Vector3(-s, t, -1.0) ## -Z
	return p.normalized()


static func _sample_heights(height_image: Image) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(HEIGHT_W * HEIGHT_H)
	for y in HEIGHT_H:
		var v := (float(y) + 0.5) / float(HEIGHT_H)
		for x in HEIGHT_W:
			var u := (float(x) + 0.5) / float(HEIGHT_W)
			data[y * HEIGHT_W + x] = (
				_sample_image_voxels(height_image, u, v) * MoonGeometry.VOXEL_SCALE
			)
	return data


static func _sample_image_voxels(img: Image, u: float, v: float) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var sx := fposmod(u, 1.0) * float(w)
	var sy := clampf(v, 0.0, 1.0) * float(h - 1)
	var x0 := int(floor(sx)) % w
	var x1 := (x0 + 1) % w
	var y0 := clampi(int(floor(sy)), 0, h - 1)
	var y1 := clampi(y0 + 1, 0, h - 1)
	var fx := sx - floorf(sx)
	var fy := sy - floorf(sy)
	var h00 := img.get_pixel(x0, y0).r
	var h10 := img.get_pixel(x1, y0).r
	var h01 := img.get_pixel(x0, y1).r
	var h11 := img.get_pixel(x1, y1).r
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


static func _sample_h(heights: PackedFloat32Array, u: float, v: float) -> float:
	var x := fposmod(u, 1.0) * float(HEIGHT_W)
	var y := clampf(v, 0.0, 1.0) * float(HEIGHT_H - 1)
	var x0 := int(floor(x)) % HEIGHT_W
	var x1 := (x0 + 1) % HEIGHT_W
	var y0 := clampi(int(floor(y)), 0, HEIGHT_H - 1)
	var y1 := clampi(y0 + 1, 0, HEIGHT_H - 1)
	var fx := x - floorf(x)
	var fy := y - floorf(y)
	var h00 := heights[y0 * HEIGHT_W + x0]
	var h10 := heights[y0 * HEIGHT_W + x1]
	var h01 := heights[y1 * HEIGHT_W + x0]
	var h11 := heights[y1 * HEIGHT_W + x1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


static func _add_tri(st: SurfaceTool, a: Dictionary, b: Dictionary, c: Dictionary) -> void:
	## Equirect dateline unwrap for any remaining UV-based samples.
	var uvs := _unwrap_equirect_seam(a["uv"] as Vector2, b["uv"] as Vector2, c["uv"] as Vector2)
	_add_vert(st, a["pos"], a["nrm"], uvs[0], float(a["ao"]))
	_add_vert(st, b["pos"], b["nrm"], uvs[1], float(b["ao"]))
	_add_vert(st, c["pos"], c["nrm"], uvs[2], float(c["ao"]))


static func _unwrap_equirect_seam(uva: Vector2, uvb: Vector2, uvc: Vector2) -> Array[Vector2]:
	var a := uva
	var b := uvb
	var c := uvc
	var max_u := maxf(a.x, maxf(b.x, c.x))
	var min_u := minf(a.x, minf(b.x, c.x))
	if max_u - min_u > 0.5:
		if a.x < 0.5:
			a.x += 1.0
		if b.x < 0.5:
			b.x += 1.0
		if c.x < 0.5:
			c.x += 1.0
	var out: Array[Vector2] = [a, b, c]
	return out


static func _add_vert(
	st: SurfaceTool, p: Vector3, n: Vector3, uv: Vector2, ao: float
) -> void:
	st.set_normal(n)
	st.set_uv(uv)
	st.set_color(Color(ao, ao, ao))
	st.add_vertex(p)


static func _unit_sphere_fallback() -> Mesh:
	## Even fallback: low-res cube-sphere without height (no UV-sphere poles).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var empty := PackedFloat32Array()
	empty.resize(HEIGHT_W * HEIGHT_H)
	empty.fill(0.0)
	for face in 6:
		_add_cube_face(st, empty, face)
	st.generate_tangents()
	return st.commit()
