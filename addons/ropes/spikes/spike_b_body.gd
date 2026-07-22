extends RigidBody3D
# Spike B helper: logs when the physics server calls into the body, to compare
# ordering against the root's _physics_process.


func _integrate_forces(_state: PhysicsDirectBodyState3D) -> void:
	var root := get_parent()
	if root != null and root.has_method("note_event"):
		root.note_event("integrate_forces")
