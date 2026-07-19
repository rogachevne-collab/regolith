class_name MoonMapGlobe
extends Control

## Interactive orthographic moon globe for MapPanel (satellite projection).
## Play-world relief mesh + lit regolith material. Spec: MAP-UI-01.

const _Builder := preload("res://scripts/presentation/moon_globe_mesh_builder.gd")
const _SHADER := preload("res://resources/ui/shaders/hud_moon_globe.gdshader")

const VIEWPORT_SIZE := 640
const DRAG_THRESHOLD_PX := 5.0
const ROTATE_SENS := 0.0085

signal cursor_world_changed(world_pos: Vector3, inside: bool)
signal surface_clicked(world_pos: Vector3, button: MouseButton)

var owner_panel: Node
var show_deposits := true

var _viewport: SubViewport
var _container: SubViewportContainer
var _pivot: Node3D
var _camera: Camera3D
var _mesh_instance: MeshInstance3D
var _mat: ShaderMaterial
var _built := false
var _dragging := false
var _drag_moved := false
var _drag_last := Vector2.ZERO
var _press_pos := Vector2.ZERO
var _ortho_size := 0.0
var _overlay: _MarkerOverlay


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_ortho_size = _ortho_default()
	_build_viewport()
	_overlay = _MarkerOverlay.new()
	_overlay.owner_globe = self
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	set_active(false)


func warm_cache(spawn_world: Vector3 = Vector3.ZERO) -> void:
	_Builder.warm_cache(spawn_world)


func ensure_built(spawn_world: Vector3 = Vector3.ZERO) -> void:
	if _built:
		_apply_deposit_strength()
		return
	_built = true
	_mesh_instance.mesh = _Builder.build_mesh()
	_update_camera()
	## Soft deposit stains after first frame so the globe paints immediately.
	call_deferred("_finish_deposits", spawn_world)


func _finish_deposits(spawn_world: Vector3) -> void:
	var cube: Cubemap = _Builder.build_deposit_cubemap(spawn_world)
	if _mat != null:
		_mat.set_shader_parameter("deposit_cube", cube)
	_apply_deposit_strength()


func set_active(active: bool) -> void:
	set_process(active)
	if _viewport != null:
		_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
		)


func set_deposit_visible(visible: bool) -> void:
	show_deposits = visible
	_apply_deposit_strength()
	queue_redraw_markers()


func _apply_deposit_strength() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter(
		"deposit_strength",
		1.0 if show_deposits else 0.0
	)


func focus_world(world_pos: Vector3) -> void:
	if world_pos.length_squared() < 0.0001 or _pivot == null:
		return
	var dir := world_pos.normalized()
	_pivot.basis = Basis(Quaternion(dir, Vector3(0.0, 0.0, 1.0)))
	queue_redraw_markers()


func queue_redraw_markers() -> void:
	if _overlay != null:
		_overlay.queue_redraw()


func project_world(world_pos: Vector3) -> Dictionary:
	if _camera == null or _pivot == null or world_pos.length_squared() < 0.0001:
		return {"ok": false, "pos": Vector2.ZERO}
	var r := _surface_radius_m()
	var dir := world_pos.normalized()
	var visual := _pivot.to_global(dir * r)
	var to_cam := (_camera.global_position - visual).normalized()
	if visual.normalized().dot(to_cam) < 0.04:
		return {"ok": false, "pos": Vector2.ZERO}
	var screen: Vector2 = _camera.unproject_position(visual)
	var sx := size.x / float(VIEWPORT_SIZE)
	var sy := size.y / float(VIEWPORT_SIZE)
	return {"ok": true, "pos": Vector2(screen.x * sx, screen.y * sy)}


func pick_world(local_pos: Vector2) -> Vector3:
	if _camera == null or _pivot == null:
		return Vector3.ZERO
	var vp_pos := Vector2(
		local_pos.x * float(VIEWPORT_SIZE) / maxf(size.x, 1.0),
		local_pos.y * float(VIEWPORT_SIZE) / maxf(size.y, 1.0)
	)
	var origin := _camera.project_ray_origin(vp_pos)
	var ray_dir := _camera.project_ray_normal(vp_pos)
	var hit := _intersect_sphere(origin, ray_dir, Vector3.ZERO, _surface_radius_m())
	if not hit.get("ok", false):
		return Vector3.ZERO
	var hit_pos: Vector3 = hit["pos"]
	var local := _pivot.to_local(hit_pos)
	if local.length_squared() < 0.0001:
		return Vector3.ZERO
	return MoonGeometry.surface_point(local.normalized())


func _surface_radius_m() -> float:
	return MoonGeometry.active_surface_radius_m()


func _camera_dist_m() -> float:
	return _surface_radius_m() * 1.35


func _ortho_default() -> float:
	return _surface_radius_m() * 2.0 * 0.96


