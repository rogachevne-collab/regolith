class_name AssemblyTeardownCoordinator
extends RefCounted
## Assembly teardown and driver evacuation extracted from SimulationPhysicsProjection.


static func sorted_int_keys(dictionary: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for key: Variant in dictionary:
		result.append(int(key))
	result.sort()
	return result


static func remove_group_bodies(
	projection,
	assembly_id: int) -> void:
	var groups: Variant = projection._assembly_group_bodies.get(assembly_id)
	if not groups is Dictionary:
		return
	for group_id_variant: Variant in groups.keys():
		var body: PhysicsBody3D = groups[group_id_variant] as PhysicsBody3D
		if body == null:
			continue
		if projection._mounted_bodies.get(assembly_id) == body:
			AssemblyBodyBuildCoordinator.clear_body_colliders(projection, body)
		else:
			AssemblyTeardownCoordinator.evacuate_seated_drivers(projection, body)
			body.collision_layer = 0
			body.collision_mask = 0
			body.process_mode = Node.PROCESS_MODE_DISABLED
			body.queue_free()
	projection._assembly_group_bodies.erase(assembly_id)


static func evacuate_seated_drivers(
	projection,
	body: PhysicsBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var to_move: Array[Node] = []
	for child_node: Node in body.get_children():
		if (
			child_node.has_method("is_in_vehicle")
			and child_node.has_method("enter_vehicle")
			and bool(child_node.call("is_in_vehicle"))
		):
			to_move.append(child_node)
	for child_node: Node in to_move:
		var driver := child_node as Node3D
		if driver == null:
			continue
		var seat_local := driver.position
		var world_xform := driver.global_transform
		var element_id := int(driver.get_meta("control_seat_element_id", 0))
		body.remove_child(driver)
		projection.add_child(driver)
		driver.global_transform = world_xform
		projection._evacuated_drivers.append({
			"player": driver,
			"seat_local": seat_local,
			"element_id": element_id,
		})


static func restore_evacuated_drivers(
	projection
) -> void:
	if projection._evacuated_drivers.is_empty():
		return
	var pending: Array[Dictionary] = projection._evacuated_drivers.duplicate()
	projection._evacuated_drivers.clear()
	for entry: Dictionary in pending:
		var player_variant: Variant = entry.get("player")
		if (
			player_variant == null
			or not (player_variant is Node)
			or not is_instance_valid(player_variant)
		):
			continue
		var player := player_variant as Node
		var element_id := int(entry.get("element_id", 0))
		var seat_local: Vector3 = entry.get("seat_local", Vector3.ZERO)
		var body: PhysicsBody3D = null
		if element_id > 0:
			body = (
				projection.get_element_projection(element_id).get("body") as PhysicsBody3D
			)
		if body == null or not is_instance_valid(body):
			push_warning(
				"SimulationPhysicsProjection: seated driver evacuated but seat body missing (element %d)"
				% element_id
			)
			continue
		if player.has_method("enter_vehicle"):
			player.call("enter_vehicle", body, seat_local)
		# Coop replica seat: enter_vehicle sets INHERIT (host RigidBody path);
		# re-assert OFF so the camera does not smear on streamed kinematic bodies.
		if (
			player is Node3D
			and (player as Node3D).has_meta("coop_replica_seat")
		):
			(player as Node3D).physics_interpolation_mode = (
				Node.PHYSICS_INTERPOLATION_MODE_OFF
			)
			(player as Node3D).reset_physics_interpolation()


static func clear_piston_constraints(
	projection,
	assembly_id: int
) -> void:
	for constraints: Dictionary in [
		projection._piston_constraints,
		projection._rotor_constraints,
		projection._wheel_constraints,
	]:
		var records: Variant = constraints.get(assembly_id, [])
		if records is Array:
			for record_variant: Variant in records:
				if not record_variant is Dictionary:
					continue
				var constraint: Generic6DOFJoint3D = (
					record_variant.get("constraint") as Generic6DOFJoint3D
				)
				if constraint != null and is_instance_valid(constraint):
					constraint.queue_free()
		constraints.erase(assembly_id)
	projection._root_group_ids.erase(assembly_id)


static func remove_body(
	projection,
	assembly_id: int) -> void:
	AssemblyTeardownCoordinator.clear_piston_constraints(projection, assembly_id)
	AssemblyTeardownCoordinator.remove_group_bodies(projection, assembly_id)
	AssemblyTeardownCoordinator.remove_element_records_for_assembly(projection, assembly_id)
	var body: PhysicsBody3D = projection.get_physics_body(assembly_id)
	if body != null and not projection._assembly_group_bodies.has(assembly_id):
		if body is RigidBody3D and projection._impact_service != null:
			projection._impact_service.unregister_tracked_body(body as RigidBody3D)
		if projection._mounted_bodies.get(assembly_id) == body:
			AssemblyBodyBuildCoordinator.clear_body_colliders(projection, body)
		else:
			AssemblyTeardownCoordinator.evacuate_seated_drivers(projection, body)
			body.collision_layer = 0
			body.collision_mask = 0
			body.process_mode = Node.PROCESS_MODE_DISABLED
			body.queue_free()
	projection._bodies.erase(assembly_id)
	projection._projected_revision.erase(assembly_id)
	projection._tick_key_structure_rev += 1


## Pull seated Player nodes off a body before queue_free. Seat entry parents the
## driver under the chassis; StaticBody→RigidBody / multibody reproject must not
## take the camera with the doomed body (blue clear-color screen).


static func remove_element_records_for_assembly(
	projection,
	assembly_id: int
) -> void:
	var stale: Array[int] = []
	for element_id: int in projection._element_records:
		var record: Dictionary = projection._element_records[element_id]
		if int(record.get("assembly_id", 0)) == assembly_id:
			stale.append(element_id)
	for element_id: int in stale:
		projection._element_records.erase(element_id)


static func clear_all_bodies(
	projection
) -> void:
	for assembly_id: int in AssemblyTeardownCoordinator.sorted_int_keys(
		projection._piston_constraints
	):
		AssemblyTeardownCoordinator.clear_piston_constraints(projection, assembly_id)
	for assembly_id: int in AssemblyTeardownCoordinator.sorted_int_keys(
		projection._rotor_constraints
	):
		AssemblyTeardownCoordinator.clear_piston_constraints(projection, assembly_id)
	for assembly_id: int in AssemblyTeardownCoordinator.sorted_int_keys(projection._bodies):
		AssemblyTeardownCoordinator.remove_body(projection, assembly_id)
	projection._bodies.clear()
	projection._element_records.clear()
	projection._projected_revision.clear()
	projection._assembly_group_bodies.clear()
	projection._root_group_ids.clear()
	projection._piston_constraints.clear()
	projection._rotor_constraints.clear()
	projection._wheel_constraints.clear()
	# Rope frozen-shapes cache bodies from this same body set (see
	# _cable_try_freeze). A join/resync (rebuild_all) or teardown frees the
	# bodies above without touching this dict, so a stale entry would keep
	# handing rope_path a freed RigidBody3D every frame forever — this is the
	# guest join rope_path spam. Dropping it here is harmless: on an
	# authoritative world the next _tick_cable_ropes just re-settles and
	# re-freezes each rope in ~0.5 s; a non-authoritative world never ticks
	# ropes at all and instead renders the analytic curve (see
	# _display_points), so an empty dict is exactly its resting state.
	projection._rope_states.clear()

