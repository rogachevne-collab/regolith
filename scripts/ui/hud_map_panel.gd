extends Control
## "КАРТА ЛУНЫ" overlay (toggle_map / M). Orthographic satellite globe of the
## planetoid (displaced crust mesh) + flat XZ fallback for legacy yard.
## Presentation only — see docs/specs/MAP-UI-01.md.

const _MoonMapGlobe := preload("res://scripts/ui/moon_map_globe.gd")

const PANEL_WIDTH := 920.0
const PANEL_HEIGHT := 640.0
const MAP_SIZE := Vector2(560, 560)
const SIDEBAR_WIDTH := 228.0
const FLAT_HALF_EXTENT_M := 250.0
const MARKER_HIT_ARC_M := 22.0

var _gateway: WorldCommandGateway
var _player: Node
var _camera: Camera3D

var _dimmer: ColorRect
var _panel: Panel
var _panel_overlay: ColorRect
var _coords_label: Label
var _cursor_label: Label
var _hint_label: Label
var _marker_list: ItemList
var _globe: Control
var _flat_view: _FlatMapCanvas
var _map_host: Control
var _chk_loot: CheckBox
var _chk_structures: CheckBox
var _chk_markers: CheckBox
var _chk_deposits: CheckBox
var _deposit_legend: VBoxContainer

var _open := false
var _planetoid := true
var _next_marker_serial := 1
var _selected_marker_id := ""
var _user_markers: Array[Dictionary] = []
var _overlay_entries: Array[Dictionary] = []
var _refresh_accum := 0.0
var _spawn_world_hint := Vector3.ZERO


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_player = ctx.get("player")
	_camera = ctx.get("camera")
	call_deferred("_warm_globe_cache")


func is_open() -> bool:
	return _open


func blocks_world_interact() -> bool:
	return _open


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_planetoid = not WorldPersistence.save_path_override.is_empty()
	_load_user_markers()
	_build()
	_apply_open_state()
	call_deferred("_warm_globe_cache")


func _warm_globe_cache() -> void:
	if not _planetoid or _globe == null:
		return
	var spawn := player_world_position()
	if spawn.length() <= 0.001:
		spawn = Vector3(MoonGeometry.active_surface_radius_m(), 0.0, 0.0)
	_globe.warm_cache(spawn)


func _process(delta: float) -> void:
	if not _open:
		return
	_refresh_accum += delta
	if _refresh_accum >= 0.35:
		_refresh_accum = 0.0
		_refresh_overlay_entries()
	_update_coords_readout()
	if _planetoid and _globe != null:
		_globe.queue_redraw_markers()
	elif _flat_view != null:
		_flat_view.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_map"):
		_toggle()
		get_viewport().set_input_as_handled()
	elif _open and event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_DELETE or event.physical_keycode == KEY_DELETE:
			_delete_selected_marker()
			get_viewport().set_input_as_handled()


func _toggle() -> void:
	if _open:
		_close()
	else:
		_open_map()


func _open_map() -> void:
	if not UIWindowStack.push(self, Callable(self, "_close")):
		return
	_open = true
	_planetoid = not WorldPersistence.save_path_override.is_empty()
	_load_user_markers()
	_refresh_overlay_entries()
	_rebuild_marker_list()
	## The landing site, not wherever the player is standing. Sampling the
	## player made the starting lenses follow them around the map while the
	## drill, which passes the real origin, found nothing there.
	_spawn_world_hint = MoonMaterialField.spawn_world()
	if _spawn_world_hint.length() <= 0.001:
		_spawn_world_hint = player_world_position()
	if _spawn_world_hint.length() <= 0.001:
		_spawn_world_hint = Vector3(MoonGeometry.active_surface_radius_m(), 0.0, 0.0)
	_sync_map_mode()
	if _planetoid and _globe != null:
		_globe.ensure_built(_spawn_world_hint)
		_globe.set_deposit_visible(show_deposit_layer())
		_globe.focus_world(player_world_position())
		_globe.set_active(true)
	_apply_open_state()


