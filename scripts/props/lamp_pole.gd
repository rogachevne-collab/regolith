extends Node3D
## Simple stand + omni bulb for local lighting / RT occluder tests.


func _ready() -> void:
	add_to_group("world_rt_mesh")
