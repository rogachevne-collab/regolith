class_name MoonMapDepositOverlay
extends RefCounted

## Builds a low-res equirectangular deposit tint for the moon map (M).
## Samples MoonMaterialField — same source as mining yield.
## Spec: docs/specs/MAP-UI-01.md + TERRAIN-MATERIALS-V1.md

const _Catalog := preload(
	"res://scripts/simulation/runtime/terrain_material_catalog.gd"
)
const _Field := preload(
	"res://scripts/simulation/runtime/moon_material_field.gd"
)

const PREVIEW_W := 384
const PREVIEW_H := 192
const SAMPLE_DEPTHS_M: PackedFloat32Array = [2.0, 5.0, 9.0, 14.0]

## Soft stained patches — muted so DEM relief stays the hero.
const DEPOSIT_COLORS: Dictionary = {
	_Catalog.MAT_ILMENITE: Color(0.62, 0.22, 0.30, 0.32),
	_Catalog.MAT_ANORTHITE: Color(0.86, 0.88, 0.92, 0.28),
	_Catalog.MAT_OLIVINE: Color(0.40, 0.58, 0.30, 0.30),
	_Catalog.MAT_PYROXENE: Color(0.72, 0.48, 0.28, 0.30),
	_Catalog.MAT_ICE_LENS: Color(0.40, 0.72, 0.88, 0.34),
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


static func build_texture(spawn_world: Vector3 = Vector3.ZERO) -> ImageTexture:
	var field: MoonMaterialField = _Field.new()
	var img := Image.create(PREVIEW_W, PREVIEW_H, false, Image.FORMAT_RGBA8)
	for y in PREVIEW_H:
		var v := (float(y) + 0.5) / float(PREVIEW_H)
		for x in PREVIEW_W:
			var u := (float(x) + 0.5) / float(PREVIEW_W)
			var dir := MoonHeightmapUtil.direction_from_node_uv(u, v)
			var material_id := sample_near_surface(field, dir, spawn_world)
			img.set_pixel(x, y, color_for(material_id))
	## Soft stains (two passes) — avoid blocky neon tiles on the globe.
	img = _soften_patches(img)
	img = _soften_patches(img)
	var tex := ImageTexture.create_from_image(img)
	return tex


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