func _close() -> void:
	_open = false
	if _globe != null:
		_globe.set_active(false)
	_apply_open_state()
	UIWindowStack.remove(self)


func _apply_open_state() -> void:
	if _panel == null:
		return
	if _dimmer != null:
		_dimmer.visible = _open
	_panel.visible = _open
	mouse_filter = Control.MOUSE_FILTER_STOP if _open else Control.MOUSE_FILTER_IGNORE
	if _player != null and _player.has_method("set_gameplay_input_enabled"):
		_player.call("set_gameplay_input_enabled", not _open)
	Input.set_mouse_mode(
		Input.MOUSE_MODE_VISIBLE if _open else Input.MOUSE_MODE_CAPTURED
	)


func _sync_map_mode() -> void:
	if _globe != null:
		_globe.visible = _planetoid
	if _flat_view != null:
		_flat_view.visible = not _planetoid
		_flat_view.planetoid = false


func _build() -> void:
	_dimmer = ColorRect.new()
	_dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dimmer.color = Color(0.01, 0.02, 0.035, 0.82)
	_dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	_dimmer.visible = false
	_dimmer.gui_input.connect(_on_dimmer_gui_input)
	add_child(_dimmer)

	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.clip_contents = true
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	var half_w := PANEL_WIDTH * 0.5
	var half_h := PANEL_HEIGHT * 0.5
	_panel.offset_left = -half_w
	_panel.offset_right = half_w
	_panel.offset_top = -half_h
	_panel.offset_bottom = half_h
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(margin)

	var root_vb := VBoxContainer.new()
	root_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vb.add_theme_constant_override("separation", HudTokens.SECTION_GAP)
	root_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(root_vb)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 10)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vb.add_child(title_row)
	title_row.add_child(HudTokens.make_emblem())
	var title_col := VBoxContainer.new()
	title_col.add_theme_constant_override("separation", 1)
	title_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(title_col)
	var title := Label.new()
	title.text = "КАРТА ЛУНЫ"
	title.theme_type_variation = &"HudTitle"
	title_col.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "ОРБИТАЛЬНЫЙ ВИД  ·  Ø19 км  ·  ортографическая проекция"
	subtitle.theme_type_variation = &"HudSmall"
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_col.add_child(subtitle)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(spacer)
	title_row.add_child(HudTokens.make_national_tick())

	root_vb.add_child(HudTokens.make_divider())

	_coords_label = Label.new()
	_coords_label.theme_type_variation = &"HudValue"
	_coords_label.text = "—"
	_coords_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vb.add_child(_coords_label)

	_cursor_label = Label.new()
	_cursor_label.theme_type_variation = &"HudSmall"
	_cursor_label.text = "Курсор: —"
	_cursor_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vb.add_child(_cursor_label)

	var body := HBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vb.add_child(body)

	_map_host = Control.new()
	_map_host.custom_minimum_size = MAP_SIZE
	_map_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_host.clip_contents = true
	body.add_child(_map_host)

	_globe = _MoonMapGlobe.new()
	_globe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_globe.owner_panel = self
	_globe.cursor_world_changed.connect(_on_globe_cursor)
	_globe.surface_clicked.connect(_on_globe_clicked)
	_map_host.add_child(_globe)

	_flat_view = _FlatMapCanvas.new()
	_flat_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flat_view.owner_panel = self
	_flat_view.visible = false
	_map_host.add_child(_flat_view)

	var sidebar := VBoxContainer.new()
	sidebar.custom_minimum_size = Vector2(SIDEBAR_WIDTH, 0)
	sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sidebar.add_theme_constant_override("separation", 8)
	sidebar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(sidebar)

	var layers_title := Label.new()
	layers_title.text = "СЛОИ"
	layers_title.theme_type_variation = &"HudSmall"
	layers_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sidebar.add_child(layers_title)

	_chk_loot = _make_layer_check("Ресурсы (кучи)", true)
	_chk_deposits = _make_layer_check("Залежи", true)
	_chk_structures = _make_layer_check("Объекты", true)
	_chk_markers = _make_layer_check("Метки", true)
	sidebar.add_child(_chk_loot)
	sidebar.add_child(_chk_deposits)
	sidebar.add_child(_chk_structures)
	sidebar.add_child(_chk_markers)
	_chk_deposits.toggled.connect(_on_deposits_toggled)

	_deposit_legend = VBoxContainer.new()
	_deposit_legend.add_theme_constant_override("separation", 2)
	_deposit_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sidebar.add_child(_deposit_legend)
	_rebuild_deposit_legend()

	sidebar.add_child(HudTokens.make_divider())

	var markers_title := Label.new()
	markers_title.text = "МЕТКИ"
	markers_title.theme_type_variation = &"HudSmall"
	markers_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sidebar.add_child(markers_title)

	_marker_list = ItemList.new()
	_marker_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_marker_list.custom_minimum_size = Vector2(SIDEBAR_WIDTH, 140)
	_marker_list.select_mode = ItemList.SELECT_SINGLE
	_marker_list.allow_reselect = true
	_marker_list.item_selected.connect(_on_marker_list_selected)
	sidebar.add_child(_marker_list)

	_hint_label = Label.new()
	_hint_label.theme_type_variation = &"HudSmall"
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.text = (
		"Тяни глобус — вращение · колёсико — масштаб · ЛКМ — метка · ПКМ/Del — удалить · M/Esc — закрыть"
	)
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vb.add_child(_hint_label)

	_panel_overlay = HudTokens.make_panel_overlay(Vector2(PANEL_WIDTH, PANEL_HEIGHT))
	_panel.add_child(_panel_overlay)
	_sync_map_mode()


