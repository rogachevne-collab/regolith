extends Camera3D

@export var sensitivity := 0.25
@export var min_pitch := -85.0
@export var max_pitch := 85.0

var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var motion: Vector2 = event.relative
		_yaw -= motion.x * sensitivity
		_pitch = clampf(_pitch - motion.y * sensitivity, min_pitch, max_pitch)
		rotation_degrees = Vector3(_pitch, _yaw, 0.0)

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			KEY_R:
				if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
