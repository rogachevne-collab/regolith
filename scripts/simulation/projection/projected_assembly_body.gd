class_name ProjectedAssemblyBody
extends RigidBody3D

static var impact_service: ImpactResolverService


func total_mass() -> float:
	return mass


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if impact_service != null and not freeze:
		impact_service.integrate_contacts(self, state)
	state.integrate_forces()