func _on_dimmer_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close()


func _make_layer_check(text: String, pressed: bool) -> CheckBox:
	var box := CheckBox.new()
	box.text = text
	box.button_pressed = pressed
	box.toggled.connect(func(_v: bool) -> void:
		if _globe != null:
			_globe.queue_redraw_markers()
		if _flat_view != null:
			_flat_view.queue_redraw()
	)
	return box


func _on_deposits_toggled(pressed: bool) -> void:
	if _globe != null:
		_globe.set_deposit_visible(pressed)


func _load_user_markers() -> void:
	_user_markers.clear()
	_next_marker_serial = 1
	for raw: Variant in WorldPersistence.get_map_markers():
		if not raw is Dictionary:
			continue
		var row: Dictionary = raw
		var marker_id := str(row.get("id", ""))
		var label := str(row.get("label", marker_id))
		var pos := SnapshotCodec.vector3_from_variant(row.get("position", []))
		if marker_id.is_empty() or not pos.is_finite():
			continue
		_user_markers.append({
			"id": marker_id,
			"label": label,
			"position": pos,
		})
		var serial := _serial_from_marker_id(marker_id)
		if serial >= _next_marker_serial:
			_next_marker_serial = serial + 1


func _persist_user_markers() -> void:
	var rows: Array = []
	for marker: Dictionary in _user_markers:
		var pos: Vector3 = marker["position"]
		rows.append({
			"id": str(marker["id"]),
			"label": str(marker["label"]),
			"position": [pos.x, pos.y, pos.z],
		})
	WorldPersistence.set_map_markers(rows)


func _serial_from_marker_id(marker_id: String) -> int:
	if not marker_id.begins_with("m:"):
		return 0
	return int(marker_id.substr(2))


func _refresh_overlay_entries() -> void:
	_overlay_entries.clear()
	if _gateway != null and _gateway.has_method("map_overlay_entries"):
		for row: Dictionary in _gateway.map_overlay_entries():
			_overlay_entries.append(row)


func _rebuild_marker_list() -> void:
	if _marker_list == null:
		return
	_marker_list.clear()
	for i in _user_markers.size():
		var marker: Dictionary = _user_markers[i]
		var pos: Vector3 = marker["position"]
		var text := "%s  (%.0f, %.0f, %.0f)" % [
			str(marker["label"]),
			pos.x,
			pos.y,
			pos.z,
		]
		_marker_list.add_item(text)
		_marker_list.set_item_metadata(i, str(marker["id"]))
		if str(marker["id"]) == _selected_marker_id:
			_marker_list.select(i)


