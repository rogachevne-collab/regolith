class_name ProjectedAssemblyBody
extends RigidBody3D

static var impact_service: ImpactResolverService


func total_mass() -> float:
	return mass


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if impact_service != null and not freeze:
		impact_service.integrate_contacts(self, state)
	# Without custom_integrator the engine already integrates gravity and
	# damping; calling state.integrate_forces() here would apply them twice.
	if custom_integrator:
		state.integrate_forces()
