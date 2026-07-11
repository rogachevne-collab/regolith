extends Node3D

@onready var _cart: RigidBody3D = $Cart

var _elapsed := 0.0
var _saw_invalid_position := false


func _physics_process(delta: float) -> void:
	_elapsed += delta
	var position: Vector3 = _cart.global_position
	if (
		is_nan(position.x)
		or is_nan(position.y)
		or is_nan(position.z)
		or is_inf(position.x)
		or is_inf(position.y)
		or is_inf(position.z)
	):
		_saw_invalid_position = true

	if _elapsed < 10.0:
		return

	set_physics_process(false)
	if _saw_invalid_position:
		_fail("cart position became NaN or infinite")
		return
	if _cart.linear_velocity.length() >= 0.05:
		_fail("linear speed %.4f is too high" % _cart.linear_velocity.length())
		return
	if _cart.angular_velocity.length() >= 0.05:
		_fail("angular speed %.4f is too high" % _cart.angular_velocity.length())
		return
	if _cart.global_position.y < 1.0 or _cart.global_position.y > 1.4:
		_fail("origin height %.4f is outside 1.0..1.4" % _cart.global_position.y)
		return

	print("POC1A: PASS")
	get_tree().quit(0)


func _fail(reason: String) -> void:
	print("POC1A: FAIL %s" % reason)
	get_tree().quit(1)
