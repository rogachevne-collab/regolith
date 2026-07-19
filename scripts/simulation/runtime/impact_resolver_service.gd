class_name ImpactResolverService
extends Node

enum ImpactBodyMode {
	FULL,
	MONITOR_ONLY,
}

const COOLDOWN_MS := 80
## A sustained grind chains into a path stamp only while consecutive
## contacts stay this close (in voxels) and this recent.
const SUSTAINED_PATH_MIN_VOXELS := 0.5
const SUSTAINED_PATH_MAX_VOXELS := 4.0
const SUSTAINED_PATH_TIMEOUT_MS := 500

var _world: SimulationWorld
var _gateway: WorldCommandGateway
var _frame_batch: Dictionary = {}
var _flush_scheduled := false
var _cooldown_until: Dictionary = {}
var _tracked_bodies: Dictionary = {}
var _pre_step_velocity: Dictionary = {}
var _last_sustained_contact: Dictionary = {}
var _player_hit_until: Dictionary = {}
var _material_source := TerrainMaterialSource.new()
var last_terrain_carve_m3: float = 0.0
var _last_vfx_spawn_msec := 0

var _sfx_terrain: AudioStream = null
var _sfx_structure: AudioStream = null


func bind(
	world: SimulationWorld,
	gateway: WorldCommandGateway
) -> void:
	_world = world
	_gateway = gateway
	# Lazy-load audiovisual resources: generate procedurally if files missing.
	if _sfx_terrain == null:
		_sfx_terrain = _generate_impact_sfx(false)
	if _sfx_structure == null:
		_sfx_structure = _generate_impact_sfx(true)


func unregister_tracked_body(body: RigidBody3D) -> void:
	if body == null:
		return
	var body_id := body.get_instance_id()
	_tracked_bodies.erase(body_id)
	_pre_step_velocity.erase(body_id)


func unbind() -> void:
	_world = null
	_gateway = null
	_frame_batch.clear()
	_cooldown_until.clear()
	_tracked_bodies.clear()
	_pre_step_velocity.clear()
	_last_sustained_contact.clear()
	_player_hit_until.clear()
	_flush_scheduled = false


## Contact signals fire after the physics step, when the collision has
## already been resolved and linear_velocity is post-impact. Cache each
## monitored body's velocity before the step so J_fallback sees the
## incoming velocity (known Godot contact-signal pitfall).
func _physics_process(_delta: float) -> void:
	var stale: Array = []
	for body_id: Variant in _tracked_bodies.keys():
		var body_variant: Variant = _tracked_bodies.get(body_id)
		if (
			body_variant == null
			or not body_variant is RigidBody3D
			or not is_instance_valid(body_variant)
		):
			stale.append(body_id)
			continue
		var body := body_variant as RigidBody3D
		if not body.is_inside_tree():
			stale.append(body_id)
			continue
		_pre_step_velocity[int(body_id)] = body.linear_velocity
	for body_id: Variant in stale:
		_tracked_bodies.erase(body_id)
		_pre_step_velocity.erase(body_id)


func pre_step_velocity(body: RigidBody3D) -> Vector3:
	if body == null:
		return Vector3.ZERO
	return _pre_step_velocity.get(body.get_instance_id(), body.linear_velocity)


func configure_rigid_body(body: RigidBody3D) -> void:
	configure_impact_body(body, ImpactBodyMode.FULL)


func configure_impact_body(
	body: RigidBody3D,
	mode: ImpactBodyMode = ImpactBodyMode.FULL
) -> void:
	if body == null or body.has_meta("impact_monitoring"):
		return
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.continuous_cd = true
	# Never enable custom_integrator: the Jolt module silently drops
	# apply_force/apply_central_force/apply_torque and skips gravity and
	# damping for such bodies (jolt_body_3d.cpp), which breaks piston and
	# wheel forces. Contact impulses are step-time estimates delivered to
	# _integrate_forces regardless of this flag.
	body.custom_integrator = false
	body.set_meta("impact_monitoring", true)
	body.set_meta("impact_body_mode", mode)
	_tracked_bodies[body.get_instance_id()] = body
	body.body_shape_entered.connect(
		func(
			body_rid: RID,
			other_body: Node,
			other_shape_index: int,
			local_shape_index: int
		) -> void:
			if not is_instance_valid(body):
				return
			_on_body_shape_entered(
				body,
				body_rid,
				other_body,
				other_shape_index,
				local_shape_index
			)
	)


