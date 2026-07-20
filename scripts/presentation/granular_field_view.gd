class_name GranularFieldView
extends Node3D
## Draws and collides one `GranularPatch` at its `GranularAnchor`.
##
## The node carries the anchor frame, so the mesh and the height field are both
## built in patch-local metres and never have to know the patch is standing on
## a sphere. Presentation only — nothing here is authoritative, and the surface
## it draws deliberately lags the field it draws from.

const _ALBEDO_PATH := "res://resources/moon_regolith_albedo.jpg"
const _NORMAL_PATH := "res://resources/moon_regolith_normal.jpg"

## Visual-only surface grain, metres. Not part of the field.
const GRAIN_AMPLITUDE_M := 0.02
## World metres per albedo/normal tile.
const SURFACE_UV_METRES := 2.5
## Thickness at which a cell is drawn as fully covered, and at which spoil
## still reads as freshly turned.
const COVER_THICKNESS_M := 0.035
const FRESH_THICKNESS_M := 0.14

var anchor: GranularAnchor
var patch: GranularPatch

var _mesh_instance: MeshInstance3D
var _collision: CollisionShape3D
var _indices := PackedInt32Array()
var _shown_thickness := PackedFloat32Array()
var _display_heights := PackedFloat32Array()

static var _surface_material: Material


func setup(new_anchor: GranularAnchor, new_patch: GranularPatch) -> void:
	anchor = new_anchor
	patch = new_patch
	transform = anchor.world_transform()
	_shown_thickness = patch.thickness_data()
	_build_indices()
	_build_nodes()
	rebuild()


## Step the drawn surface toward the field and redraw if anything moved. The
## field steps at the settle rate — about 10 Hz under lunar gravity — while the
## screen runs at 60, so the drawn surface chases it with a critically damped
## filter one sweep long: the simulation stays authoritative and the picture
## stays continuous.
func refresh(delta_s: float, gravity_m_s2: float) -> void:
	if patch == null:
		return
	var target := patch.thickness_data()
	if _shown_thickness.size() != target.size():
		_shown_thickness = target
		rebuild()
		return
	var tau := 1.0 / maxf(patch.settle_rate_hz(gravity_m_s2), 0.01)
	var blend := 1.0 - exp(-delta_s / tau)
	var moved := false
	for i in target.size():
		var difference := target[i] - _shown_thickness[i]
		if absf(difference) < 1e-5:
			if _shown_thickness[i] != target[i]:
				_shown_thickness[i] = target[i]
				moved = true
			continue
		_shown_thickness[i] += difference * blend
		moved = true
	if moved:
		rebuild()


## Redraw from the field immediately, skipping the display filter. Used when
## the base moves under the material — a fresh cut is not something to ease
## into.
func snap() -> void:
	if patch == null:
		return
	_shown_thickness = patch.thickness_data()
	rebuild()


func rebuild() -> void:
	if patch == null or _mesh_instance == null:
		return
	var width := patch.width
	var depth := patch.depth
	var cell := patch.cell_size
	var half := anchor.half_extent()
	var count := width * depth
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	vertices.resize(count)
	normals.resize(count)
	colors.resize(count)
	uvs.resize(count)
	_display_heights.resize(count)
	for z in depth:
		for x in width:
			var i := z * width + x
			var thickness := _shown_thickness[i]
			# Presentation-only grain: a mathematically clean surface reads as
			# dough. The jitter never touches the field, so volume, repose and
			# determinism of the simulation stay exact.
			var grain := (_hash2(x + 2027, z + 911) - 0.5) * 2.0 * minf(
				thickness * 0.4, GRAIN_AMPLITUDE_M
			)
			_display_heights[i] = patch.base_height(x, z) + thickness + grain
			uvs[i] = Vector2(
				float(x) * cell / SURFACE_UV_METRES,
				float(z) * cell / SURFACE_UV_METRES
			)
			var cover := clampf(thickness / COVER_THICKNESS_M, 0.0, 1.0)
			var fresh := clampf(thickness / FRESH_THICKNESS_M, 0.0, 1.0)
			colors[i] = Color(0.9, 0.88, 0.84).lerp(Color(1.0, 0.98, 0.94), fresh)
			colors[i].a = cover
	for z in depth:
		for x in width:
			var i := z * width + x
			vertices[i] = Vector3(
				float(x) * cell - half.x,
				_display_heights[i],
				float(z) * cell - half.y
			)
			var left := _display_heights[maxi(x - 1, 0) + z * width]
			var right := _display_heights[mini(x + 1, width - 1) + z * width]
			var back := _display_heights[x + maxi(z - 1, 0) * width]
			var front := _display_heights[x + mini(z + 1, depth - 1) * width]
			normals[i] = Vector3(left - right, 2.0 * cell, back - front).normalized()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh
	_update_collider()


