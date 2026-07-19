class_name MoonMapDepositOverlay
extends RefCounted

## Deposit tint for the moon map (M). Globe uses a cubemap (no equirect
## pole-star). Equirect bake kept for headless coverage checks.
## Spec: docs/specs/MAP-UI-01.md + TERRAIN-MATERIALS-V1.md

const _Catalog := preload(
	"res://scripts/simulation/runtime/terrain_material_catalog.gd"
)
const _Field := preload(
	"res://scripts/simulation/runtime/moon_material_field.gd"
)

const PREVIEW_W := 256
const PREVIEW_H := 128
const CUBE_FACE := 64
const SAMPLE_DEPTHS_M: PackedFloat32Array = [2.0, 5.0, 9.0, 14.0]
## True lenses are ~70 m (sub-texel). Thin + stamp so orbital stains read.
const MAP_STAMP_RADIUS_PX := 2
const MAP_HIT_MIN_DIST_PX := 14
const CUBE_STAMP_RADIUS_PX := 2
const CUBE_HIT_MIN_DIST_PX := 10

## Soft stained patches — saturated enough to read on grey regolith.
const DEPOSIT_COLORS: Dictionary = {
	_Catalog.MAT_ILMENITE: Color(0.82, 0.28, 0.34, 0.55),
	_Catalog.MAT_ANORTHITE: Color(0.45, 0.68, 0.92, 0.50),
	_Catalog.MAT_OLIVINE: Color(0.38, 0.72, 0.30, 0.52),
	_Catalog.MAT_PYROXENE: Color(0.90, 0.55, 0.22, 0.52),
	_Catalog.MAT_ICE_LENS: Color(0.35, 0.82, 0.95, 0.58),
}


static func is_lens_material(material_id: String) -> bool:
	return DEPOSIT_COLORS.has(material_id)


static func color_for(material_id: String) -> Color:
	if DEPOSIT_COLORS.has(material_id):
		return DEPOSIT_COLORS[material_id]
	return Color(0, 0, 0, 0)


static func display_name(material_id: String) -> String:
	if material_id.is_empty():
		return ""
	return _Catalog.display_name(material_id)


static func build_cubemap_images(spawn_world: Vector3 = Vector3.ZERO) -> Array[Image]:
	var field: MoonMaterialField = _Field.new()
	var images: Array[Image] = []
	for face in 6:
		images.append(_bake_cube_face(field, face, spawn_world))
	return images


static func build_cubemap(spawn_world: Vector3 = Vector3.ZERO) -> Cubemap:
	var images := build_cubemap_images(spawn_world)
	var cube := Cubemap.new()
	cube.create_from_images(images)
	return cube


static func build_texture(spawn_world: Vector3 = Vector3.ZERO) -> ImageTexture:
	## Equirect path — tests / tools only (pole pinch; do not use on globe).
	var field: MoonMaterialField = _Field.new()
	var raw_hits: Array[Vector2i] = []
	var hit_colors: Dictionary = {}
	for y in PREVIEW_H:
		var v := (float(y) + 0.5) / float(PREVIEW_H)
		for x in PREVIEW_W:
			var u := (float(x) + 0.5) / float(PREVIEW_W)
			var dir := MoonHeightmapUtil.direction_from_node_uv(u, v)
			var material_id := sample_near_surface(field, dir, spawn_world)
			if not is_lens_material(material_id):
				continue
			var key := Vector2i(x, y)
			raw_hits.append(key)
			hit_colors[key] = color_for(material_id)
	var hits := _thin_hits(raw_hits, PREVIEW_W, MAP_HIT_MIN_DIST_PX, true)
	var img := Image.create(PREVIEW_W, PREVIEW_H, false, Image.FORMAT_RGBA8)
	for key: Vector2i in hits:
		_stamp_soft(img, key.x, key.y, hit_colors[key], MAP_STAMP_RADIUS_PX, true)
	img = _soften_patches(img)
	return ImageTexture.create_from_image(img)


