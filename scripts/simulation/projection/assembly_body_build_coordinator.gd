class_name AssemblyBodyBuildCoordinator
extends RefCounted
## Body creation, collider attach, mass/COM helpers extracted from
## SimulationPhysicsProjection.

const MIN_MASS := 0.001
const BODY_NAME_PREFIX := "AssemblyBody_"
const GROUP_BODY_NAME_PREFIX := "AssemblyGroupBody_"
const ASSEMBLY_BOUNCE := 0.32
const ASSEMBLY_FRICTION := 0.42
const COLLISION_LAYER_TERRAIN := 1
const COLLISION_LAYER_ASSEMBLY := 2
const COLLISION_MASK_ASSEMBLY := (
	COLLISION_LAYER_TERRAIN | COLLISION_LAYER_ASSEMBLY
)
const FragmentBodyScript := preload(
	"res://scripts/simulation/projection/projected_assembly_body.gd"
)

static func create_group_body(
	projection,
	assembly_id: int,
	group_id: int,
	is_static: bool
) -> PhysicsBody3D:
	var body: PhysicsBody3D
	if is_static:
		body = StaticBody3D.new()
	else:
		var rigid := AssemblyBodyBuildCoordinator.FragmentBodyScript.new() as RigidBody3D
		rigid.physics_material_override = AssemblyBodyBuildCoordinator.get_assembly_physics_material(projection)
		body = rigid
	body.name = "%s%d_%d" % [
		AssemblyBodyBuildCoordinator.GROUP_BODY_NAME_PREFIX,
		assembly_id,
		group_id,
	]
	body.collision_layer = AssemblyBodyBuildCoordinator.COLLISION_LAYER_ASSEMBLY
	body.collision_mask = AssemblyBodyBuildCoordinator.COLLISION_MASK_ASSEMBLY
	body.set_meta("assembly_id", assembly_id)
	body.set_meta("body_group_id", group_id)
	return body


static func create_body(
	projection,
	assembly_id: int,
	anchored: bool
) -> PhysicsBody3D:
	var body: PhysicsBody3D
	if anchored:
		body = StaticBody3D.new()
	else:
		var rigid: RigidBody3D
		if projection._mounted_bodies.has(assembly_id):
			rigid = RigidBody3D.new()
		else:
			# Locomotive bodies also carry the fragment script: precise
			# contact impulses come from _integrate_forces, and the script
			# no longer conflicts with wheel forces (no custom integrator).
			rigid = AssemblyBodyBuildCoordinator.FragmentBodyScript.new() as RigidBody3D
		rigid.freeze = false
		rigid.physics_material_override = AssemblyBodyBuildCoordinator.get_assembly_physics_material(projection)
		body = rigid
	body.name = "%s%d" % [AssemblyBodyBuildCoordinator.BODY_NAME_PREFIX, assembly_id]
	body.collision_layer = AssemblyBodyBuildCoordinator.COLLISION_LAYER_ASSEMBLY
	body.collision_mask = AssemblyBodyBuildCoordinator.COLLISION_MASK_ASSEMBLY
	body.set_meta("assembly_id", assembly_id)
	AssemblyBodyBuildCoordinator.apply_collision_profile(projection, assembly_id, body)
	return body


static func attach_colliders_to_body(
	projection,
	body: PhysicsBody3D,
	records: Array[Dictionary],
	assembly_id: int,
	element_ids: Array[int]
) -> void:
	var colliders_by_element: Dictionary = {}
	for record: Dictionary in records:
		var element_id: int = int(record["element_id"])
		var existing_colliders: Array = colliders_by_element.get(
			element_id,
			[]
		)
		var collider := CollisionShape3D.new()
		collider.name = "ElementCollider_%d_%d" % [
			element_id,
			existing_colliders.size(),
		]
		collider.shape = record["shape"]
		collider.transform = record["local_transform"]
		collider.set_meta("element_id", element_id)
		collider.set_meta("collider_index", int(record["collider_index"]))
		collider.set_meta(
			"collider_local_cell",
			record["collider_local_cell"]
		)
		body.add_child(collider)
		if not colliders_by_element.has(element_id):
			colliders_by_element[element_id] = []
		colliders_by_element[element_id].append(collider)
	for element_id: int in element_ids:
		if not colliders_by_element.has(element_id):
			continue
		projection._element_records[element_id] = {
			"assembly_id": assembly_id,
			"body": body,
			"colliders": colliders_by_element[element_id],
		}


