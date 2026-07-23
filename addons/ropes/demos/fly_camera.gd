extends Camera3D
# Editor-style fly camera for test scenes. Hold RMB: mouselook + WASD fly,
# Q/E down/up, Shift = fast, wheel = fly speed. Wheel without RMB: dolly.
# Uses physical keys, so it works on any keyboard layout.

@export var speed := 8.0
@export var fast_multiplier := 4.0
@export var sensitivity := 0.003

var _flying := false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				_flying = event.pressed
				Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if event.pressed
						else Input.MOUSE_MODE_VISIBLE)
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					if _flying:
						speed = minf(speed * 1.15, 200.0)
					else:
						global_position -= global_basis.z * (speed * 0.15)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					if _flying:
						speed = maxf(speed / 1.15, 0.5)
					else:
						global_position += global_basis.z * (speed * 0.15)
	elif event is InputEventMouseMotion and _flying:
		rotation.y -= event.relative.x * sensitivity
		rotation.x = clampf(rotation.x - event.relative.y * sensitivity, -1.5, 1.5)


func _process(dt: float) -> void:
	if not _flying:
		return
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		dir -= global_basis.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += global_basis.z
	if Input.is_physical_key_pressed(KEY_A):
		dir -= global_basis.x
	if Input.is_physical_key_pressed(KEY_D):
		dir += global_basis.x
	if Input.is_physical_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q):
		dir -= Vector3.UP
	if dir == Vector3.ZERO:
		return
	var mult := fast_multiplier if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0
	global_position += dir.normalized() * (speed * mult * dt)