func _on_marker_list_selected(index: int) -> void:
	var meta: Variant = _marker_list.get_item_metadata(index)
	_selected_marker_id = str(meta)
	if _planetoid and _globe != null:
		for marker: Dictionary in _user_markers:
			if str(marker["id"]) == _selected_marker_id:
				_globe.focus_world(marker["position"])
				break
		_globe.queue_redraw_markers()


func _update_coords_readout() -> void:
	if _coords_label == null or _player == null or not is_instance_valid(_player):
		return
	var pos: Vector3 = (_player as Node3D).global_position
	var heading := _current_heading()
	if _planetoid:
		var geo := lat_lon_altitude(pos)
		_coords_label.text = (
			"ПОЗ  %.1f  %.1f  %.1f   ·   φ %+0.2f°  λ %+0.2f°   ·   h %+0.1f м   ·   курс %03.0f°"
			% [pos.x, pos.y, pos.z, geo.x, geo.y, geo.z, heading]
		)
	else:
		_coords_label.text = (
			"ПОЗ  %.1f  %.1f  %.1f   ·   курс %03.0f°"
			% [pos.x, pos.y, pos.z, heading]
		)


func _current_heading() -> float:
	if _camera == null:
		return 0.0
	var basis: Basis
	if _camera.has_method("aim_transform"):
		basis = (_camera.call("aim_transform") as Transform3D).basis
	else:
		basis = _camera.global_transform.basis
	var forward := -basis.z
	return fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)