func emit_actuator_sustained_entry(
	striker_element_id: int,
	striker_body: RigidBody3D,
	partner: Object,
	force_n: float,
	delta: float,
	local_shape_index: int = 0,
	contact_world: Vector3 = Vector3.ZERO
) -> void:
	if (
		_world == null
		or striker_element_id <= 0
		or striker_body == null
		or force_n <= 0.0
		or delta <= 0.0
	):
		return
	if partner == null:
		partner = _terrain_partner()
	if partner == null:
		return
	var impulse_length := force_n * delta
	if impulse_length < ImpactResolver.I_MIN:
		return
	if ImpactResolver.same_assembly_subgrid(striker_body, partner):
		return
	var partner_key := ImpactResolver.partner_key_from_object(partner)
	var batch_key := ImpactResolver.batch_key(
		striker_element_id,
		partner_key,
		local_shape_index
	)
	if not _cooldown_ready(batch_key):
		return
	if contact_world == Vector3.ZERO:
		contact_world = _contact_point_on_body(striker_body, local_shape_index)
	var entry := {
		"batch_key": batch_key,
		"striker_element_id": striker_element_id,
		"striker_body": striker_body,
		"local_shape_index": local_shape_index,
		"partner": partner,
		"impulse_length": impulse_length,
		"contact_world": contact_world,
		"contact_points": PackedVector3Array([contact_world]),
		"contact_impulses": PackedFloat32Array([impulse_length]),
	}
	var path_from: Variant = _sustained_path_from(batch_key, contact_world)
	if path_from is Vector3:
		entry["sustained_path_from"] = path_from
	_queue_entry(entry)


## While the carriage crawls under load, chain consecutive contact points
## into one trench segment instead of stamping isolated pits.
func _sustained_path_from(batch_key: String, contact_world: Vector3) -> Variant:
	var now := Time.get_ticks_msec()
	var previous: Dictionary = _last_sustained_contact.get(batch_key, {})
	_last_sustained_contact[batch_key] = {
		"point": contact_world,
		"msec": now,
	}
	if previous.is_empty():
		return null
	if now - int(previous.get("msec", 0)) > SUSTAINED_PATH_TIMEOUT_MS:
		return null
	var voxel := VoxelSpaceUtil.voxel_size_m(_terrain_partner() as Node3D)
	var distance := Vector3(previous.get("point", Vector3.ZERO)).distance_to(
		contact_world
	)
	if (
		distance < voxel * SUSTAINED_PATH_MIN_VOXELS
		or distance > voxel * SUSTAINED_PATH_MAX_VOXELS
	):
		return null
	return Vector3(previous.get("point", Vector3.ZERO))


func _on_body_shape_entered(
	body: RigidBody3D,
	_body_rid: RID,
	other_body: Node,
	_other_shape_index: int,
	local_shape_index: int
) -> void:
	if body == null or not is_instance_valid(body) or body.freeze or other_body == null:
		return
	var is_world_surface := ImpactResolver.is_world_surface_partner(other_body)
	var hits_player := ImpactResolver.is_player_partner(other_body)
	if (
		not is_world_surface
		and not ImpactResolver.is_assembly_partner(other_body)
		and not hits_player
	):
		return
	var assembly_id := int(body.get_meta("assembly_id", 0))
	if assembly_id <= 0:
		return
	if ImpactResolver.same_assembly_subgrid(body, other_body):
		return
	# ROVER-MODULES-V1: locomotive ↔ terrain carve/damage off (wheels only).
	if _locomotive_ignores_terrain_partner(assembly_id, other_body):
		return
	if not ImpactResolver.assembly_has_construction_elements(_world, assembly_id):
		return
	var striker_element_id := ImpactResolver.element_id_from_shape_index(
		body,
		local_shape_index
	)
	if striker_element_id <= 0:
		return
	var partner_element_id := 0
	if other_body is PhysicsBody3D:
		partner_element_id = ImpactResolver.element_id_from_shape_index(
			other_body as PhysicsBody3D,
			_other_shape_index
		)
	if ImpactResolver.same_driven_hub_pair(
		_world,
		striker_element_id,
		partner_element_id
	):
		return
	var inbound_velocity := pre_step_velocity(body)
	var contact_world := _contact_point_on_body(
		body,
		local_shape_index,
		inbound_velocity
	)
	var contact_normal := _contact_normal_toward_partner(
		body,
		contact_world,
		other_body,
		inbound_velocity
	)
	var partner_velocity := Vector3.ZERO
	if other_body is RigidBody3D:
		partner_velocity = pre_step_velocity(other_body as RigidBody3D)
	elif other_body is CharacterBody3D:
		partner_velocity = (other_body as CharacterBody3D).velocity
	var relative_velocity := inbound_velocity - partner_velocity
	var impulse_length := ImpactResolver.fallback_impulse_length(
		body,
		other_body,
		contact_normal,
		relative_velocity
	)
	if impulse_length < ImpactResolver.I_MIN:
		return
	var v_sep := absf(relative_velocity.dot(contact_normal))
	# Same resting-contact gate as integrate_contacts: every carve rebuilds the
	# terrain collider, which re-fires body_shape_entered on the new shape while
	# the body merely sits — heavy mass alone must not re-trigger a carve.
	if is_world_surface and not ImpactResolver.passes_terrain_kinetic_gate(
		impulse_length,
		v_sep
	):
		return
	var partner_key := ImpactResolver.partner_key_from_object(other_body)
	var batch_key := ImpactResolver.batch_key(
		striker_element_id,
		partner_key,
		local_shape_index
	)
	if not _cooldown_ready(batch_key):
		return
	_queue_entry({
		"batch_key": batch_key,
		"striker_element_id": striker_element_id,
		"striker_body": body,
		"local_shape_index": local_shape_index,
		"partner": other_body,
		"partner_element_id": partner_element_id,
		"impulse_length": impulse_length,
		"carve_blocked": not ImpactResolver.passes_terrain_carve_gate(v_sep),
		"contact_world": contact_world,
		"contact_normal": contact_normal,
		"inbound_velocity": inbound_velocity,
		"contact_points": PackedVector3Array([contact_world]),
		"contact_impulses": PackedFloat32Array([impulse_length]),
	})