func _ortho_min() -> float:
	return _surface_radius_m() * 0.72


func _ortho_max() -> float:
	return _surface_radius_m() * 2.18


func _make_moon_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _SHADER
	mat.set_shader_parameter("albedo_tint", Color(0.58, 0.59, 0.61))
	mat.set_shader_parameter("macro_amp", 0.04)
	mat.set_shader_parameter("macro_freq", 2.4)
	mat.set_shader_parameter("deposit_strength", 1.0)
	## Transparent cubemap placeholder until bake finishes.
	var empty := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	empty.set_pixel(0, 0, Color(0, 0, 0, 0))
	var faces: Array[Image] = [empty, empty, empty, empty, empty, empty]
	var cube := Cubemap.new()
	cube.create_from_images(faces)
	mat.set_shader_parameter("deposit_cube", cube)
	return mat


func _build_viewport() -> void:
	_container = SubViewportContainer.new()
	_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(VIEWPORT_SIZE, VIEWPORT_SIZE)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = false
	_viewport.own_world_3d = true
	_container.add_child(_viewport)

	var world := Node3D.new()
	_viewport.add_child(world)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.015, 0.016, 0.018, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	## Neutral vacuum ambient — no blue fill in the terminator.
	environment.ambient_light_color = Color(0.14, 0.135, 0.13)
	environment.ambient_light_energy = 0.22
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.02
	env.environment = environment
	world.add_child(env)

	_pivot = Node3D.new()
	world.add_child(_pivot)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = _make_moon_material()
	_mesh_instance.material_override = _mat
	_pivot.add_child(_mesh_instance)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = _ortho_size
	_camera.near = 10.0
	_camera.far = _camera_dist_m() + _ortho_max() + 5000.0
	_camera.current = true
	world.add_child(_camera)
	_camera.look_at_from_position(
		Vector3(0.0, 0.0, _camera_dist_m()),
		Vector3.ZERO,
		Vector3.UP
	)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.98, 0.94)
	sun.light_energy = 2.8
	sun.shadow_enabled = false
	sun.rotation_degrees = Vector3(-18.0, 36.0, 0.0)
	_camera.add_child(sun)

	## Soft warm bounce only — keep night side grey, not cyan/lavender.
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.62, 0.58, 0.52)
	fill.light_energy = 0.07
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(25.0, -50.0, 0.0)
	_camera.add_child(fill)


func _orbit_drag(delta: Vector2) -> void:
	if _pivot == null or _camera == null:
		return
	_pivot.rotate(Vector3.UP, delta.x * ROTATE_SENS)
	_pivot.rotate(_camera.global_transform.basis.x, delta.y * ROTATE_SENS)


func _update_camera() -> void:
	if _camera == null:
		return
	_camera.size = _ortho_size
	_camera.far = _camera_dist_m() + _ortho_max() + 5000.0


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_ortho_size = clampf(_ortho_size * 0.9, _ortho_min(), _ortho_max())
			_update_camera()
			queue_redraw_markers()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_ortho_size = clampf(_ortho_size * 1.1, _ortho_min(), _ortho_max())
			_update_camera()
			queue_redraw_markers()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_dragging = true
				_drag_moved = false
				_drag_last = mb.position
				_press_pos = mb.position
			else:
				if _dragging and not _drag_moved:
					var world := pick_world(mb.position)
					if world.length_squared() > 0.0001:
						surface_clicked.emit(world, mb.button_index)
				_dragging = false
			accept_event()
			return
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			var delta: Vector2 = mm.position - _drag_last
			_drag_last = mm.position
			if not _drag_moved and _press_pos.distance_to(mm.position) >= DRAG_THRESHOLD_PX:
				_drag_moved = true
			if _drag_moved:
				_orbit_drag(delta)
				queue_redraw_markers()
			accept_event()
		var world_hover := pick_world(mm.position)
		var inside := (
			world_hover.length_squared() > 0.0001
			and _disk_contains(mm.position)
		)
		cursor_world_changed.emit(world_hover, inside)


func _disk_contains(local_pos: Vector2) -> bool:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.48
	return local_pos.distance_to(c) <= r


func _intersect_sphere(
	origin: Vector3,
	dir: Vector3,
	center: Vector3,
	radius: float
) -> Dictionary:
	var oc := origin - center
	var a := dir.dot(dir)
	var b := 2.0 * oc.dot(dir)
	var c := oc.dot(oc) - radius * radius
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return {"ok": false}
	var s := sqrt(disc)
	var t0 := (-b - s) / (2.0 * a)
	var t1 := (-b + s) / (2.0 * a)
	var t := t0 if t0 > 0.001 else t1
	if t <= 0.001:
		return {"ok": false}
	return {"ok": true, "pos": origin + dir * t}


func _process(_delta: float) -> void:
	if visible and _overlay != null:
		_overlay.queue_redraw()


