@tool
extends ScrollContainer

## Док «Мастер деталей». Четыре шага, ноль осей, ноль тумблеров:
## 1. Закинь модель — футпринт и масса меряются сами.
## 2. Поверни превью «глазами игрока» — так деталь встанет при выборе.
## 3. Кликни точки крепления прямо по модели.
## 4. Испечь.

const _REFRESH_INTERVAL_S := 0.5
const _TEMPLATE_SCENE := """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/authoring/part_authoring_root.gd" id="1"]

[node name="PartAuthoring" type="Node3D"]
script = ExtResource("1")
"""

var plugin: EditorPlugin

var _root: PartAuthoringRoot
var _refresh_timer := 0.0
var _preview_signature := ""

var _model_label: Label
var _pose_pivot: Node3D
var _pose_viewport: SubViewport
var _pose_camera: Camera3D
var _place_button: Button
var _socket_option: OptionButton
var _port_role_option: OptionButton
var _kind_option: OptionButton
var _part_id_edit: LineEdit
var _display_name_edit: LineEdit
var _diagnostics_label: RichTextLabel
var _no_scene_label: Label
var _steps_box: VBoxContainer
var _model_dialog: EditorFileDialog
var _new_part_dialog: EditorFileDialog
var _stale_dialog: ConfirmationDialog
var _stale_path := ""


func _init() -> void:
	custom_minimum_size = Vector2(280, 0)
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_build_ui()


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = _REFRESH_INTERVAL_S
	_sync_to_edited_scene()


func place_mode_active() -> bool:
	return (
		_place_button != null
		and _place_button.button_pressed
		and _root != null
	)


## Called by the plugin when the author clicks the model in the 3D view.
func place_connector_at(
	root: PartAuthoringRoot,
	local_point: Vector3,
	_local_normal: Vector3
) -> void:
	var marker := MountPadMarker.new()
	marker.socket_kind = _selected_socket_kind()
	if marker.is_electric():
		marker.port_role = _selected_port_role()
	# The clicked point IS the mount: whatever bit of the model the author
	# picked (the tip of a stub axle, a bracket ear) is what will touch the
	# target. The grid decides where the part goes, this decides what of the
	# part gets put there.
	marker.snap_to_face = false
	marker.name = _unique_marker_name(root)
	root.add_child(marker)
	var tree := root.get_tree()
	marker.owner = (
		tree.edited_scene_root
		if tree != null and tree.edited_scene_root != null
		else root
	)
	marker.position = local_point
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(marker)
	EditorInterface.mark_scene_as_unsaved()
	_show_message("точка поставлена: %s" % _socket_option.get_item_text(
		_socket_option.selected
	))


