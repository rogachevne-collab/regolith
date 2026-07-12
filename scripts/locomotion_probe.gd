extends "res://scripts/character_motor.gd"

var move_input := Vector3.ZERO
var sprint_input := false
var jump_input := false


func _physics_process(delta: float) -> void:
	move_character(
		move_input,
		sprint_input,
		jump_input,
		delta
	)
	jump_input = false


func request_jump() -> void:
	jump_input = true
