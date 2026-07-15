class_name ImpactResolver
extends RefCounted

const I_MIN := 4.0
const I_REF := 24.0
const K_DAMAGE := 0.35
const V_MAX_M3 := 2.0


static func impulse_strength(impulse_length: float) -> float:
	if impulse_length < I_MIN:
		return 0.0
	return clampf(impulse_length / I_REF, 0.0, 1.0)


static func damage_amount(
	impulse_length: float,
	max_integrity: float
) -> float:
	var strength := impulse_strength(impulse_length)
	if strength <= 0.0 or max_integrity <= 0.0:
		return 0.0
	return strength * strength * max_integrity * K_DAMAGE


static func batch_key(
	striker_element_id: int,
	partner_key: String,
	local_shape_index: int
) -> String:
	return "%d:%s:%d" % [striker_element_id, partner_key, local_shape_index]


static func partner_key_from_object(partner: Object) -> String:
	if partner == null:
		return "none"
	if partner is VoxelTerrain:
		return "terrain"
	var assembly_id := int(partner.get_meta("assembly_id", 0))
	if assembly_id > 0:
		return "assembly_%d" % assembly_id
	return str(partner.get_instance_id())


static func is_terrain_partner(partner: Object) -> bool:
	if partner == null:
		return false
	if partner is VoxelTerrain:
		return true
	if partner is PhysicsBody3D:
		if int((partner as PhysicsBody3D).get_meta("assembly_id", 0)) != 0:
			return false
	var node := partner as Node
	while node != null:
		if node is VoxelTerrain:
			return true
		node = node.get_parent()
	return false


static func is_world_surface_partner(partner: Object) -> bool:
	if is_terrain_partner(partner):
		return true
	if partner is PhysicsBody3D:
		return int((partner as PhysicsBody3D).get_meta("assembly_id", 0)) == 0
	return partner is StaticBody3D


static func element_id_from_shape_index(
	body: PhysicsBody3D,
	shape_index: int
) -> int:
	if body == null or shape_index < 0:
		return 0
	var index := 0
	for child: Node in body.get_children():
		if child is CollisionShape3D:
			if index == shape_index:
				return int((child as CollisionShape3D).get_meta("element_id", 0))
			index += 1
	return 0


static func collider_from_shape_index(
	body: PhysicsBody3D,
	shape_index: int
) -> CollisionShape3D:
	if body == null or shape_index < 0:
		return null
	var index := 0
	for child: Node in body.get_children():
		if child is CollisionShape3D:
			if index == shape_index:
				return child as CollisionShape3D
			index += 1
	return null


static func same_assembly_subgrid(
	striker_assembly_id: int,
	partner: Object
) -> bool:
	if striker_assembly_id <= 0 or partner == null:
		return false
	if partner is PhysicsBody3D:
		var partner_assembly_id := int(
			(partner as PhysicsBody3D).get_meta("assembly_id", 0)
		)
		return partner_assembly_id > 0 and partner_assembly_id == striker_assembly_id
	return false


static func fallback_impulse_length(
	body: RigidBody3D,
	partner: Object,
	contact_normal: Vector3
) -> float:
	if body == null:
		return 0.0
	var normal := contact_normal
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()
	var partner_velocity := Vector3.ZERO
	if partner is RigidBody3D:
		partner_velocity = (partner as RigidBody3D).linear_velocity
	var v_rel := body.linear_velocity - partner_velocity
	var v_sep := absf(v_rel.dot(normal))
	return maxf(body.mass, 0.001) * v_sep


static func assembly_has_construction_elements(
	world: SimulationWorld,
	assembly_id: int
) -> bool:
	if world == null or assembly_id <= 0:
		return false
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return false
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if (
			element != null
			and TerrainAnchorProbe.is_construction_archetype(
				element.archetype_id
			)
		):
			return true
	return false
