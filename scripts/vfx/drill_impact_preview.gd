extends Node3D
## Standalone preview for DrillImpactVfx: aims the effect into the
## floor and keeps it emitting so the look can be tuned in isolation.

@onready var _vfx: Node3D = $DrillImpactVfx
@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_vfx.rotation_degrees.x = -90.0
	_vfx.call(&"set_active", true)
	_camera.look_at(Vector3(0, 0.25, 0))