func integrate_contacts(
	body: RigidBody3D,
	state: PhysicsDirectBodyState3D
) -> void:
	if _world == null or body == null or body.freeze:
		return
	var assembly_id := int(body.get_meta("assembly_id", 0))
	if assembly_id <= 0:
		return
	var has_construction := ImpactResolver.assembly_has_construction_elements(
		_world, assembly_id
	)
	if not has_construction:
		return
	for contact_index: int in range(state.get_contact_count()):
		var impulse: Vector3 = state.get_contact_impulse(contact_index)
		var impulse_length := impulse.length()
		var local_shape_index := state.get_contact_local_shape(contact_index)
		var striker_element_id := ImpactResolver.element_id_from_shape_index(
			body,
			local_shape_index
		)
		if striker_element_id <= 0:
			continue
		var partner: Object = state.get_contact_collider_object(contact_index)
		if partner == null:
			var partner_id := state.get_contact_collider_id(contact_index)
			if partner_id != 0:
				partner = instance_from_id(partner_id)
		# Like get_contact_local_position, get_contact_local_normal is
		# already world space in Godot/Jolt ("local" = this body's side);
		# rotating it by the body basis skews normals of tilted bodies.
		var world_normal := state.get_contact_local_normal(
			contact_index
		).normalized()
		if partner == null and absf(world_normal.y) >= 0.35:
			partner = _terrain_partner()
		if partner == null:
			continue
		if (
			not ImpactResolver.is_world_surface_partner(partner)
			and not ImpactResolver.is_assembly_partner(partner)
			and not ImpactResolver.is_player_partner(partner)
		):
			continue
		if ImpactResolver.same_assembly_subgrid(body, partner):
			continue
		# ROVER-MODULES-V1: locomotive ↔ terrain carve/damage off (wheels only).
		if _locomotive_ignores_terrain_partner(assembly_id, partner):
			continue
		var partner_element_id := 0
		if partner is PhysicsBody3D:
			partner_element_id = ImpactResolver.element_id_from_shape_index(
				partner as PhysicsBody3D,
				state.get_contact_collider_shape(contact_index)
			)
		if ImpactResolver.same_driven_hub_pair(
			_world,
			striker_element_id,
			partner_element_id
		):
			continue
		var partner_key := ImpactResolver.partner_key_from_object(partner)
		var batch_key := ImpactResolver.batch_key(
			striker_element_id,
			partner_key,
			local_shape_index
		)
		if not _cooldown_ready(batch_key):
			continue
		# Godot 4.x/Jolt: get_contact_local_position is already world space
		# (misleading name). body.to_global() double-transforms and shifts carve.
		var contact_world := state.get_contact_local_position(contact_index)
		# Contact velocities are captured pre-solve by the Jolt contact
		# listener; body.linear_velocity here is already post-impact.
		var contact_relative_velocity := (
			state.get_contact_local_velocity_at_position(contact_index)
			- state.get_contact_collider_velocity_at_position(contact_index)
		)
		var inbound_velocity := pre_step_velocity(body)
		var j_fallback := ImpactResolver.fallback_impulse_length(
			body,
			partner,
			world_normal,
			contact_relative_velocity
		)
		var effective_impulse := maxf(impulse_length, j_fallback)
		if effective_impulse < ImpactResolver.I_MIN:
			continue
		# Terrain: ignore resting gravity-support impulses. Jolt reports
		# contact_impulse ≈ m·g·Δt every step while sat; that used to pass
		# I_MIN on heavy flight/assembly bodies and dig endless shafts.
		var v_sep := 0.0
		if world_normal.length_squared() > 0.000001:
			v_sep = absf(contact_relative_velocity.dot(world_normal))
		if ImpactResolver.is_world_surface_partner(partner):
			if not ImpactResolver.passes_terrain_kinetic_gate(j_fallback, v_sep):
				continue
		_queue_entry({
			"batch_key": batch_key,
			"striker_element_id": striker_element_id,
			"striker_body": body,
			"local_shape_index": local_shape_index,
			"partner": partner,
			"partner_element_id": partner_element_id,
			"impulse_length": effective_impulse,
			"carve_blocked": not ImpactResolver.passes_terrain_carve_gate(
				v_sep
			),
			"contact_world": contact_world,
			"contact_normal": world_normal,
			"inbound_velocity": inbound_velocity,
			"contact_from_physics": true,
			"contact_points": PackedVector3Array(),
			"contact_impulses": PackedFloat32Array(),
		})


