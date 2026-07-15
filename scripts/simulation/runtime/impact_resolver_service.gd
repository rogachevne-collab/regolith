class_name ImpactResolverService
extends Node

enum ImpactBodyMode {
	FULL,
	MONITOR_ONLY,
}

const COOLDOWN_MS := 80

var _world: SimulationWorld
var _gateway: WorldCommandGateway
var _frame_batch: Dictionary = {}
var _flush_scheduled := false
var _cooldown_until: Dictionary = {}
var _tracked_bodies: Dictionary = {}
var _pre_step_velocity: Dictionary = {}
var last_terrain_carve_m3: float = 0.0


func bind(
	world: SimulationWorld,
	gateway: WorldCommandGateway
) -> void:
	_world = world
	_gateway = gateway


func unbind() -> void:
	_world = null
	_gateway = null
	_frame_batch.clear()
	_cooldown_until.clear()
	_tracked_bodies.clear()
	_pre_step_velocity.clear()
	_flush_scheduled = false


## Contact signals fire after the physics step, when the collision has
## already been resolved and linear_velocity is post-impact. Cache each
## monitored body's velocity before the step so J_fallback sees the
## incoming velocity (known Godot contact-signal pitfall).
func _physics_process(_delta: float) -> void:
	var stale: Array = []
	for body_id: int in _tracked_bodies:
		var body: RigidBody3D = _tracked_bodies[body_id]
		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			stale.append(body_id)
			continue
		_pre_step_velocity[body_id] = body.linear_velocity
	for body_id: int in stale:
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
	var assembly_id := int(striker_body.get_meta("assembly_id", 0))
	if ImpactResolver.same_assembly_subgrid(assembly_id, partner):
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
	_queue_entry({
		"batch_key": batch_key,
		"striker_element_id": striker_element_id,
		"striker_body": striker_body,
		"local_shape_index": local_shape_index,
		"partner": partner,
		"impulse_length": impulse_length,
		"contact_world": contact_world,
		"contact_points": PackedVector3Array([contact_world]),
		"contact_impulses": PackedFloat32Array([impulse_length]),
	})


func _on_body_shape_entered(
	body: RigidBody3D,
	_body_rid: RID,
	other_body: Node,
	_other_shape_index: int,
	local_shape_index: int
) -> void:
	if body == null or body.freeze or other_body == null:
		return
	var is_world_surface := ImpactResolver.is_world_surface_partner(other_body)
	if not is_world_surface and not ImpactResolver.is_assembly_partner(other_body):
		return
	var assembly_id := int(body.get_meta("assembly_id", 0))
	if assembly_id <= 0:
		return
	if ImpactResolver.same_assembly_subgrid(assembly_id, other_body):
		return
	if not ImpactResolver.assembly_has_construction_elements(_world, assembly_id):
		return
	var striker_element_id := ImpactResolver.element_id_from_shape_index(
		body,
		local_shape_index
	)
	if striker_element_id <= 0:
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
	var impulse_length := ImpactResolver.fallback_impulse_length(
		body,
		other_body,
		contact_normal,
		inbound_velocity - partner_velocity
	)
	if impulse_length < ImpactResolver.I_MIN:
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
		"impulse_length": impulse_length,
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
	if not ImpactResolver.assembly_has_construction_elements(_world, assembly_id):
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
		var local_normal := state.get_contact_local_normal(contact_index)
		var world_normal := (
			body.global_transform.basis * local_normal
		).normalized()
		if partner == null and absf(world_normal.y) >= 0.35:
			partner = _terrain_partner()
		if partner == null:
			continue
		if (
			not ImpactResolver.is_world_surface_partner(partner)
			and not ImpactResolver.is_assembly_partner(partner)
		):
			continue
		if ImpactResolver.same_assembly_subgrid(assembly_id, partner):
			continue
		var partner_key := ImpactResolver.partner_key_from_object(partner)
		var batch_key := ImpactResolver.batch_key(
			striker_element_id,
			partner_key,
			local_shape_index
		)
		if not _cooldown_ready(batch_key):
			continue
		var contact_world := body.to_global(
			state.get_contact_local_position(contact_index)
		)
		# Contact velocities are captured pre-solve by the Jolt contact
		# listener; body.linear_velocity here is already post-impact.
		var contact_relative_velocity := (
			state.get_contact_local_velocity_at_position(contact_index)
			- state.get_contact_collider_velocity_at_position(contact_index)
		)
		var inbound_velocity := pre_step_velocity(body)
		var effective_impulse := maxf(
			impulse_length,
			ImpactResolver.fallback_impulse_length(
				body,
				partner,
				world_normal,
				contact_relative_velocity
			)
		)
		if effective_impulse < ImpactResolver.I_MIN:
			continue
		_queue_entry({
			"batch_key": batch_key,
			"striker_element_id": striker_element_id,
			"striker_body": body,
			"local_shape_index": local_shape_index,
			"partner": partner,
			"impulse_length": effective_impulse,
			"contact_world": contact_world,
			"contact_normal": world_normal,
			"inbound_velocity": inbound_velocity,
			"contact_points": PackedVector3Array(),
			"contact_impulses": PackedFloat32Array(),
		})