func _build_ui() -> void:
	_steps_box = VBoxContainer.new()
	_steps_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_steps_box)

	_no_scene_label = Label.new()
	_no_scene_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_no_scene_label.text = (
		"Открой сцену детали (PartAuthoringRoot в корне)\n"
		+ "или создай новую:"
	)
	_steps_box.add_child(_no_scene_label)

	var new_part := Button.new()
	new_part.text = "✚ Создать новую деталь…"
	new_part.pressed.connect(_on_new_part_pressed)
	_steps_box.add_child(new_part)

	# --- Шаг 1: модель ---
	_steps_box.add_child(_step_header("1. Модель"))
	var pick_model := Button.new()
	pick_model.text = "Выбрать модель…"
	pick_model.tooltip_text = (
		"Сцена или меш детали. Размер и масса посчитаются сами —\n"
		+ "двигать модель в ноль не обязательно."
	)
	pick_model.pressed.connect(_on_pick_model_pressed)
	_steps_box.add_child(pick_model)
	_model_label = Label.new()
	_model_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_model_label.text = "модель не выбрана"
	_steps_box.add_child(_model_label)

	# --- Шаг 2: поза глазами игрока ---
	_steps_box.add_child(_step_header("2. Как увидит игрок"))
	var pose_hint := Label.new()
	pose_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pose_hint.text = "Поверни, пока не встанет «лицом». Так деталь появится при выборе в стройке."
	_steps_box.add_child(pose_hint)
	_steps_box.add_child(_build_pose_viewport())
	var rotate_row := HBoxContainer.new()
	rotate_row.add_child(_rotate_button("⟲", Vector3.UP, "повернуть влево"))
	rotate_row.add_child(_rotate_button("⟳", Vector3.DOWN, "повернуть вправо"))
	rotate_row.add_child(_rotate_button("↑", Vector3.RIGHT, "наклонить от себя"))
	rotate_row.add_child(_rotate_button("↓", Vector3.LEFT, "наклонить на себя"))
	rotate_row.add_child(_rotate_button("⤾", Vector3.FORWARD, "крен влево"))
	rotate_row.add_child(_rotate_button("⤿", Vector3.BACK, "крен вправо"))
	_steps_box.add_child(rotate_row)

	# --- Шаг 3: крепления ---
	_steps_box.add_child(_step_header("3. Точки крепления"))
	_socket_option = OptionButton.new()
	_socket_option.add_item("Обычное крепление")
	_socket_option.add_item("Ось колеса (на ступице)")
	_socket_option.add_item("Гнездо колеса (на подвеске)")
	_socket_option.add_item("⚡ Электроточка (опционально)")
	_socket_option.item_selected.connect(_on_socket_kind_selected)
	_steps_box.add_child(_socket_option)
	_port_role_option = OptionButton.new()
	_port_role_option.add_item("Вход и выход")
	_port_role_option.add_item("Только вход (потребитель)")
	_port_role_option.add_item("Только выход (источник)")
	_port_role_option.visible = false
	_steps_box.add_child(_port_role_option)
	var place_hint := Label.new()
	place_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	place_hint.text = (
		"Кликать — в ОСНОВНОМ 3D-окне редактора по самой модели"
		+ " (не в превью выше). Точка встанет ровно в место клика."
	)
	_steps_box.add_child(place_hint)
	_place_button = Button.new()
	_place_button.toggle_mode = true
	_place_button.tooltip_text = (
		"Включи, перейди в 3D-окно и кликай по модели: точка встанет там,\n"
		+ "куда попал — хоть на ступицу, хоть на кронштейн.\n"
		+ "Выключи режим, чтобы снова крутить камеру кликом."
	)
	_place_button.toggled.connect(_on_place_mode_toggled)
	_steps_box.add_child(_place_button)
	_update_place_button_look(false)
	var generate := Button.new()
	generate.text = "Сгенерировать по граням"
	generate.pressed.connect(_on_generate_pressed)
	_steps_box.add_child(generate)

	# --- Шаг 4: испечь ---
	_steps_box.add_child(_step_header("4. Испечь"))
	_kind_option = OptionButton.new()
	_kind_option.add_item("Блок / рама")
	_kind_option.add_item("Колесо")
	_kind_option.add_item("Подвеска")
	_kind_option.add_item("Батарея")
	_kind_option.add_item("Источник энергии")
	_kind_option.item_selected.connect(_on_kind_selected)
	_steps_box.add_child(_kind_option)
	_part_id_edit = LineEdit.new()
	_part_id_edit.placeholder_text = "part_id (латиницей, без пробелов)"
	_part_id_edit.text_changed.connect(_on_part_id_changed)
	_steps_box.add_child(_part_id_edit)
	_display_name_edit = LineEdit.new()
	_display_name_edit.placeholder_text = "Название для игрока"
	_display_name_edit.text_changed.connect(_on_display_name_changed)
	_steps_box.add_child(_display_name_edit)
	var params_hint := Label.new()
	params_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	params_hint.text = (
		"Тонкая настройка (радиус, жёсткость, ёмкость батареи…) — в инспекторе корня.\n"
		+ "Для батареи/источника не забудь поставить электроточки на шаге 3"
		+ " (⚡, роль вход/выход)."
	)
	_steps_box.add_child(params_hint)
	var bake := Button.new()
	bake.text = "🔥 Испечь деталь"
	bake.pressed.connect(_on_bake_pressed)
	_steps_box.add_child(bake)
	_diagnostics_label = RichTextLabel.new()
	_diagnostics_label.fit_content = true
	_diagnostics_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diagnostics_label.custom_minimum_size = Vector2(0, 60)
	_steps_box.add_child(_diagnostics_label)

	_model_dialog = EditorFileDialog.new()
	_model_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_model_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	for pattern: String in ["*.tscn", "*.scn", "*.glb", "*.gltf", "*.fbx", "*.obj"]:
		_model_dialog.add_filter(pattern)
	_model_dialog.file_selected.connect(_on_model_file_selected)
	add_child(_model_dialog)

	_new_part_dialog = EditorFileDialog.new()
	_new_part_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_new_part_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_new_part_dialog.current_dir = "res://scenes/authoring"
	_new_part_dialog.add_filter("*.tscn")
	_new_part_dialog.file_selected.connect(_on_new_part_file_selected)
	add_child(_new_part_dialog)

	_stale_dialog = ConfirmationDialog.new()
	_stale_dialog.ok_button_text = "Удалить"
	_stale_dialog.cancel_button_text = "Оставить"
	_stale_dialog.confirmed.connect(_on_stale_delete_confirmed)
	add_child(_stale_dialog)