## Entries from different J sources (contact estimate, fallback, sustained)
## may target the same pair in one frame — spec combines them by max impulse,
## but contact position from Jolt/manifold wins over SDF guesses (scale 0.65).
func _queue_entry(entry: Dictionary) -> void:
	var batch_key := str(entry.get("batch_key", ""))
	if batch_key.is_empty():
		return
	var existing: Dictionary = _frame_batch.get(batch_key, {})
	if existing.is_empty():
		_frame_batch[batch_key] = entry.duplicate(true)
	else:
		var merged := existing.duplicate(true)
		var new_impulse := float(entry.get("impulse_length", 0.0))
		var old_impulse := float(merged.get("impulse_length", 0.0))
		merged["impulse_length"] = maxf(old_impulse, new_impulse)
		# Carve stays allowed if any contributing source allowed it.
		merged["carve_blocked"] = (
			bool(merged.get("carve_blocked", false))
			and bool(entry.get("carve_blocked", false))
		)
		var entry_physics := bool(entry.get("contact_from_physics", false))
		var merged_physics := bool(merged.get("contact_from_physics", false))
		if entry_physics:
			merged["contact_world"] = entry["contact_world"]
			merged["contact_normal"] = entry.get(
				"contact_normal",
				merged.get("contact_normal", Vector3.UP)
			)
			merged["inbound_velocity"] = entry.get(
				"inbound_velocity",
				merged.get("inbound_velocity", Vector3.ZERO)
			)
			merged["contact_from_physics"] = true
		elif not merged_physics and new_impulse >= old_impulse:
			merged["contact_world"] = entry.get(
				"contact_world",
				merged.get("contact_world", Vector3.ZERO)
			)
			merged["contact_normal"] = entry.get(
				"contact_normal",
				merged.get("contact_normal", Vector3.UP)
			)
			merged["inbound_velocity"] = entry.get(
				"inbound_velocity",
				merged.get("inbound_velocity", Vector3.ZERO)
			)
		_frame_batch[batch_key] = merged
	if not _flush_scheduled:
		_flush_scheduled = true
		call_deferred("_flush_batch")


func apply_entry_for_test(entry: Dictionary) -> float:
	return _apply_entry(entry)


## Headless helpers: skip the real-time pair cooldown so a second sustained
## bite can land in the same frame without letting physics destroy the
## striker into the crater carved by the first bite.
func clear_pair_cooldowns_for_test() -> void:
	_cooldown_until.clear()


func emit_actuator_sustained_entry_for_test(
	striker_element_id: int,
	striker_body: RigidBody3D,
	partner: Object,
	force_n: float,
	delta: float,
	local_shape_index: int = 0,
	contact_world: Vector3 = Vector3.ZERO
) -> float:
	emit_actuator_sustained_entry(
		striker_element_id,
		striker_body,
		partner,
		force_n,
		delta,
		local_shape_index,
		contact_world
	)
	if _frame_batch.is_empty():
		return 0.0
	var batch: Dictionary = _frame_batch.duplicate(true)
	_frame_batch.clear()
	_flush_scheduled = false
	var volume_budget := ImpactResolver.V_MAX_M3
	var used := 0.0
	for key: Variant in batch.keys():
		used += _apply_entry(batch[key], volume_budget - used)
	return used


func _flush_batch() -> void:
	_flush_scheduled = false
	if _frame_batch.is_empty():
		return
	var batch: Dictionary = _frame_batch.duplicate(true)
	_frame_batch.clear()
	var sorted_keys: Array = batch.keys()
	sorted_keys.sort()
	var volume_budget := ImpactResolver.V_MAX_M3
	for key: Variant in sorted_keys:
		var entry: Dictionary = batch[key]
		# Exhausted carve budget only stops terrain edits; element damage
		# from remaining entries must still land.
		volume_budget = maxf(
			volume_budget - _apply_entry(entry, volume_budget),
			0.0
		)