func _build_indices() -> void:
	var width := patch.width
	_indices = PackedInt32Array()
	for z in patch.depth - 1:
		for x in width - 1:
			# A blocked corner has no probed floor, so it draws at the tangent
			# plane's height by default — on sloped ground that can be metres
			# from where the real surface actually is. Left in, that quad becomes
			# a phantom cliff face hanging in the air; skip it and leave a hole,
			# same as the collider already does for these cells. Blocked state is
			# fixed at patch creation (GranularWorld never blocks a cell that
			# once had a floor), so a one-time skip here stays correct for the
			# life of the patch.
			if (
				patch.is_blocked(x, z)
				or patch.is_blocked(x + 1, z)
				or patch.is_blocked(x, z + 1)
				or patch.is_blocked(x + 1, z + 1)
			):
				continue
			# Godot treats clockwise winding as front-facing; the other order
			# renders the whole patch inside-out.
			var i := z * width + x
			_indices.append(i)
			_indices.append(i + 1)
			_indices.append(i + width)
			_indices.append(i + 1)
			_indices.append(i + width + 1)
			_indices.append(i + width)


func _build_nodes() -> void:
	if _mesh_instance != null:
		return
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _shared_surface_material()
	add_child(_mesh_instance)
	var body := StaticBody3D.new()
	add_child(body)
	_collision = CollisionShape3D.new()
	var shape := HeightMapShape3D.new()
	shape.map_width = patch.width
	shape.map_depth = patch.depth
	_collision.shape = shape
	# HeightMapShape3D samples are one unit apart and centred on the shape, so
	# scale uniformly (Jolt rejects non-uniform height fields) and store heights
	# in cell units. The patch is centred on the anchor, so the shape sits at
	# the node origin.
	_collision.scale = Vector3.ONE * patch.cell_size
	body.add_child(_collision)


func _update_collider() -> void:
	if _collision == null:
		return
	var shape := _collision.shape as HeightMapShape3D
	if shape == null:
		return
	var source := patch.height_map_data()
	# `map_data` is PackedFloat32Array in stock Godot and PackedFloat64Array in
	# the double-precision build, so take the array from the property itself
	# instead of naming a type here.
	var data := shape.map_data
	if data.size() != source.size():
		data.resize(source.size())
	for i in source.size():
		# Collide against the field itself, not the smoothed surface drawn from
		# it. The drawn one lags by a sweep, and a body resting on that lag never
		# falls into the hollow it has just yielded — it hangs there while the
		# material keeps yielding under it. NAN survives the divide and stays a
		# hole in the collider.
		data[i] = source[i] / patch.cell_size
	shape.map_data = data


## Deterministic per-cell hash in 0..1 — same layout every run and for every
## peer, no RNG state to replicate.
static func _hash2(x: int, z: int) -> float:
	var h := (x * 73856093) ^ (z * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	return float(absi(h) % 100000) / 100000.0


static func _shared_surface_material() -> Material:
	if _surface_material != null:
		return _surface_material
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.88, 0.85, 0.78)
	material.albedo_texture = load(_ALBEDO_PATH) as Texture2D
	material.normal_enabled = true
	material.normal_texture = load(_NORMAL_PATH) as Texture2D
	material.normal_scale = 1.35
	material.roughness = 0.95
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.vertex_color_use_as_albedo = true
	# Thin cover fades out instead of ending at a hard edge, so a spoil ring
	# blends into the rock it is lying on rather than looking like a decal.
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_surface_material = material
	return _surface_material
