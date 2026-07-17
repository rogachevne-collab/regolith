class_name ImpactResolver
extends RefCounted

const I_MIN := 4.0
const I_REF := 24.0
## Closing speed below this is resting / micro-bounce, not a kinetic slam.
## Needed because Jolt contact_impulse includes gravity support (≈ m·g·Δt),
## so I_MIN alone is defeated on heavy assemblies that are merely sitting.
const V_SEP_MIN := 0.35
const K_DAMAGE := 0.35
## Landing legs absorb terrain touchdowns; keep crash lethality elsewhere.
const K_LANDING_GEAR := 0.08
const V_MAX_M3 := 2.0
## Kinetic loot threshold: below this impulse a carve yields nothing, so
## junk taps cannot be farmed (V2-4).
const I_LOOT := 12.0
## Impacts scatter regolith — collection efficiency is well below the
## drill's 1.0. Balance knob.
const KINETIC_COLLECTIBLE_FRACTION := 0.35
## Player hp lost at a reference-strength impact (I_REF); a few reference
## hits are lethal. Same quadratic curve as element damage (V2-6).
const K_PLAYER_DAMAGE := 35.0
## Personal invulnerability window so sliding contact ticks <= 4 Hz.
const PLAYER_HIT_COOLDOWN_MS := 250


static func impulse_strength(impulse_length: float) -> float:
	if impulse_length < I_MIN:
		return 0.0
	return clampf(impulse_length / I_REF, 0.0, 1.0)


## Terrain kinetic gate: velocity-derived J and closing speed must both clear
## thresholds. Resting support impulses must not carve/damage.
static func passes_terrain_kinetic_gate(
	j_fallback: float,
	separating_speed: float
) -> bool:
	return j_fallback >= I_MIN and separating_speed >= V_SEP_MIN


static func damage_amount(
	impulse_length: float,
	max_integrity: float,
	damage_scale: float = 1.0
) -> float:
	var strength := impulse_strength(impulse_length)
	if strength <= 0.0 or max_integrity <= 0.0:
		return 0.0
	var scale := maxf(damage_scale, 0.0)
	return strength * strength * max_integrity * K_DAMAGE * scale


static func is_landing_gear_archetype(archetype_id: String) -> bool:
	return archetype_id == "landing_leg"


static func terrain_damage_scale_for_archetype(archetype_id: String) -> float:
	if is_landing_gear_archetype(archetype_id):
		return K_LANDING_GEAR / K_DAMAGE
	return 1.0


static func batch_key(
	striker_element_id: int,
	partner_key: String,
	local_shape_index: int
) -> String:
	return "%d:%s:%d" % [striker_element_id, partner_key, local_shape_index]


static func partner_key_from_object(partner: Object) -> String:
	if partner == null:
		return "none"
	if TerrainCompat.is_terrain(partner):
		return "terrain"
	var assembly_id := int(partner.get_meta("assembly_id", 0))
	if assembly_id > 0:
		return "assembly_%d" % assembly_id
	return str(partner.get_instance_id())


static func is_terrain_partner(partner: Object) -> bool:
	if partner == null:
		return false
	if TerrainCompat.is_terrain(partner):
		return true
	if partner is PhysicsBody3D:
		if int((partner as PhysicsBody3D).get_meta("assembly_id", 0)) != 0:
			return false
	var node := partner as Node
	while node != null:
		if TerrainCompat.is_terrain(node):
			return true
		node = node.get_parent()
	return false


static func is_world_surface_partner(partner: Object) -> bool:
	if is_terrain_partner(partner):
		return true
	# Only anchored world geometry counts; players (CharacterBody3D) and
	# loose rigid props are ignored in v1.
	if partner is StaticBody3D:
		return int((partner as StaticBody3D).get_meta("assembly_id", 0)) == 0
	return false


## The player is a CharacterBody3D carrying a SuitState child (player.tscn).
static func player_suit_state(partner: Object) -> SuitState:
	if not partner is CharacterBody3D:
		return null
	return (partner as CharacterBody3D).get_node_or_null(
		"SuitState"
	) as SuitState


static func player_damage_amount(impulse_length: float) -> float:
	var strength := impulse_strength(impulse_length)
	return strength * strength * K_PLAYER_DAMAGE


static func is_assembly_partner(partner: Object) -> bool:
	if not partner is PhysicsBody3D:
		return false
	return int((partner as PhysicsBody3D).get_meta("assembly_id", 0)) > 0