func _apply_entry(
	entry: Dictionary,
	volume_budget_m3: float = ImpactResolver.V_MAX_M3
) -> float:
	if _world == null:
		return 0.0
	var striker_element_id := int(entry.get("striker_element_id", 0))
	if striker_element_id <= 0:
		return 0.0
	var striker_body: PhysicsBody3D = entry.get("striker_body")
	var striker_assembly_id := 0
	if striker_body != null:
		striker_assembly_id = int(striker_body.get_meta("assembly_id", 0))
	var partner: Object = entry.get("partner")
	if ImpactResolver.same_assembly_subgrid(striker_body, partner):
		return 0.0
	var partner_element_id := int(entry.get("partner_element_id", 0))
	if ImpactResolver.same_driven_hub_pair(
		_world,
		striker_element_id,
		partner_element_id
	):
		return 0.0
	# ROVER-MODULES-V1: locomotive ↔ terrain carve/damage off (wheels only).
	if _locomotive_ignores_terrain_partner(striker_assembly_id, partner):
		return 0.0
	var impulse_length := float(entry.get("impulse_length", 0.0))
	if not is_finite(impulse_length):
		return 0.0
	var strength := ImpactResolver.impulse_strength(impulse_length)
	if strength <= 0.0:
		return 0.0
	var batch_key := str(entry.get("batch_key", ""))
	if not batch_key.is_empty():
		_cooldown_until[batch_key] = Time.get_ticks_msec() + COOLDOWN_MS
	if ImpactResolver.is_player_partner(partner):
		# V2-6: the player absorbs the hit; no carve and no self-damage to
		# the striker from squashing something soft.
		_apply_player_hit(partner, impulse_length)
		return 0.0
	var used_volume := 0.0
	var world_surface := ImpactResolver.is_world_surface_partner(partner)
	# Sub-V_CARVE_MIN touchdowns damage elements but never dig: the smallest
	# crater is deep enough that falling back into it re-arms the kinetic
	# gate, so carving on touchdown chains a self-digging shaft.
	var carve_blocked := bool(entry.get("carve_blocked", false))
	if volume_budget_m3 > 0.0 and world_surface and not carve_blocked:
		used_volume = _apply_terrain_carve(entry, strength, volume_budget_m3)
		if used_volume > 0.0 and ImpactResolver.is_terrain_partner(partner):
			_drop_kinetic_loot(entry, impulse_length, used_volume)
	_apply_element_damage(striker_element_id, impulse_length, world_surface)
	var is_assembly := ImpactResolver.is_assembly_partner(partner)
	_spawn_impact_feedback(entry, strength, world_surface or is_assembly)
	return used_volume


func _locomotive_ignores_terrain_partner(
	assembly_id: int,
	partner: Object
) -> bool:
	if _world == null or assembly_id <= 0 or partner == null:
		return false
	if not ImpactResolver.is_world_surface_partner(partner):
		return false
	return WheelSimulationService.is_locomotive_assembly(_world, assembly_id)


## V2-4: strong-enough impacts leave part of the carved regolith as a
## world loot pile at the crater; weak taps carve but yield nothing.
func _drop_kinetic_loot(
	entry: Dictionary,
	impulse_length: float,
	carved_m3: float
) -> void:
	if _world == null or impulse_length < ImpactResolver.I_LOOT:
		return
	var yields := _material_source.yield_for_removed_volume(
		carved_m3,
		ImpactResolver.KINETIC_COLLECTIBLE_FRACTION
	)
	var contact_world := Vector3(entry.get("contact_world", Vector3.ZERO))
	for yield_entry: Dictionary in yields:
		_world.add_world_loot_pile(
			contact_world,
			String(yield_entry.get("resource_id", "")),
			float(yield_entry.get("mass_kg", 0.0))
		)


func _apply_terrain_carve(
	entry: Dictionary,
	strength: float,
	volume_budget_m3: float
) -> float:
	if _gateway == null:
		return 0.0
	var terrain: Node3D = _gateway.get_node_or_null(_gateway.terrain_path)
	var body: PhysicsBody3D = entry.get("striker_body")
	var collider := ImpactResolver.collider_from_shape_index(
		body,
		int(entry.get("local_shape_index", 0))
	)
	var carve_direction := _terrain_carve_direction(entry)
	if carve_direction.length_squared() <= 0.000001:
		return 0.0
	var raw_contact := Vector3(entry.get("contact_world", Vector3.ZERO))
	var contact_world := raw_contact
	if not bool(entry.get("contact_from_physics", false)):
		contact_world = _snap_contact_to_terrain_surface(
			raw_contact,
			terrain,
			body
		)
	var op: Dictionary = {}
	var path_from: Variant = entry.get("sustained_path_from")
	if path_from is Vector3:
		# Sustained grind: trench segment between consecutive contacts.
		var segment_radius := float(TerrainImpactCarver.build_sphere_op(
			contact_world,
			collider,
			strength,
			terrain,
			carve_direction,
			TerrainImpactCarver.IMPACT_MAX_RADIUS
		).get("radius", 0.0))
		op = TerrainImpactCarver.build_path_op(
			PackedVector3Array([path_from, contact_world]),
			PackedFloat32Array([segment_radius, segment_radius]),
			strength,
			terrain,
			carve_direction
		)
	if op.is_empty():
		# Oriented bite: box colliders stamp with their world rotation, so
		# a cube landing at an angle digs a slanted imprint instead of a
		# vertical square pit. Sphere stays the fallback for non-box shapes.
		op = TerrainImpactCarver.build_mesh_op(
			contact_world,
			collider,
			strength,
			carve_direction,
			terrain,
			TerrainImpactCarver.IMPACT_MAX_RADIUS
		)
	if op.is_empty():
		op = TerrainImpactCarver.build_sphere_op(
			contact_world,
			collider,
			strength,
			terrain,
			carve_direction,
			TerrainImpactCarver.IMPACT_MAX_RADIUS
		)
	op["sdf_scale"] = clampf(0.25 + 0.75 * strength, 0.25, 1.0)
	var carved := _gateway.apply_terrain_carve(op, volume_budget_m3)
	last_terrain_carve_m3 = carved
	return carved


