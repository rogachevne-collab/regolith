extends CanvasLayer

@export var camera_path: NodePath = NodePath("../Camera")

@onready var _panel: Control = $Panel
@onready var _sensitivity_slider: HSlider = (
	$Panel/Margin/Content/Sensitivity/Slider
)
@onready var _sensitivity_value: Label = (
	$Panel/Margin/Content/Sensitivity/Value
)
@onready var _fov_slider: HSlider = $Panel/Margin/Content/Fov/Slider
@onready var _fov_value: Label = $Panel/Margin/Content/Fov/Value
@onready var _close_button: Button = $Panel/Margin/Content/Close

var _camera: Camera3D
var _player: Node


func _ready() -> void:
	_camera = get_node(camera_path)
	_player = get_parent()
	_sensitivity_slider.value = float(_camera.get("sensitivity"))
	_fov_slider.value = _camera.fov
	_update_labels()
	_sensitivity_slider.value_changed.connect(
		_on_sensitivity_changed
	)
	_sensitivity_slider.drag_ended.connect(
		_on_sensitivity_drag_ended
	)
	_fov_slider.value_changed.connect(_on_fov_changed)
	_fov_slider.drag_ended.connect(_on_fov_drag_ended)
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


func _update_labels() -> void:
	_sensitivity_value.text = "%.2f" % _sensitivity_slider.value
	_fov_value.text = "%d°" % roundi(_fov_slider.value)