static func lat_lon_altitude(world_pos: Vector3) -> Vector3:
	var r := world_pos.length()
	if r <= 0.000001:
		return Vector3.ZERO
	var n := world_pos / r
	var lat := rad_to_deg(asin(clampf(n.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(n.x, -n.z))
	var alt := r - MoonGeometry.active_surface_radius_m()
	return Vector3(lat, lon, alt)


func _on_globe_cursor(world_pos: Vector3, inside: bool) -> void:
	if _cursor_label == null:
		return
	if not inside or world_pos.length_squared() < 0.0001:
		_cursor_label.text = "Курсор: —"
		return
	_set_cursor_readout(world_pos)


func _on_globe_clicked(world_pos: Vector3, button: MouseButton) -> void:
	if world_pos.length_squared() < 0.0001:
		return
	if button == MOUSE_BUTTON_LEFT:
		var hit_id := _hit_user_marker_world(world_pos)
		if not hit_id.is_empty():
			_selected_marker_id = hit_id
			_rebuild_marker_list()
			return
		_add_marker_at_world(world_pos)
	elif button == MOUSE_BUTTON_RIGHT:
		var hit_id_r := _hit_user_marker_world(world_pos)
		if not hit_id_r.is_empty():
			_selected_marker_id = hit_id_r
			_delete_selected_marker()


func on_map_cursor(uv: Vector2, inside: bool) -> void:
	## Flat-map path.
	if not inside:
		if _cursor_label != null:
			_cursor_label.text = "Курсор: —"
		return
	_set_cursor_readout(map_uv_to_world(uv))


func on_map_click(uv: Vector2, button: MouseButton) -> void:
	## Flat-map path.
	var world := map_uv_to_world(uv)
	_on_globe_clicked(world, button)


func _set_cursor_readout(world: Vector3) -> void:
	var deposit_id := ""
	if _planetoid and show_deposit_layer():
		deposit_id = MoonMapDepositOverlay.sample_at_world(world, _spawn_world_hint)
	var deposit_txt := ""
	if not deposit_id.is_empty():
		deposit_txt = "   ·   %s" % MoonMapDepositOverlay.display_name(deposit_id)
	if _planetoid:
		var geo := lat_lon_altitude(world)
		_cursor_label.text = (
			"Курсор  %.1f  %.1f  %.1f   ·   φ %+0.2f°  λ %+0.2f°%s"
			% [world.x, world.y, world.z, geo.x, geo.y, deposit_txt]
		)
	else:
		_cursor_label.text = (
			"Курсор  %.1f  %.1f  %.1f%s"
			% [world.x, world.y, world.z, deposit_txt]
		)


func map_uv_to_world(uv: Vector2) -> Vector3:
	var origin := Vector3.ZERO
	if _player != null and is_instance_valid(_player):
		origin = (_player as Node3D).global_position
	return Vector3(
		origin.x + (uv.x - 0.5) * FLAT_HALF_EXTENT_M * 2.0,
		origin.y,
		origin.z + (uv.y - 0.5) * FLAT_HALF_EXTENT_M * 2.0,
	)


func world_to_map_uv(world_pos: Vector3) -> Vector2:
	var origin := Vector3.ZERO
	if _player != null and is_instance_valid(_player):
		origin = (_player as Node3D).global_position
	var u := (world_pos.x - origin.x) / (FLAT_HALF_EXTENT_M * 2.0) + 0.5
	var v := (world_pos.z - origin.z) / (FLAT_HALF_EXTENT_M * 2.0) + 0.5
	return Vector2(clampf(u, 0.0, 1.0), clampf(v, 0.0, 1.0))


func _hit_user_marker_world(world: Vector3) -> String:
	if not show_marker_layer():
		return ""
	var dir := world.normalized()
	if dir.length_squared() < 0.0001:
		return ""
	var best_id := ""
	var best_arc := MARKER_HIT_ARC_M
	for marker: Dictionary in _user_markers:
		var mdir: Vector3 = (marker["position"] as Vector3).normalized()
		var ang := acos(clampf(dir.dot(mdir), -1.0, 1.0))
		var arc_m := ang * MoonGeometry.active_surface_radius_m()
		if arc_m <= best_arc:
			best_arc = arc_m
			best_id = str(marker["id"])
	return best_id


func _add_marker_at_world(world: Vector3) -> void:
	var marker_id := "m:%d" % _next_marker_serial
	var label := "МЕТКА %d" % _next_marker_serial
	_next_marker_serial += 1
	_user_markers.append({
		"id": marker_id,
		"label": label,
		"position": world,
	})
	_selected_marker_id = marker_id
	_persist_user_markers()
	_rebuild_marker_list()
	if _globe != null:
		_globe.queue_redraw_markers()


func _delete_selected_marker() -> void:
	if _selected_marker_id.is_empty():
		return
	var next: Array[Dictionary] = []
	for marker: Dictionary in _user_markers:
		if str(marker["id"]) != _selected_marker_id:
			next.append(marker)
	_user_markers = next
	_selected_marker_id = ""
	_persist_user_markers()
	_rebuild_marker_list()
	if _globe != null:
		_globe.queue_redraw_markers()


func _rebuild_deposit_legend() -> void:
	if _deposit_legend == null:
		return
	for child: Node in _deposit_legend.get_children():
		child.queue_free()
	for row: Dictionary in MoonMapDepositOverlay.legend_rows():
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 8)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var swatch_wrap := Panel.new()
		swatch_wrap.custom_minimum_size = Vector2(14, 14)
		swatch_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var swatch_sb := StyleBoxFlat.new()
		var c: Color = row["color"]
		swatch_sb.bg_color = Color(c.r, c.g, c.b, 0.95)
		swatch_sb.border_color = Color(HudTokens.COL_BORDER, 0.9)
		swatch_sb.set_border_width_all(1)
		swatch_sb.set_corner_radius_all(2)
		swatch_wrap.add_theme_stylebox_override("panel", swatch_sb)
		line.add_child(swatch_wrap)
		var lab := Label.new()
		lab.text = str(row["label"])
		lab.theme_type_variation = &"HudSmall"
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(lab)
		_deposit_legend.add_child(line)


func show_loot_layer() -> bool:
	return _chk_loot != null and _chk_loot.button_pressed


func show_deposit_layer() -> bool:
	return _chk_deposits != null and _chk_deposits.button_pressed


func show_structure_layer() -> bool:
	return _chk_structures != null and _chk_structures.button_pressed


func show_marker_layer() -> bool:
	return _chk_markers != null and _chk_markers.button_pressed


func player_world_position() -> Vector3:
	if _player != null and is_instance_valid(_player):
		return (_player as Node3D).global_position
	return Vector3.ZERO


func overlay_entries() -> Array[Dictionary]:
	return _overlay_entries


func user_markers() -> Array[Dictionary]:
	return _user_markers


func selected_marker_id() -> String:
	return _selected_marker_id


func player_heading() -> float:
	return _current_heading()


func entry_label(entry: Dictionary) -> String:
	var kind := str(entry.get("kind", ""))
	if kind == "loot":
		var resource_id := str(entry.get("resource_id", ""))
		var amount := float(entry.get("amount_kg", 0.0))
		return "%s %.0f кг" % [HudTokens.resource_label(resource_id), amount]
	if kind == "structure":
		var archetype_id := str(entry.get("archetype_id", ""))
		if _gateway != null:
			return _gateway.archetype_display_name(archetype_id)
		return HudTokens.archetype_label(archetype_id, "")
	return str(entry.get("id", ""))


## Legacy flat XZ map for flat_moon yard.
class _FlatMapCanvas:
	extends Control

	var owner_panel: Node
	var planetoid := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		clip_contents = true

	func _gui_input(event: InputEvent) -> void:
		if owner_panel == null:
			return
		if event is InputEventMouseMotion:
			var uv := _event_uv(event.position)
			owner_panel.call("on_map_cursor", uv, _inside(event.position))
		elif event is InputEventMouseButton and event.pressed:
			if not _inside(event.position):
				return
			owner_panel.call("on_map_click", _event_uv(event.position), event.button_index)
			accept_event()

	func _event_uv(local_pos: Vector2) -> Vector2:
		var s := size
		if s.x <= 1.0 or s.y <= 1.0:
			return Vector2(0.5, 0.5)
		return Vector2(
			clampf(local_pos.x / s.x, 0.0, 1.0),
			clampf(local_pos.y / s.y, 0.0, 1.0)
		)

	func _inside(local_pos: Vector2) -> bool:
		return Rect2(Vector2.ZERO, size).has_point(local_pos)

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		draw_rect(rect, Color(0.04, 0.05, 0.06, 1.0), true)
		var grid := Color(HudTokens.COL_BORDER, 0.45)
		for i in 9:
			var t := float(i) / 8.0
			draw_line(Vector2(t * size.x, 0.0), Vector2(t * size.x, size.y), grid, 1.0)
			draw_line(Vector2(0.0, t * size.y), Vector2(size.x, t * size.y), grid, 1.0)
		if owner_panel == null:
			return
		if bool(owner_panel.call("show_structure_layer")):
			for entry: Dictionary in owner_panel.call("overlay_entries"):
				if str(entry.get("kind", "")) != "structure":
					continue
				_draw_dot(
					owner_panel.call("world_to_map_uv", entry["position"]),
					HudTokens.COL_OK,
					3.5
				)
		if bool(owner_panel.call("show_loot_layer")):
			for entry: Dictionary in owner_panel.call("overlay_entries"):
				if str(entry.get("kind", "")) != "loot":
					continue
				_draw_dot(
					owner_panel.call("world_to_map_uv", entry["position"]),
					HudTokens.COL_WARNING,
					4.5
				)
		if bool(owner_panel.call("show_marker_layer")):
			for marker: Dictionary in owner_panel.call("user_markers"):
				_draw_dot(
					owner_panel.call("world_to_map_uv", marker["position"]),
					HudTokens.COL_VALID,
					5.0
				)
		_draw_dot(
			owner_panel.call(
				"world_to_map_uv",
				owner_panel.call("player_world_position")
			),
			HudTokens.COL_VALID,
			4.0
		)
		draw_rect(rect, Color(HudTokens.COL_OK, 0.5), false, 1.0)

	func _draw_dot(uv: Vector2, color: Color, radius: float) -> void:
		var p := Vector2(uv.x * size.x, uv.y * size.y)
		draw_circle(p, radius + 1.5, Color(0, 0, 0, 0.55))
		draw_circle(p, radius, color)