func _terrain_carve_direction(entry: Dictionary) -> Vector3:
	var inbound: Vector3 = entry.get("inbound_velocity", Vector3.ZERO)
	var normal: Vector3 = entry.get("contact_normal", Vector3.ZERO)
	if normal.length_squared() > 0.000001:
		normal = normal.normalized()
		# Jolt normal sign depends on manifold ordering — orient the dig
		# into the surface: along the inbound motion when we have it,
		# otherwise downward.
		if inbound.length_squared() > 0.01:
			return -normal if normal.dot(inbound) < 0.0 else normal
		return -normal if normal.y > 0.0 else normal
	if inbound.length_squared() > 0.25:
		return inbound.normalized()
	return Vector3.DOWN


func _snap_contact_to_terrain_surface(
	contact_world: Vector3,
	terrain: Node3D,
	striker_body: PhysicsBody3D = null
) -> Vector3:
	return _probe_terrain_surface_world(
		contact_world + Vector3.UP * 1.25,
		Vector3.DOWN,
		terrain,
		striker_body,
		4.0
	)


func _probe_terrain_surface_world(
	probe_origin: Vector3,
	ray_direction: Vector3,
	terrain: Node3D,
	striker_body: PhysicsBody3D = null,
	max_distance: float = 4.0
) -> Vector3:
	if terrain == null or ray_direction.length_squared() <= 0.000001:
		return probe_origin
	var nudged_origin := _nudge_integer_ray_origin(probe_origin)
	var voxel_terrain: Node3D = terrain if TerrainCompat.is_terrain(terrain) else null
	var space_state: PhysicsDirectSpaceState3D = null
	if striker_body != null:
		space_state = striker_body.get_world_3d().direct_space_state
	elif terrain.is_inside_tree():
		space_state = terrain.get_world_3d().direct_space_state
	if space_state != null and voxel_terrain != null:
		var exclude: Array[RID] = []
		if striker_body != null:
			exclude.append(striker_body.get_rid())
		var physics_hit := TerrainAnchorProbe.raycast_terrain(
			space_state,
			voxel_terrain,
			nudged_origin,
			ray_direction,
			max_distance,
			1,
			exclude
		)
		if not physics_hit.is_empty():
			return physics_hit["position"] as Vector3
	if _gateway == null:
		return probe_origin
	var tool: VoxelTool = _gateway.get_voxel_tool()
	if tool == null:
		return probe_origin
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		terrain,
		nudged_origin,
		ray_direction,
		max_distance
	)
	if hit == null:
		return probe_origin
	return VoxelSpaceUtil.raycast_hit_world_point(
		terrain,
		nudged_origin,
		ray_direction,
		hit
	)


func _nudge_integer_ray_origin(origin: Vector3) -> Vector3:
	if (
		absf(origin.x - roundf(origin.x)) < 0.001
		and absf(origin.z - roundf(origin.z)) < 0.001
	):
		return origin + Vector3(0.05, 0.0, 0.05)
	return origin


func _apply_player_hit(
	partner: Object,
	impulse_length: float
) -> void:
	# Cooldown is keyed by body instance, the suit by player id: two players
	# sharing one suit id must still be rate-limited independently.
	var body_key := partner.get_instance_id()
	var now := Time.get_ticks_msec()
	if now < int(_player_hit_until.get(body_key, 0)):
		return
	var amount := ImpactResolver.player_damage_amount(impulse_length)
	if amount <= 0.0 or _world == null:
		return
	_player_hit_until[body_key] = now + ImpactResolver.PLAYER_HIT_COOLDOWN_MS
	_world.apply_suit_damage(
		ImpactResolver.player_id_of(partner),
		amount,
		&"kinetic_impact"
	)


