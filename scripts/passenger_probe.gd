extends "res://scripts/character_motor.gd"

@export var walk_input := Vector2.ZERO
var jump_requested := false


func _ready() -> void:
	super._ready()


func _physics_process(delta: float) -> void:
	var move_direction := Vector3(
		walk_input.x,
		0.0,
		walk_input.y
	)
	move_character(
		move_direction,
		false,
		jump_requested,
		delta
	)
	jump_requested = false


func request_jump() -> void:
	jump_requested = true