static func _bake_cube_face(
	field: MoonMaterialField,
	face: int,
	spawn_world: Vector3
) -> Image:
	var n := CUBE_FACE
	var raw_hits: Array[Vector2i] = []
	var hit_colors: Dictionary = {}
	for y in n:
		var t := lerpf(1.0, -1.0, float(y) / float(maxi(n - 1, 1)))
		for x in n:
			var s := lerpf(-1.0, 1.0, float(x) / float(maxi(n - 1, 1)))
			var dir := _cube_face_dir(face, s, t)
			var material_id := sample_near_surface(field, dir, spawn_world)
			if not is_lens_material(material_id):
				continue
			var key := Vector2i(x, y)
			raw_hits.append(key)
			hit_colors[key] = color_for(material_id)
	var hits := _thin_hits(raw_hits, n, CUBE_HIT_MIN_DIST_PX, false)
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for key: Vector2i in hits:
		_stamp_soft(img, key.x, key.y, hit_colors[key], CUBE_STAMP_RADIUS_PX, false)
	return _soften_patches(img)


static func _cube_face_dir(face: int, s: float, t: float) -> Vector3:
	## Same mapping as MoonGlobeMeshBuilder — deposits stick to the mesh.
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


static func _thin_hits(
	raw: Array[Vector2i],
	width: int,
	min_dist: int,
	wrap_x: bool
) -> Array[Vector2i]:
	var kept: Array[Vector2i] = []
	var min_d2 := min_dist * min_dist
	for key: Vector2i in raw:
		var ok := true
		for prev: Vector2i in kept:
			var dx := key.x - prev.x
			var dy := key.y - prev.y
			if wrap_x:
				dx = mini(abs(dx), width - abs(dx))
			else:
				dx = abs(dx)
			dy = abs(dy)
			if dx * dx + dy * dy < min_d2:
				ok = false
				break
		if ok:
			kept.append(key)
	return kept


static func sample_near_surface(
	field: MoonMaterialField,
	dir: Vector3,
	spawn_world: Vector3 = Vector3.ZERO
) -> String:
	## Prefer a lens in the near-surface depth bands; else empty (no tint).
	for depth_m: float in SAMPLE_DEPTHS_M:
		var material_id := field.material_id_at_dir_depth(
			dir,
			depth_m,
			spawn_world
		)
		if is_lens_material(material_id):
			return material_id
	return ""


static func sample_at_world(
	world_pos: Vector3,
	spawn_world: Vector3 = Vector3.ZERO
) -> String:
	if world_pos.length() <= 0.001:
		return ""
	var field: MoonMaterialField = _Field.new()
	return sample_near_surface(field, world_pos.normalized(), spawn_world)


static func legend_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for material_id: String in [
		_Catalog.MAT_ILMENITE,
		_Catalog.MAT_ANORTHITE,
		_Catalog.MAT_OLIVINE,
		_Catalog.MAT_PYROXENE,
		_Catalog.MAT_ICE_LENS,
	]:
		rows.append({
			"material_id": material_id,
			"label": display_name(material_id),
			"color": color_for(material_id),
		})
	return rows


static func _stamp_soft(
	img: Image,
	cx: int,
	cy: int,
	col: Color,
	radius: int,
	wrap_x: bool
) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var r2 := float(radius * radius)
	for oy in range(-radius, radius + 1):
		for ox in range(-radius, radius + 1):
			var d2 := float(ox * ox + oy * oy)
			if d2 > r2:
				continue
			var xx := posmod(cx + ox, w) if wrap_x else clampi(cx + ox, 0, w - 1)
			var yy := clampi(cy + oy, 0, h - 1)
			var falloff := 1.0 - d2 / maxf(r2, 1.0)
			var a := col.a * falloff * falloff
			var prev := img.get_pixel(xx, yy)
			if a <= prev.a:
				continue
			var mixed := col if prev.a <= 0.001 else prev.lerp(col, 0.65)
			img.set_pixel(xx, yy, Color(mixed.r, mixed.g, mixed.b, a))


static func _soften_patches(src: Image) -> Image:
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
					var wgt := 1.0 if ox == 0 and oy == 0 else 0.45
					acc += Color(c.r * wgt, c.g * wgt, c.b * wgt, c.a * wgt)
					weight += wgt
			if weight <= 0.001:
				out.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				var a := clampf(acc.a / weight, 0.0, 1.0)
				out.set_pixel(
					x,
					y,
					Color(acc.r / weight, acc.g / weight, acc.b / weight, a)
				)
	return out
