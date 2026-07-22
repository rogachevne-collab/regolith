class_name ProjectedAssemblyBody
extends RigidBody3D

static var impact_service: ImpactResolverService


## Every projected body stands in loose material the same way — rover, dozer,
## anything broken off one. Attached here because this is where assemblies
## actually become physics: `assembly.gd` is the older stand-alone path and the
## world does not build rovers through it, so a coupling hung there never runs
## for anything the player drives.
##
## The component reads this body's collision shapes and nothing else, so it
## needs no knowledge of archetypes and costs nothing where there is no
## material to stand in.
func _ready() -> void:
	for child in get_children():
		if child is GranularBody:
			return
	var coupling := GranularBody.new()
	coupling.name = "GranularBody"
	add_child(coupling)


func total_mass() -> float:
	return mass


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if impact_service != null and not freeze:
		impact_service.integrate_contacts(self, state)
	# Without custom_integrator the engine already integrates gravity and
	# damping; calling state.integrate_forces() here would apply them twice.
	if custom_integrator:
		state.integrate_forces()