func _apply_element_damage(
	element_id: int,
	impulse_length: float,
	terrain_contact: bool = false
) -> void:
	var element := _world.get_element(element_id)
	if element == null:
		return
	var archetype := element.get_archetype()
	if archetype == null:
		return
	var scale := 1.0
	if terrain_contact:
		scale = ImpactResolver.terrain_damage_scale_for_archetype(
			element.archetype_id
		)
	var amount := ImpactResolver.damage_amount(
		impulse_length,
		archetype.max_integrity,
		scale
	)
	if amount <= 0.0:
		return
	var command := DamageElementCommand.new()
	command.element_id = element_id
	command.expected_state_revision = element.state_revision
	command.damage = amount
	_world.apply_structural_command_now(command)


func _cooldown_ready(batch_key: String) -> bool:
	return Time.get_ticks_msec() >= int(_cooldown_until.get(batch_key, 0))


func _terrain_partner() -> Object:
	if _gateway == null:
		return null
	return _gateway.get_node_or_null(_gateway.terrain_path)


func _contact_normal_toward_partner(
	body: RigidBody3D,
	contact_world: Vector3,
	partner: Object,
	inbound_velocity: Vector3 = Vector3.ZERO
) -> Vector3:
	if body == null:
		return Vector3.UP
	if ImpactResolver.is_world_surface_partner(partner):
		return _world_surface_normal(body, contact_world, inbound_velocity)
	# Assembly partner: approximate with the direction between mass centers.
	var partner_point := contact_world
	if partner is Node3D:
		partner_point = (partner as Node3D).global_position
	var toward_partner := partner_point - body.global_position
	if toward_partner.length_squared() > 0.000001:
		return toward_partner.normalized()
	if inbound_velocity.length_squared() > 0.01:
		return inbound_velocity.normalized()
	return Vector3.UP


## Physics raycast along the motion direction to recover the actual surface
## normal; the terrain node's origin says nothing about the contact plane.
func _world_surface_normal(
	body: RigidBody3D,
	contact_world: Vector3,
	inbound_velocity: Vector3
) -> Vector3:
	var ray_dir := Vector3.DOWN
	if inbound_velocity.length_squared() > 0.01:
		ray_dir = inbound_velocity.normalized()
	var space_state := body.get_world_3d().direct_space_state
	if space_state != null:
		var query := PhysicsRayQueryParameters3D.create(
			contact_world - ray_dir * 0.5,
			contact_world + ray_dir * 0.5
		)
		query.exclude = [body.get_rid()]
		query.collide_with_areas = false
		var hit: Dictionary = space_state.intersect_ray(query)
		if not hit.is_empty():
			return Vector3(hit["normal"]).normalized()
	return Vector3.UP


## Spawn audiovisual feedback for an impact: VFX burst + SFX.
## Particles are built from scratch — no pre-made meteor scene.
func _spawn_impact_feedback(
	entry: Dictionary,
	strength: float,
	is_structural: bool
) -> void:
	# Global VFX cooldown: at most 4 spawns per second.
	var now := Time.get_ticks_msec()
	if now - _last_vfx_spawn_msec < 250:
		return
	_last_vfx_spawn_msec = now
	var contact_world := Vector3(entry.get("contact_world", Vector3.ZERO))
	var parent_node := _feedback_parent()
	if parent_node == null:
		return
	var s := clampf(strength, 0.0, 1.0)
	# Build a small burst node anchored to the terrain.
	var burst := Node3D.new()
	parent_node.add_child(burst)
	burst.global_position = contact_world
	# Flash — brief orange/white spark, small sphere.
	var flash := _make_particles(15, 0.28, Color(1.0, 0.82, 0.55, 0.9))
	flash.one_shot = true
	flash.explosiveness = 1.0
	var flash_mat := flash.process_material as ParticleProcessMaterial
	flash_mat.spread = 180.0
	flash_mat.emission_sphere_radius = 0.2 + 0.3 * s
	flash_mat.initial_velocity_min = 1.5 + 3.0 * s
	flash_mat.initial_velocity_max = 4.0 + 6.0 * s
	flash_mat.scale_min = 0.15 + 0.15 * s
	flash_mat.scale_max = 0.3 + 0.25 * s
	if is_structural:
		flash_mat.color = Color(0.85, 0.9, 1.0, 0.9)
	burst.add_child(flash)
	# Dust — grey regolith cloud, drifts slowly upward under lunar g.
	var dust := _make_particles(35, 1.8, Color(0.55, 0.52, 0.48, 0.7))
	dust.one_shot = true
	dust.explosiveness = 0.92
	var dust_mat := dust.process_material as ParticleProcessMaterial
	dust_mat.spread = 165.0
	dust_mat.emission_sphere_radius = 0.3 + 0.4 * s
	dust_mat.initial_velocity_min = 1.0 + 2.0 * s
	dust_mat.initial_velocity_max = 3.5 + 5.0 * s
	dust_mat.scale_min = 0.2 + 0.2 * s
	dust_mat.scale_max = 0.4 + 0.3 * s
	dust_mat.gravity = Vector3(0.0, -1.62, 0.0)
	burst.add_child(dust)
	# Lifecycle: remove after dust fades.
	var duration := 2.5
	get_tree().create_timer(duration).timeout.connect(
		burst.queue_free,
		CONNECT_DEFERRED
	)
	flash.restart(); flash.emitting = true
	dust.restart(); dust.emitting = true
	# SFX on Master bus.
	var stream: AudioStream = _sfx_terrain
	var pitch_min := 0.8
	var pitch_max := 1.0
	if is_structural:
		stream = _sfx_structure
		pitch_min = 1.1
		pitch_max = 1.4
	if stream != null:
		var player := AudioStreamPlayer3D.new()
		player.stream = stream
		player.pitch_scale = randf_range(pitch_min, pitch_max)
		player.volume_db = linear_to_db(clampf(s * 1.2, 0.0, 1.0))
		player.max_distance = 40.0
		parent_node.add_child(player)
		player.global_position = contact_world
		player.play()
		var finish_duration := stream.get_length()
		get_tree().create_timer(finish_duration + 0.1).timeout.connect(
			player.queue_free,
			CONNECT_DEFERRED
		)