func _build_pose_viewport() -> Control:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.custom_minimum_size = Vector2(0, 300)
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pose_viewport = SubViewport.new()
	_pose_viewport.own_world_3d = true
	_pose_viewport.transparent_bg = false
	container.add_child(_pose_viewport)
	_pose_camera = Camera3D.new()
	# «Глаза игрока»: чуть выше и спереди; дистанция подгоняется под деталь
	# в _refresh_pose_preview, чтобы и колесо, и балка влезали в кадр.
	_pose_camera.position = Vector3(0.0, 1.2, 2.6)
	_pose_viewport.add_child(_pose_camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	_pose_viewport.add_child(light)
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.14, 0.17)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.75)
	env.ambient_light_energy = 0.6
	environment.environment = env
	_pose_viewport.add_child(environment)
	_pose_pivot = Node3D.new()
	_pose_viewport.add_child(_pose_pivot)
	return container


func _step_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	return label


func _rotate_button(
	glyph: String,
	axis: Vector3,
	tooltip: String
) -> Button:
	var button := Button.new()
	button.text = glyph
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(34, 30)
	button.pressed.connect(_on_rotate_pressed.bind(axis))
	return button


func _sync_to_edited_scene() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var next_root := scene_root as PartAuthoringRoot
	if next_root != _root:
		_root = next_root
		_preview_signature = ""
		if _root != null:
			_part_id_edit.text = _root.part_id
			_display_name_edit.text = _root.display_name
			_kind_option.selected = int(_root.part_kind)
			_diagnostics_label.text = "\n".join(_root.last_bake_diagnostics)
	var has_root := _root != null
	_no_scene_label.visible = not has_root
	for child: Node in _steps_box.get_children():
		if child == _no_scene_label:
			continue
		if child is Control and not has_root:
			(child as Control).modulate.a = 0.45
		elif child is Control:
			(child as Control).modulate.a = 1.0
	if not has_root:
		return
	_model_label.text = (
		"модель: %s\nфутпринт: %d×%d×%d клеток"
		% [
			(
				_root.visual_scene.resource_path.get_file()
				if _root.visual_scene != null
				else "не выбрана"
			),
			_root.size_cells.x,
			_root.size_cells.y,
			_root.size_cells.z,
		]
	)
	_refresh_pose_preview()


func _refresh_pose_preview() -> void:
	if _root == null or _pose_pivot == null:
		return
	var signature := "%s|%s|%s|%d" % [
		(
			_root.visual_scene.resource_path
			if _root.visual_scene != null
			else ""
		),
		_root.size_cells,
		_root.model_offset,
		_root.default_orientation_index,
	]
	if signature == _preview_signature:
		return
	_preview_signature = signature
	for child: Node in _pose_pivot.get_children():
		child.queue_free()
	var basis := OrientationUtil.orientation_basis(
		_root.default_orientation_index
	)
	# Крутим вокруг центра футпринта, чтобы деталь не уезжала из кадра.
	var center := Vector3(_root.size_cells) * GridMetric.CELL_SIZE_M * 0.5
	_pose_pivot.transform = Transform3D(
		basis,
		-(basis * center)
	)
	if _root.visual_scene != null:
		var instance := _root.visual_scene.instantiate()
		var node3d := instance as Node3D
		if node3d != null:
			_pose_pivot.add_child(node3d)
			# Same compensation as the authoring scene: pivot-at-hub-tip
			# models sit centred without any re-export.
			node3d.position = _root.model_offset
		else:
			instance.free()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.8, 1.0, 0.10)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(_root.size_cells) * GridMetric.CELL_SIZE_M
	box.mesh = mesh
	box.position = center
	box.material_override = mat
	_pose_pivot.add_child(box)
	_frame_pose_camera()


## Fit the player-view camera to the part so a wheel and a 5-cell beam both
## fill the frame instead of drowning in it or overflowing.
func _frame_pose_camera() -> void:
	if _pose_camera == null or _root == null:
		return
	var extent := (
		Vector3(_root.size_cells) * GridMetric.CELL_SIZE_M
	).length() * 0.5
	var distance := maxf(extent * 2.1, 0.8)
	var eye := Vector3(0.0, distance * 0.45, distance)
	_pose_camera.look_at_from_position(eye, Vector3.ZERO, Vector3.UP)


## Godot silently renames colliding children to "@Node3D@12345" garbage —
## hand out Mount_1, Mount_2, … ourselves instead.
func _unique_marker_name(root: Node) -> String:
	var index := 1
	while root.has_node("Mount_%d" % index):
		index += 1
	return "Mount_%d" % index


func _selected_socket_kind() -> MountPadMarker.SocketKind:
	match _socket_option.selected:
		1:
			return MountPadMarker.SocketKind.WHEEL_PLUG
		2:
			return MountPadMarker.SocketKind.WHEEL_SOCKET
		3:
			return MountPadMarker.SocketKind.ELECTRIC_PORT
		_:
			return MountPadMarker.SocketKind.STRUCTURAL