class _MarkerOverlay:
	extends Control

	var owner_globe: MoonMapGlobe

	func _draw() -> void:
		if owner_globe == null or owner_globe.owner_panel == null:
			return
		var panel: Node = owner_globe.owner_panel
		var rect := Rect2(Vector2.ZERO, size)
		_draw_chrome(rect)
		var col_structure: Color = HudTokens.COL_OK
		var col_loot: Color = HudTokens.COL_WARNING
		if bool(panel.call("show_structure_layer")):
			for entry: Dictionary in panel.call("overlay_entries"):
				if str(entry.get("kind", "")) != "structure":
					continue
				_draw_projected_dot(entry["position"], col_structure, 3.5)
		if bool(panel.call("show_loot_layer")):
			for entry: Dictionary in panel.call("overlay_entries"):
				if str(entry.get("kind", "")) != "loot":
					continue
				_draw_projected_dot(entry["position"], col_loot, 4.5)
		if bool(panel.call("show_marker_layer")):
			for marker: Dictionary in panel.call("user_markers"):
				var selected := (
					str(marker["id"]) == str(panel.call("selected_marker_id"))
				)
				_draw_projected_marker(marker["position"], selected)
		_draw_projected_player(
			panel.call("player_world_position"),
			float(panel.call("player_heading"))
		)

	func _draw_chrome(rect: Rect2) -> void:
		var col := Color(HudTokens.COL_VALID, 0.7)
		var len := 18.0
		var t := 1.5
		var x0 := rect.position.x + 3.0
		var y0 := rect.position.y + 3.0
		var x1 := rect.end.x - 3.0
		var y1 := rect.end.y - 3.0
		draw_line(Vector2(x0, y0), Vector2(x0 + len, y0), col, t)
		draw_line(Vector2(x0, y0), Vector2(x0, y0 + len), col, t)
		draw_line(Vector2(x1, y0), Vector2(x1 - len, y0), col, t)
		draw_line(Vector2(x1, y0), Vector2(x1, y0 + len), col, t)
		draw_line(Vector2(x0, y1), Vector2(x0 + len, y1), col, t)
		draw_line(Vector2(x0, y1), Vector2(x0, y1 - len), col, t)
		draw_line(Vector2(x1, y1), Vector2(x1 - len, y1), col, t)
		draw_line(Vector2(x1, y1), Vector2(x1, y1 - len), col, t)
		draw_rect(rect, Color(HudTokens.COL_OK, 0.45), false, 1.0)
		var font := get_theme_default_font()
		if font == null:
			font = ThemeDB.fallback_font
		if font != null:
			draw_string(
				font,
				Vector2(10.0, size.y - 10.0),
				"ЛКМ — метка · тяни — вращение · колесо — масштаб",
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				11,
				Color(HudTokens.COL_DIM, 0.85)
			)

	func _draw_projected_dot(world_pos: Vector3, color: Color, radius: float) -> void:
		var pr: Dictionary = owner_globe.project_world(world_pos)
		if not pr.get("ok", false):
			return
		var p: Vector2 = pr["pos"]
		draw_circle(p, radius + 2.0, Color(0, 0, 0, 0.55))
		draw_circle(p, radius, color)

	func _draw_projected_marker(world_pos: Vector3, selected: bool) -> void:
		var pr: Dictionary = owner_globe.project_world(world_pos)
		if not pr.get("ok", false):
			return
		var p: Vector2 = pr["pos"]
		var r := 7.0 if selected else 5.5
		var points := PackedVector2Array([
			p + Vector2(0, -r),
			p + Vector2(r * 0.7, r * 0.6),
			p + Vector2(-r * 0.7, r * 0.6),
		])
		draw_colored_polygon(points, Color(0.85, 0.95, 1.0, 0.95))
		var outline := points.duplicate()
		outline.append(points[0])
		draw_polyline(outline, HudTokens.COL_VALID, 1.3, true)

	func _draw_projected_player(world_pos: Vector3, heading_deg: float) -> void:
		var pr: Dictionary = owner_globe.project_world(world_pos)
		if not pr.get("ok", false):
			return
		var p: Vector2 = pr["pos"]
		var col := HudTokens.COL_VALID
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.005)
		draw_circle(p, 14.0 + pulse * 4.0, Color(col.r, col.g, col.b, 0.12 + pulse * 0.08))
		draw_arc(p, 8.0, 0.0, TAU, 28, Color(col.r, col.g, col.b, 0.5), 1.2, true)
		draw_circle(p, 5.5, Color(0, 0, 0, 0.7))
		draw_circle(p, 3.6, col)
		var rad := deg_to_rad(heading_deg)
		var tip := p + Vector2(sin(rad), -cos(rad)) * 14.0
		draw_line(p, tip, col, 2.0)
