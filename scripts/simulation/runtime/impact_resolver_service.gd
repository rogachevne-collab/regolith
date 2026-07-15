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
	_flush_scheduled = false


func configure_rigid_body(body: RigidBody3D) -> void:
	configure_impact_body(body, ImpactBodyMode.FULL)


func configure_impact_body(
	body: RigidBody3D,
	mode: ImpactBodyMode = ImpactBodyMode.FULL
) -> void:
	if body == null or body.has_meta("impact_monitoring"):
		return
	body.contact_monitor = true
	body.max_contacts_reported = 16
	body.continuous_cd = true
	body.custom_integrator = mode == ImpactBodyMode.FULL
	body.set_meta("impact_monitoring", true)
	body.set_meta("impact_body_mode", mode)
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
	if not ImpactResolver.is_world_surface_partner(other_body):
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
	var contact_world := _contact_point_on_body(body, local_shape_index)
	var contact_normal := _contact_normal_toward_partner(
		body,
		contact_world,
		other_body
	)
	var impulse_length := ImpactResolver.fallback_impulse_length(
		body,
		other_body,
		contact_normal
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
		if impulse_length < ImpactResolver.I_MIN:
			continue
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
		if partner == null or ImpactResolver.is_world_surface_partner(partner):
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
		var contact_world := _contact_point_on_body(body, local_shape_index)
		var entry: Dictionary = _frame_batch.get(batch_key, {})
		if entry.is_empty():
			entry = {
				"batch_key": batch_key,
				"striker_element_id": striker_element_id,
				"striker_body": body,
				"local_shape_index": local_shape_index,
				"partner": partner,
				"impulse_length": impulse_length,
				"contact_world": contact_world,
				"contact_points": PackedVector3Array(),
				"contact_impulses": PackedFloat32Array(),
			}
		else:
			entry["impulse_length"] = maxf(
				float(entry.get("impulse_length", 0.0)),
				impulse_length
			)
		var points: PackedVector3Array = entry.get(
			"contact_points",
			PackedVector3Array()
		)
		points.append(contact_world)
		entry["contact_points"] = points
		var impulses: PackedFloat32Array = entry.get(
			"contact_impulses",
			PackedFloat32Array()
		)
		impulses.append(impulse_length)
		entry["contact_impulses"] = impulses
		_queue_entry(entry)


func _queue_entry(entry: Dictionary) -> void:
	var batch_key := str(entry.get("batch_key", ""))
	if batch_key.is_empty():
		return
	_frame_batch[batch_key] = entry
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
		volume_budget -= _apply_entry(entry, volume_budget)
		if volume_budget <= 0.0:
			break


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
	if ImpactResolver.is_world_surface_partner(partner):
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
	var carve_direction := Vector3.DOWN
	if body != null and body.linear_velocity.length_squared() > 0.01:
		carve_direction = body.linear_velocity.normalized()
	var points: PackedVector3Array = entry.get(
		"contact_points",
		PackedVector3Array()
	)
	var op: Dictionary
	if points.size() >= 2:
		var radii := PackedFloat32Array()
		var base_radius := TerrainImpactCarver.base_radius_from_collider(collider)
		for index: int in range(points.size()):
			var local_strength := strength
			if entry.has("contact_impulses"):
				var impulses: PackedFloat32Array = entry["contact_impulses"]
				if index < impulses.size():
					local_strength = ImpactResolver.impulse_strength(
						float(impulses[index])
					)
			radii.append(
				clampf(
					base_radius * (0.35 + 0.65 * local_strength),
					TerrainImpactCarver.MIN_RADIUS,
					TerrainImpactCarver.MAX_RADIUS
				)
			)
		op = TerrainImpactCarver.build_path_op(
			points,
			radii,
			strength,
			terrain,
			carve_direction
		)
	else:
		op = TerrainImpactCarver.build_sphere_op(
			Vector3(entry.get("contact_world", Vector3.ZERO)),
			collider,
			strength,
			terrain,
			carve_direction
		)
	return _gateway.apply_terrain_carve(op, volume_budget_m3)


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
	partner: Object
) -> Vector3:
	if body == null:
		return Vector3.UP
	var partner_point := contact_world
	if partner is Node3D:
		partner_point = (partner as Node3D).global_position
	var toward_partner := partner_point - body.global_position
	if toward_partner.length_squared() <= 0.000001:
		if body.linear_velocity.length_squared() > 0.01:
			return -body.linear_velocity.normalized()
		return Vector3.UP
	return toward_partner.normalized()


func _contact_point_on_body(
	body: RigidBody3D,
	local_shape_index: int
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
	var ray_dir := Vector3.DOWN
	if body.linear_velocity.length_squared() > 0.01:
		ray_dir = -body.linear_velocity.normalized()
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