func _selected_port_role() -> MountPadMarker.PortRole:
	match _port_role_option.selected:
		1:
			return MountPadMarker.PortRole.IN
		2:
			return MountPadMarker.PortRole.OUT
		_:
			return MountPadMarker.PortRole.BIDIRECTIONAL


func _on_socket_kind_selected(index: int) -> void:
	_port_role_option.visible = index == 3


func _on_rotate_pressed(axis: Vector3) -> void:
	if _root == null:
		return
	var current := OrientationUtil.orientation_basis(
		_root.default_orientation_index
	)
	var rotated := Basis(axis.normalized(), PI * 0.5) * current
	_root.default_orientation_index = _nearest_orientation_index(rotated)
	EditorInterface.mark_scene_as_unsaved()
	_refresh_pose_preview()


func _nearest_orientation_index(basis: Basis) -> int:
	var snapped_basis := basis.orthonormalized()
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if OrientationUtil.orientation_basis(index).is_equal_approx(
			snapped_basis
		):
			return index
	return _root.default_orientation_index if _root != null else 0


func _on_pick_model_pressed() -> void:
	_model_dialog.popup_file_dialog()


func _on_model_file_selected(path: String) -> void:
	if _root == null:
		return
	var resource: Resource = load(path)
	var packed := resource as PackedScene
	if packed == null:
		_show_message("не удалось загрузить сцену: %s" % path)
		return
	_root.visual_scene = packed
	_show_message("модель выбрана, размер посчитан")


func _on_new_part_pressed() -> void:
	_new_part_dialog.popup_file_dialog()


func _on_new_part_file_selected(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_show_message("не удалось создать %s" % path)
		return
	file.store_string(_TEMPLATE_SCENE)
	file.close()
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)


func _on_place_mode_toggled(enabled: bool) -> void:
	_update_place_button_look(enabled)
	if not enabled:
		_show_message("режим точек выключен")
		return
	if _root == null:
		return
	# The 3D gizmo input only reaches our plugin while it "handles" the
	# selection — put the part root in focus so clicks land immediately.
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(_root)
	_show_message(
		"режим точек включён — кликай по модели в 3D-окне"
	)


## The toggle must read as a mode switch, not a one-shot button: loud text
## and a green tint while armed, calm text when off.
func _update_place_button_look(enabled: bool) -> void:
	if _place_button == null:
		return
	if enabled:
		_place_button.text = "🟢 РЕЖИМ ТОЧЕК ВКЛЮЧЁН — нажми, чтобы выключить"
		for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			_place_button.add_theme_color_override(
				state,
				Color(0.55, 1.0, 0.6)
			)
	else:
		_place_button.text = "✛ Ставить точки кликом по модели"
		for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			_place_button.remove_theme_color_override(state)


func _on_generate_pressed() -> void:
	if _root == null:
		return
	_root.generate_mounts()
	EditorInterface.mark_scene_as_unsaved()
	_diagnostics_label.text = "\n".join(_root.last_bake_diagnostics)


func _on_kind_selected(index: int) -> void:
	if _root == null:
		return
	_root.part_kind = index as PartAuthoringRoot.PartKind
	EditorInterface.mark_scene_as_unsaved()


func _on_part_id_changed(text: String) -> void:
	if _root != null:
		_root.part_id = text


func _on_display_name_changed(text: String) -> void:
	if _root != null:
		_root.display_name = text


func _on_bake_pressed() -> void:
	if _root == null:
		return
	var result := _root.bake()
	_diagnostics_label.text = "\n".join(_root.last_bake_diagnostics)
	if bool(result.get("ok", false)):
		_show_message("испечено: %s" % str(result.get("path", "")))
		EditorInterface.mark_scene_as_unsaved()
	else:
		_show_message("бак с ошибками — смотри диагностику")
	var stale := str(result.get("stale_path", ""))
	if not stale.is_empty():
		_stale_path = stale
		_stale_dialog.dialog_text = (
			"part_id сменился. Старый файл детали больше не нужен:\n%s\n\nУдалить его?"
			% stale
		)
		_stale_dialog.popup_centered()


func _on_stale_delete_confirmed() -> void:
	if _stale_path.is_empty():
		return
	var absolute := ProjectSettings.globalize_path(_stale_path)
	var error := DirAccess.remove_absolute(absolute)
	if error == OK:
		_show_message("старый файл удалён: %s" % _stale_path)
		EditorInterface.get_resource_filesystem().scan()
	else:
		_show_message(
			"не смог удалить %s (код %d) — удали руками" % [_stale_path, error]
		)
	_stale_path = ""


func _show_message(text: String) -> void:
	if _diagnostics_label != null:
		_diagnostics_label.text = text
