extends CanvasLayer

@export var camera_path: NodePath = NodePath("../Camera")

const SETTINGS_PATH := "user://player_settings.cfg"

@onready var _panel: Control = $Panel
@onready var _sensitivity_slider: HSlider = (
	$Panel/Margin/Content/Sensitivity/Slider
)
@onready var _sensitivity_value: Label = (
	$Panel/Margin/Content/Sensitivity/Value
)
@onready var _fov_slider: HSlider = $Panel/Margin/Content/Fov/Slider
@onready var _fov_value: Label = $Panel/Margin/Content/Fov/Value
@onready var _soft_penumbra_check: CheckBox = (
	$Panel/Margin/Content/SoftPenumbra/Check
)
@onready var _close_button: Button = $Panel/Margin/Content/Close

var _camera: Camera3D
var _player: Node
var _soft_penumbra := false


func _ready() -> void:
	_camera = get_node(camera_path)
	_player = get_parent()
	_sensitivity_slider.value = float(_camera.get("sensitivity"))
	_fov_slider.value = _camera.fov
	_load_graphics_prefs()
	_apply_soft_penumbra()
	_update_labels()
	_sensitivity_slider.value_changed.connect(
		_on_sensitivity_changed
	)
	_sensitivity_slider.drag_ended.connect(
		_on_sensitivity_drag_ended
	)
	_fov_slider.value_changed.connect(_on_fov_changed)
	_fov_slider.drag_ended.connect(_on_fov_drag_ended)
	_soft_penumbra_check.toggled.connect(_on_soft_penumbra_toggled)
	_close_button.pressed.connect(close)
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse") and not visible:
		if open():
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("capture_mouse") and visible:
		close()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return visible


func open() -> bool:
	if not UIWindowStack.push(self, Callable(self, "close")):
		return false
	visible = true
	_player.call("set_gameplay_input_enabled", false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_close_button.grab_focus()
	return true


func close() -> void:
	visible = false
	_player.call("set_gameplay_input_enabled", true)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_panel.release_focus()
	UIWindowStack.remove(self)
	get_viewport().set_input_as_handled()


func _on_sensitivity_changed(value: float) -> void:
	_camera.set("sensitivity", clampf(value, 0.02, 1.5))
	_update_labels()


func _on_sensitivity_drag_ended(value_changed: bool) -> void:
	if value_changed:
		_camera.call(
			"set_look_sensitivity",
			_sensitivity_slider.value
		)


func _on_fov_changed(value: float) -> void:
	_camera.fov = clampf(value, 60.0, 110.0)
	_update_labels()


func _on_fov_drag_ended(value_changed: bool) -> void:
	if value_changed:
		_camera.call("set_camera_fov", _fov_slider.value)


func _on_soft_penumbra_toggled(pressed: bool) -> void:
	_soft_penumbra = pressed
	_apply_soft_penumbra()
	_save_graphics_prefs()


func _apply_soft_penumbra() -> void:
	if RenderingServer.has_method("set_rt_soft_penumbra"):
		RenderingServer.call("set_rt_soft_penumbra", _soft_penumbra)


func _load_graphics_prefs() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		_soft_penumbra_check.set_pressed_no_signal(_soft_penumbra)
		return
	_soft_penumbra = bool(config.get_value("graphics", "rt_soft_penumbra", false))
	_soft_penumbra_check.set_pressed_no_signal(_soft_penumbra)


func _save_graphics_prefs() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH) # keep look/fov if present
	config.set_value("graphics", "rt_soft_penumbra", _soft_penumbra)
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		push_warning("Could not save graphics settings: %s" % error_string(error))


func _update_labels() -> void:
	_sensitivity_value.text = "%.2f" % _sensitivity_slider.value
	_fov_value.text = "%d°" % roundi(_fov_slider.value)