static func element_id_from_shape_index(
	body: PhysicsBody3D,
	shape_index: int
) -> int:
	var collider := collider_from_shape_index(body, shape_index)
	if collider == null:
		return 0
	return int(collider.get_meta("element_id", 0))


static func collider_from_shape_index(
	body: PhysicsBody3D,
	shape_index: int
) -> CollisionShape3D:
	if body == null or shape_index < 0:
		return null
	# Body shape indices are assigned per shape owner, in owner order —
	# walk owners the same way CollisionObject3D.shape_find_owner does.
	var index := 0
	for owner_id: int in body.get_shape_owners():
		var owner_shape_count := body.shape_owner_get_shape_count(owner_id)
		if shape_index < index + owner_shape_count:
			return body.shape_owner_get_owner(owner_id) as CollisionShape3D
		index += owner_shape_count
	return null


static func shape_index_for_element(
	body: PhysicsBody3D,
	element_id: int
) -> int:
	if body == null or element_id <= 0:
		return -1
	var index := 0
	for owner_id: int in body.get_shape_owners():
		var owner := body.shape_owner_get_owner(owner_id)
		var owner_shape_count := body.shape_owner_get_shape_count(owner_id)
		if (
			owner is CollisionShape3D
			and int((owner as CollisionShape3D).get_meta("element_id", 0))
			== element_id
		):
			return index
		index += owner_shape_count
	return -1


## Immune only inside one body group. Different driven groups of the same
## assembly (rotor/piston base ↔ top) collide and deal kinetic damage.
static func same_assembly_subgrid(
	striker_body: PhysicsBody3D,
	partner: Object
) -> bool:
	if striker_body == null or partner == null:
		return false
	if not partner is PhysicsBody3D:
		return false
	var partner_body := partner as PhysicsBody3D
	if partner_body == striker_body:
		return true
	var striker_assembly_id := int(striker_body.get_meta("assembly_id", 0))
	var partner_assembly_id := int(partner_body.get_meta("assembly_id", 0))
	if (
		striker_assembly_id <= 0
		or partner_assembly_id != striker_assembly_id
	):
		return false
	var striker_group_id := int(striker_body.get_meta("body_group_id", 0))
	var partner_group_id := int(partner_body.get_meta("body_group_id", 0))
	return striker_group_id == partner_group_id


## Driven joint hub interface (piston_base↔head / rotor_base↔top): no kinetic
## self-damage from resting contact at the hinge. Attached frames still hit.
static func same_driven_hub_pair(
	world,
	element_a_id: int,
	element_b_id: int
) -> bool:
	if (
		world == null
		or element_a_id <= 0
		or element_b_id <= 0
		or element_a_id == element_b_id
	):
		return false
	for joint: SimulationJoint in world.list_joints():
		if joint == null or not joint.is_driven():
			continue
		if (
			(
				joint.element_a_id == element_a_id
				and joint.element_b_id == element_b_id
			)
			or (
				joint.element_a_id == element_b_id
				and joint.element_b_id == element_a_id
			)
		):
			return true
	return false


## Reduced mass of the contact pair: m1·m2/(m1+m2); terrain/static ⇒ m1.
static func effective_mass(body: RigidBody3D, partner: Object) -> float:
	if body == null:
		return 0.001
	var m1 := maxf(body.mass, 0.001)
	if partner is RigidBody3D:
		var m2 := maxf((partner as RigidBody3D).mass, 0.001)
		return m1 * m2 / (m1 + m2)
	return m1


## J = m_eff · |v_rel · n|. Pass relative_velocity explicitly when the
## bodies' current velocities are already post-solve (contact signals fire
## after the physics step, so linear_velocity is the bounced-off value).
static func fallback_impulse_length(
	body: RigidBody3D,
	partner: Object,
	contact_normal: Vector3,
	relative_velocity: Variant = null
) -> float:
	if body == null:
		return 0.0
	var normal := contact_normal
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()
	var v_rel: Vector3
	if relative_velocity is Vector3:
		v_rel = relative_velocity
	else:
		var partner_velocity := Vector3.ZERO
		if partner is RigidBody3D:
			partner_velocity = (partner as RigidBody3D).linear_velocity
		v_rel = body.linear_velocity - partner_velocity
	var v_sep := absf(v_rel.dot(normal))
	return effective_mass(body, partner) * v_sep


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
