class_name GranularStreamVfx
extends Node3D
## Continuous spoil stream: dense soft grit + lingering dust haze.
## Presentation only — height field remains truth.

var _active := false


func set_active(active: bool) -> void:
	if _active == active:
		return
	_active = active
	for child in get_children():
		var particles := child as GPUParticles3D
		if particles == null:
			continue
		particles.emitting = active
		if active:
			particles.restart()


## World-space stream direction (identity basis on this node).
func aim(
	direction: Vector3,
	spread: float = -1.0,
	speed_min: float = -1.0,
	speed_max: float = -1.0,
	emission_radius: float = -1.0
) -> void:
	var dir := direction
	if dir.length_squared() < 1e-8:
		dir = Vector3(0.0, -1.0, 0.0)
	else:
		dir = dir.normalized()
	for child in get_children():
		var particles := child as GPUParticles3D
		if particles == null:
			continue
		var mat := particles.process_material as ParticleProcessMaterial
		if mat == null:
			continue
		mat.direction = dir
		if spread >= 0.0:
			mat.spread = spread
		if speed_min >= 0.0:
			mat.initial_velocity_min = speed_min
		if speed_max >= 0.0:
			mat.initial_velocity_max = speed_max
		if emission_radius >= 0.0:
			mat.emission_sphere_radius = emission_radius