static func clear_body_colliders(
	projection,
	body: PhysicsBody3D) -> void:
	var stale: Array[CollisionShape3D] = []
	for child_node: Node in body.get_children():
		if child_node is CollisionShape3D:
			stale.append(child_node as CollisionShape3D)
	for collider: CollisionShape3D in stale:
		collider.disabled = true
		collider.queue_free()

## Snapshot live per-group body motions (group_id -> AssemblyMotionState)
## before a multibody teardown so the rebuild can reseed surviving groups.


static func apply_body_groups(
	projection,
	assembly_id: int,
	body: PhysicsBody3D
) -> void:
	for group_name: Variant in projection._body_groups.get(assembly_id, []):
		if body is RigidBody3D:
			(body as RigidBody3D).add_to_group(str(group_name))


static func apply_collision_profile(
	projection,
	assembly_id: int,
	body: PhysicsBody3D
) -> void:
	var profile: Variant = projection._collision_profiles.get(assembly_id)
	if profile is Dictionary:
		body.collision_layer = int(profile.get("layer", body.collision_layer))
		body.collision_mask = int(profile.get("mask", body.collision_mask))


static func get_assembly_physics_material(
	projection
) -> PhysicsMaterial:
	if projection._assembly_physics_material == null:
		projection._assembly_physics_material = PhysicsMaterial.new()
		projection._assembly_physics_material.friction = AssemblyBodyBuildCoordinator.ASSEMBLY_FRICTION
		projection._assembly_physics_material.bounce = AssemblyBodyBuildCoordinator.ASSEMBLY_BOUNCE
	return projection._assembly_physics_material


static func get_locomotive_physics_material(
	projection
) -> PhysicsMaterial:
	if projection._locomotive_physics_material == null:
		projection._locomotive_physics_material = PhysicsMaterial.new()
		projection._locomotive_physics_material.friction = AssemblyBodyBuildCoordinator.ASSEMBLY_FRICTION
		projection._locomotive_physics_material.bounce = WheelPhysicsTickCoordinator.LOCOMOTIVE_BOUNCE
	return projection._locomotive_physics_material


## Soften locomotive↔terrain contact cost without removing the safety net:
## no CCD, no bounce. Applies to chassis/carriage bodies only — wheel bodies
## carry their own tire material (see _configure_wheel_rigid).


static func apply_locomotive_rigid_tuning(
	projection,
	assembly_id: int,
	rigid: RigidBody3D
) -> void:
	WheelPhysicsTickCoordinator.apply_locomotive_rigid_tuning(
		projection,
		assembly_id,
		rigid
	)


static func body_mass(
	projection,
	body: PhysicsBody3D) -> float:
	if body is RigidBody3D:
		return maxf((body as RigidBody3D).mass, AssemblyBodyBuildCoordinator.MIN_MASS)
	var assembly_id: int = int(body.get_meta("assembly_id", 0))
	var assembly: SimulationAssembly = projection._world.get_assembly_raw(assembly_id)
	return maxf(
		ColliderProjectionUtil.assembly_dry_mass(projection._world, assembly),
		AssemblyBodyBuildCoordinator.MIN_MASS
	)


static func body_center_of_mass_world(
	projection,
	body: PhysicsBody3D
) -> Vector3:
	if body is RigidBody3D:
		return body.to_global((body as RigidBody3D).center_of_mass)
	return body.global_position


static func estimate_body_inertia(
	projection,
	body: PhysicsBody3D) -> Vector3:
	var records: Array[Dictionary] = []
	for child_node: Node in body.get_children():
		if child_node is CollisionShape3D:
			var collider: CollisionShape3D = child_node as CollisionShape3D
			if collider.shape is BoxShape3D:
				records.append({
					"shape": collider.shape,
					"local_transform": collider.transform,
				})
	var local_com := Vector3.ZERO
	if body is RigidBody3D:
		local_com = (body as RigidBody3D).center_of_mass
	return ColliderProjectionUtil.estimate_inertia_diagonal(
		AssemblyBodyBuildCoordinator.body_mass(projection, body),
		records,
		local_com
	)