## Entries from different J sources (contact estimate, fallback, sustained)
## may target the same pair in one frame — spec combines them by max.
func _queue_entry(entry: Dictionary) -> void:
	var batch_key := str(entry.get("batch_key", ""))
	if batch_key.is_empty():
		return
	var existing: Dictionary = _frame_batch.get(batch_key, {})
	if (
		existing.is_empty()
		or float(entry.get("impulse_length", 0.0))
		>= float(existing.get("impulse_length", 0.0))
	):
		_frame_batch[batch_key] = existing.merged(entry, true)
	if not _flush_scheduled:
		_flush_scheduled = true
		call_deferred("_flush_batch")


func apply_entry_for_test(entry: Dictionary) -> float:
	return _apply_entry(entry)


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
	if ImpactResolver.same_assembly_subgrid(striker_assembly_id, partner):
		return 0.0
	var impulse_length := float(entry.get("impulse_length", 0.0))
	var strength := ImpactResolver.impulse_strength(impulse_length)
	if strength <= 0.0:
		return 0.0
	var batch_key := str(entry.get("batch_key", ""))
	if not batch_key.is_empty():
		_cooldown_until[batch_key] = Time.get_ticks_msec() + COOLDOWN_MS
	var used_volume := 0.0
	if (
		volume_budget_m3 > 0.0
		and ImpactResolver.is_world_surface_partner(partner)
	):
		used_volume = _apply_terrain_carve(entry, strength, volume_budget_m3)
	_apply_element_damage(striker_element_id, impulse_length)
	return used_volume


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
	var contact_world := _snap_contact_to_terrain_surface(
		Vector3(entry.get("contact_world", Vector3.ZERO)),
		terrain
	)
	var op := TerrainImpactCarver.build_sphere_op(
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
	terrain: Node3D
) -> Vector3:
	if _gateway == null or terrain == null:
		return contact_world
	var tool: VoxelTool = _gateway.get_voxel_tool()
	if tool == null:
		return contact_world
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		terrain,
		contact_world + Vector3.UP * 0.75,
		Vector3.DOWN,
		2.0
	)
	if hit == null:
		return contact_world
	return VoxelSpaceUtil.raycast_hit_world_point(
		terrain,
		contact_world + Vector3.UP * 0.75,
		Vector3.DOWN,
		hit
	)


func _apply_element_damage(
	element_id: int,
	impulse_length: float
) -> void:
	var element := _world.get_element(element_id)
	if element == null:
		return
	var archetype := element.get_archetype()
	if archetype == null:
		return
	var amount := ImpactResolver.damage_amount(
		impulse_length,
		archetype.max_integrity
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
	var tool: VoxelTool = _gateway.get_voxel_tool()
	if tool == null:
		return origin
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var terrain: Node3D = _gateway.get_node_or_null(_gateway.terrain_path)
	# Probe along the motion direction — the surface we hit lies ahead of
	# the collider, not behind it.
	var ray_dir := Vector3.DOWN
	var motion := inbound_velocity
	if motion == Vector3.ZERO:
		motion = body.linear_velocity
	if motion.length_squared() > 0.01:
		ray_dir = motion.normalized()
	var ray_origin := origin - ray_dir * 0.25
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		terrain,
		ray_origin,
		ray_dir,
		4.0
	)
	if hit != null:
		return VoxelSpaceUtil.raycast_hit_world_point(
			terrain,
			ray_origin,
			ray_dir,
			hit
		)
	# Fallback: probe downward when velocity-aligned ray misses.
	hit = VoxelSpaceUtil.raycast_world(
		tool,
		terrain,
		origin + Vector3.UP * 0.25,
		Vector3.DOWN,
		4.0
	)
	if hit != null:
		return VoxelSpaceUtil.raycast_hit_world_point(
			terrain,
			origin + Vector3.UP * 0.25,
			Vector3.DOWN,
			hit
		)
	return origin