## Build a minimal GPUParticles3D with a quad mesh and the given
## material tint. Caller must set one_shot, explosiveness, and emission
## params on the returned node's process_material.
static func _make_particles(
	amount: int,
	lifetime: float,
	tint: Color
) -> GPUParticles3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.5, 0.5)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = tint
	mesh.material = mat
	var proc_mat := ParticleProcessMaterial.new()
	proc_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	proc_mat.direction = Vector3.UP
	var particles := GPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.process_material = proc_mat
	particles.draw_pass_1 = mesh
	return particles


## Procedurally generate a short impact SFX — white noise burst with an
## exponential decay envelope. `structural = true` shifts the noise toward
## higher frequencies (clang), `false` keeps it low (thud).
static func _generate_impact_sfx(structural: bool) -> AudioStreamWAV:
	var sample_rate := 22050
	var duration_sec := 0.35
	var num_samples := int(sample_rate * duration_sec)
	var data := PackedByteArray()
	data.resize(num_samples * 2)  # 16-bit mono
	var envelope_scale := 1.0 / float(num_samples)
	var freq_boost := 0.6 if structural else 0.15  # high-pass blend
	for i: int in range(num_samples):
		var t := float(i) * envelope_scale
		# Envelope: fast attack, exponential decay.
		var envelope: float = exp(-t * 5.0)
		# White noise.
		var noise := randf_range(-1.0, 1.0)
		# Simple high-pass: mix with previous sample difference.
		var prev := 0.0 if i == 0 else float(data[(i - 1) * 2 + 1] - 128) / 128.0
		var hp := noise - prev
		var sample := lerpf(noise, hp, freq_boost) * envelope
		sample = clampf(sample, -1.0, 1.0)
		var s16 := int(sample * 32767.0)
		s16 = clampi(s16, -32768, 32767)
		var le := s16 & 0xFF
		var be := (s16 >> 8) & 0xFF
		data[i * 2] = le
		data[i * 2 + 1] = be
	var wav := AudioStreamWAV.new()
	wav.data = data
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return wav


## World-anchored node for VFX/SFX so they don't follow the falling assembly.
func _feedback_parent() -> Node3D:
	var candidate: Node3D = null
	if _gateway != null:
		candidate = _gateway.get_node_or_null(_gateway.terrain_path) as Node3D
	if candidate == null:
		candidate = get_parent() as Node3D
	if candidate == null:
		candidate = get_node_or_null("/root") as Node3D
	return candidate


func _contact_point_on_body(
	body: RigidBody3D,
	local_shape_index: int,
	inbound_velocity: Vector3 = Vector3.ZERO
) -> Vector3:
	var collider := ImpactResolver.collider_from_shape_index(
		body,
		local_shape_index
	)
	var origin := body.global_position
	if collider != null:
		origin = collider.global_position
	if _gateway == null:
		return origin
	var terrain: Node3D = _gateway.get_node_or_null(_gateway.terrain_path)
	if terrain == null:
		return origin
	var motion := inbound_velocity
	if motion.length_squared() <= 0.01:
		motion = body.linear_velocity
	var ray_dir := Vector3.DOWN
	if motion.length_squared() > 0.01:
		ray_dir = motion.normalized()
	var along_motion := _probe_terrain_surface_world(
		origin - ray_dir * 0.25,
		ray_dir,
		terrain,
		body,
		4.0
	)
	if along_motion.distance_squared_to(origin - ray_dir * 0.25) > 0.000001:
		return along_motion
	return _probe_terrain_surface_world(
		origin + Vector3.UP * 1.25,
		Vector3.DOWN,
		terrain,
		body,
		4.0
	)
