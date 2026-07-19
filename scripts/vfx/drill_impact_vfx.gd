class_name DrillImpactVfx
extends Node3D
## Contact-point VFX for the hand drill: dust jet, lingering dust
## plume, rock chips, and hot spark streaks. The node is positioned
## at the drill contact each physics frame with -Z pointing into the
## surface, so every emitter sprays along local +Z (out of the rock).

var _active := false


func set_active(active: bool) -> void:
	if _active == active:
		return
	_active = active
	for child in get_children():
		var particles := child as GPUParticles3D
		if particles != null:
			particles.emitting = active
