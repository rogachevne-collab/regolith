class_name ConstructionPlacement
extends RefCounted

const SURFACE_EPSILON := 0.05


static func plan(
	world: SimulationWorld,
	target: Dictionary,
	archetype: ElementArchetype,
	orientation_index: int,
	store_id: String,
	held_ground_pivot: Vector3 = Vector3(INF, INF, INF),
	held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Dictionary:
	if (
		world == null
		or archetype == null
		or not bool(target.get("valid", false))
	):
		return _failed(StructuralCommandResult.REASON_INVALID_TARGET)
	var command := PlaceElementCommand.new()
	command.archetype = archetype
	command.orientation_index = orientation_index
	command.store_id = store_id
	var world_transform := Transform3D.IDENTITY
	var assembly_world_transform := Transform3D.IDENTITY
	var attach_snap_context: Dictionary = {}
	var target_kind := StringName(target.get("target_kind", &""))
	if target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
		var metadata: Dictionary = target.get("metadata", {})
		var assembly_id := int(metadata.get("assembly_id", 0))
		var assembly := world.get_assembly(assembly_id)
		if assembly == null or assembly.tombstoned:
			return _failed(StructuralCommandResult.REASON_INVALID_REFERENCE)
		command.assembly_id = assembly.assembly_id
		command.expected_assembly_revision = assembly.topology_revision
		var snap_context := _attach_snap_context(
			world,
			assembly,
			target,
			metadata
		)
		attach_snap_context = snap_context.duplicate(true)
		command.origin_cell = _resolve_attach_origin(
			world,
			archetype,
			snap_context,
			command.orientation_index,
			command.assembly_id,
			store_id,
			held_attach_pivot
		)
		assembly_world_transform = snap_context.get(
			"assembly_world_transform",
			assembly.motion.transform
		) as Transform3D
		world_transform = (
			assembly_world_transform
			* GridPoseUtil.element_local_transform(
				command.origin_cell,
				command.orientation_index
			)
		)
	elif target_kind == InteractionHit.KIND_VOXEL:
		var metadata: Dictionary = target.get("metadata", {})
		var aim_direction := Vector3(
			metadata.get("aim_direction", Vector3.FORWARD)
		)
		var surface_point := Vector3(target.get("point", Vector3.ZERO))
		# Field-upright orientation keeps the base level on slopes; only the
		# discrete grid frame is snapped. The continuous root keeps the exact
		# surface contact height so the block neither floats nor tilts. On a
		# radial field (spherical moon) the local up is the surface up, not
		# world +Y — a world-snapped root there buries the block in the crust.
		var surface_up := _surface_up_for_target(target)
		var aim_basis := _upright_basis(aim_direction, surface_up)
		command.assembly_id = 0
		command.origin_cell = Vector3i.ZERO
		command.new_assembly_grid_frame = (
			GridSpawnUtil.grid_frame_from_transform(
				Transform3D(aim_basis, surface_point)
			)
		)
		var upright_basis := _field_aligned_grid_basis(
			command.new_assembly_grid_frame.orientation_index,
			surface_up
		)
		if held_ground_pivot.is_finite():
			assembly_world_transform = (
				GridPoseUtil.ground_assembly_transform_pivot_hold(
					archetype,
					command.orientation_index,
					upright_basis,
					held_ground_pivot
				)
			)
		else:
			var ground_contact := GridPoseUtil.ground_contact_local(
				archetype,
				command.orientation_index
			)
			assembly_world_transform = Transform3D(
				upright_basis,
				surface_point - upright_basis * ground_contact
			)
		world_transform = (
			assembly_world_transform
			* GridPoseUtil.element_local_transform(
				Vector3i.ZERO,
				command.orientation_index
			)
		)
	else:
		return _failed(StructuralCommandResult.REASON_INVALID_TARGET)

	if command.assembly_id == 0:
		command.initial_motion = AssemblyMotionState.new()
		command.initial_motion.transform = assembly_world_transform

	var validation := world.preview_place_element(command)
	if (
		not validation.is_ok()
		and validation.reason == StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
		and target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
	):
		# Auto-facing: a part with only a few mount faces (a suspension with
		# one frame pad) often arrives rotated so none of them touch the
		# target. Instead of a mute red ghost, turn the part so a mount face
		# looks at the target — nearest rotation to the player's wins.
		var original_orientation := command.orientation_index
		var original_origin := command.origin_cell
		for alt_orientation: int in _auto_facing_orientations(
			archetype,
			attach_snap_context,
			orientation_index
		):
			command.orientation_index = alt_orientation
			command.origin_cell = _resolve_attach_origin(
				world,
				archetype,
				attach_snap_context,
				alt_orientation,
				command.assembly_id,
				store_id,
				held_attach_pivot
			)
			var alt_validation := world.preview_place_element(command)
			if alt_validation.is_ok():
				validation = alt_validation
				world_transform = (
					assembly_world_transform
					* GridPoseUtil.element_local_transform(
						command.origin_cell,
						command.orientation_index
					)
				)
				break
		if not validation.is_ok():
			command.orientation_index = original_orientation
			command.origin_cell = original_origin
	if (
		validation.is_ok()
		and target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
	):
		command.pose_offset = _precise_attach_offset(
			world,
			command,
			validation.data
		)
		if command.pose_offset != Transform3D.IDENTITY:
			world_transform = (
				assembly_world_transform
				* GridPoseUtil.element_local_transform(
					command.origin_cell,
					command.orientation_index,
					command.pose_offset
				)
			)
	return {
		"valid": validation.is_ok(),
		"reason": validation.reason,
		"data": validation.data,
		"command": command,
		"world_transform": world_transform,
		"assembly_world_transform": assembly_world_transform,
		"preview_root_transform": assembly_world_transform,
		"origin_cell": command.origin_cell,
		"orientation_index": command.orientation_index,
		"archetype": archetype,
		"attach_snap_context": attach_snap_context,
	}


static func baseline_ground_pivot(
	world: SimulationWorld,
	target: Dictionary,
	archetype: ElementArchetype,
	store_id: String
) -> Vector3:
	var baseline := plan(world, target, archetype, 0, store_id)
	if not bool(baseline.get("valid", false)):
		return Vector3(INF, INF, INF)
	return GridPoseUtil.world_footprint_pivot(
		baseline["preview_root_transform"],
		archetype,
		baseline["origin_cell"],
		0
	)


static func _surface_up_for_target(target: Dictionary) -> Vector3:
	var up := Vector3(
		target.get(
			"surface_up",
			target.get("metadata", {}).get(
				"surface_up",
				target.get("normal", Vector3.UP)
			)
		)
	)
	if not up.is_finite() or up.length_squared() <= 0.000001:
		return Vector3.UP
	return up.normalized()


static func _upright_basis(
	aim_direction: Vector3,
	surface_up: Vector3 = Vector3.UP
) -> Basis:
	var up := surface_up
	if not up.is_finite() or up.length_squared() <= 0.000001:
		up = Vector3.UP
	up = up.normalized()
	var forward := aim_direction - up * aim_direction.dot(up)
	if forward.length_squared() < 0.000001:
		forward = Vector3.FORWARD - up * Vector3.FORWARD.dot(up)
	if forward.length_squared() < 0.000001:
		forward = Vector3.RIGHT - up * Vector3.RIGHT.dot(up)
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	forward = up.cross(right).normalized()
	return Basis(right, up, -forward).orthonormalized()


## Snapped grid orientation re-anchored to the Field up. On a flat field this
## is exactly the snapped world-grid basis (old behaviour, yaw quantized). On
## a radial field the snapped basis is rotated by the shortest arc so local +Y
## matches the surface up and the block base stays level on the sphere.
static func _field_aligned_grid_basis(
	orientation_index: int,
	surface_up: Vector3
) -> Basis:
	var orient_basis := OrientationUtil.orientation_basis(orientation_index)
	var up := surface_up
	if not up.is_finite() or up.length_squared() <= 0.000001:
		return orient_basis
	up = up.normalized()
	var alignment := orient_basis.y.dot(up)
	if alignment >= 1.0 - 0.000001:
		return orient_basis
	if alignment <= -1.0 + 0.000001:
		return (Basis(orient_basis.x.normalized(), PI) * orient_basis).orthonormalized()
	return (Basis(Quaternion(orient_basis.y, up)) * orient_basis).orthonormalized()


static func _dominant_grid_direction(direction: Vector3) -> Vector3i:
	var absolute := direction.abs()
	if absolute.x >= absolute.y and absolute.x >= absolute.z:
		return Vector3i.RIGHT if direction.x >= 0.0 else Vector3i.LEFT
	if absolute.y >= absolute.z:
		return Vector3i.UP if direction.y >= 0.0 else Vector3i.DOWN
	return Vector3i.BACK if direction.z >= 0.0 else Vector3i.FORWARD


static func _attach_frame_for_target(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	metadata: Dictionary
) -> Transform3D:
	# Hit->cell mapping and the ghost follow the aimed element's LIVE body
	# group frame: group colliders keep blueprint-local offsets, so on a
	# sagged/flexed branch this frame resolves the same cells as the root
	# frame does at home, while the ghost hugs the real geometry. Occupancy
	# itself stays in blueprint grid space and is unaffected.
	if assembly == null or assembly.motion == null:
		return Transform3D.IDENTITY
	var element_id := int(metadata.get("element_id", 0))
	if element_id > 0 and world != null:
		var element := world.get_element(element_id)
		if element != null and element.assembly_id == assembly.assembly_id:
			return world.element_group_transform(element_id)
	return assembly.motion.transform


static func _attach_snap_context(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	target: Dictionary,
	metadata: Dictionary
) -> Dictionary:
	var assembly_world_transform := _attach_frame_for_target(
		world,
		assembly,
		metadata
	)
	if (
		metadata.has("locked_target_port_cell")
		and metadata.has("locked_snap_dir")
	):
		return {
			"target_port_cell": metadata["locked_target_port_cell"],
			"snap_dir": metadata["locked_snap_dir"],
			"assembly_world_transform": assembly_world_transform,
		}
	var point := Vector3(target.get("point", Vector3.ZERO))
	var normal := Vector3(target.get("normal", Vector3.UP)).normalized()
	# Prefer the nearest authored structural pad on the aimed element so a
	# glancing hit on a large piston head deck does not snap to a side cell.
	var element_id := int(metadata.get("element_id", 0))
	if element_id > 0 and point.is_finite():
		var target_element := world.get_element(element_id)
		var nearest := GridSurfaceUtil.nearest_assembly_face_to_hit(
			target_element,
			point,
			normal,
			assembly_world_transform
		)
		if not nearest.is_empty():
			return {
				"target_port_cell": nearest["cell"],
				"snap_dir": nearest["direction"],
				"assembly_world_transform": assembly_world_transform,
			}
	var local_normal := assembly_world_transform.basis.inverse() * normal
	var snap_dir := _dominant_grid_direction(local_normal)
	var target_port_cell: Vector3i
	if point.is_finite() and normal.is_finite() and normal.length_squared() > 0.0:
		var local_point := assembly_world_transform.affine_inverse() * (
			point + normal * SURFACE_EPSILON
		)
		target_port_cell = GridMetric.meters_to_cell_floor(local_point) - snap_dir
	elif metadata.has("element_id"):
		var target_element := world.get_element(element_id)
		if (
			target_element != null
			and metadata.has("collider_local_cell")
		):
			target_port_cell = (
				target_element.origin_cell
				+ OrientationUtil.rotate_cell(
					metadata.get("collider_local_cell", Vector3i.ZERO),
					target_element.orientation_index
				)
			)
		else:
			target_port_cell = Vector3i.ZERO - snap_dir
	else:
		target_port_cell = Vector3i.ZERO - snap_dir
	return {
		"target_port_cell": target_port_cell,
		"snap_dir": snap_dir,
		"assembly_world_transform": assembly_world_transform,
	}


static func ranked_attach_plans(
	world: SimulationWorld,
	target: Dictionary,
	archetype: ElementArchetype,
	orientation_index: int,
	store_id: String,
	held_ground_pivot: Vector3 = Vector3(INF, INF, INF),
	held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Array[Dictionary]:
	if (
		world == null
		or archetype == null
		or not bool(target.get("valid", false))
		or StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return []
	var metadata: Dictionary = target.get("metadata", {})
	var assembly_id := int(metadata.get("assembly_id", 0))
	var assembly := world.get_assembly(assembly_id)
	if assembly == null or assembly.tombstoned:
		return []
	var snap_context := _attach_snap_context(
		world,
		assembly,
		target,
		metadata
	)
	var ranked_origins := _ranked_attach_origins(
		world,
		archetype,
		snap_context,
		orientation_index,
		assembly_id,
		store_id,
		held_attach_pivot
	)
	var plans: Array[Dictionary] = []
	var best_invalid: Dictionary = {}
	var seen_origins: Dictionary = {}
	for origin_cell: Vector3i in ranked_origins:
		if seen_origins.has(origin_cell):
			continue
		seen_origins[origin_cell] = true
		var candidate := _plan_for_attach_origin(
			world,
			target,
			archetype,
			orientation_index,
			store_id,
			held_ground_pivot,
			snap_context,
			origin_cell
		)
		if bool(candidate.get("valid", false)):
			plans.append(candidate)
		elif best_invalid.is_empty():
			best_invalid = candidate
	# Keep one invalid plan so the preview can show a red ghost + reason
	# instead of hiding completely when every candidate fails.
	if plans.is_empty() and not best_invalid.is_empty():
		plans.append(best_invalid)
	return plans


static func _plan_for_attach_origin(
	world: SimulationWorld,
	target: Dictionary,
	archetype: ElementArchetype,
	orientation_index: int,
	store_id: String,
	_held_ground_pivot: Vector3,
	snap_context: Dictionary,
	origin_cell: Vector3i
) -> Dictionary:
	var metadata: Dictionary = target.get("metadata", {})
	var assembly_id := int(metadata.get("assembly_id", 0))
	var assembly := world.get_assembly(assembly_id)
	if assembly == null or assembly.tombstoned:
		return _failed(StructuralCommandResult.REASON_INVALID_REFERENCE)
	var command := PlaceElementCommand.new()
	command.archetype = archetype
	command.orientation_index = orientation_index
	command.store_id = store_id
	command.assembly_id = assembly_id
	command.expected_assembly_revision = assembly.topology_revision
	command.origin_cell = origin_cell
	var assembly_world_transform: Transform3D = snap_context.get(
		"assembly_world_transform",
		assembly.motion.transform
	) as Transform3D
	var world_transform := (
		assembly_world_transform
		* GridPoseUtil.element_local_transform(
			command.origin_cell,
			command.orientation_index
		)
	)
	var validation := world.preview_place_element(command)
	if validation.is_ok():
		command.pose_offset = _precise_attach_offset(
			world,
			command,
			validation.data
		)
		if command.pose_offset != Transform3D.IDENTITY:
			world_transform = (
				assembly_world_transform
				* GridPoseUtil.element_local_transform(
					command.origin_cell,
					command.orientation_index,
					command.pose_offset
				)
			)
	return {
		"valid": validation.is_ok(),
		"reason": validation.reason,
		"data": validation.data,
		"command": command,
		"world_transform": world_transform,
		"assembly_world_transform": assembly_world_transform,
		"preview_root_transform": assembly_world_transform,
		"origin_cell": command.origin_cell,
		"orientation_index": command.orientation_index,
		"archetype": archetype,
		"attach_snap_context": snap_context.duplicate(true),
	}


## Orientations that turn at least one of the part's grid mount faces toward
## the snap target (face == -snap_dir), nearest to `current` first. `current`
## itself is excluded — it just failed.
static func _auto_facing_orientations(
	archetype: ElementArchetype,
	snap_context: Dictionary,
	current: int
) -> Array[int]:
	var snap_dir: Vector3i = snap_context.get("snap_dir", Vector3i.ZERO)
	if snap_dir == Vector3i.ZERO or archetype == null:
		return []
	var wanted := -snap_dir
	var result: Array[int] = []
	for index: int in range(OrientationUtil.ORIENTATION_COUNT):
		if index == current:
			continue
		for connector: ConnectorDefinition in archetype.effective_connectors():
			if connector == null or not connector.is_grid:
				continue
			var rotated := OrientationUtil.rotate_direction(
				OrientationUtil.face_to_vector(connector.grid_face),
				index
			)
			if rotated == wanted:
				result.append(index)
				break
	var current_basis := OrientationUtil.orientation_basis(current)
	result.sort_custom(
		func(left: int, right: int) -> bool:
			return (
				_rotation_distance(current_basis, left)
				< _rotation_distance(current_basis, right)
			)
	)
	return result


static func _rotation_distance(from_basis: Basis, to_index: int) -> float:
	var delta := (
		from_basis.inverse() * OrientationUtil.orientation_basis(to_index)
	)
	return delta.get_rotation_quaternion().get_angle()


## Translation-only pose_offset that puts the held part's mount point exactly
## on the target's mount point.
##
## The target side is a grid pad: a block's mount point is the centre of the
## cell face, so the part lands on the 0.5 m grid as expected. The held side
## is whatever the author marked — the tip of a stub axle, a bracket ear —
## so THAT is the bit of the model that touches. A part with no authored
## points is face-centred on both sides and gets identity.
static func precise_attach_pose_offset(
	existing: SimulationElement,
	existing_port_id: String,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int,
	new_port_id: String
) -> Transform3D:
	if existing == null:
		return Transform3D.IDENTITY
	var existing_connector := _connector_by_id(
		existing.get_archetype(),
		existing_port_id
	)
	var new_connector := _connector_by_id(archetype, new_port_id)
	if existing_connector == null or new_connector == null:
		return Transform3D.IDENTITY
	var target_point: Vector3 = GridPoseUtil.element_metric_transform(
		existing.origin_cell,
		existing.orientation_index,
		existing.pose_offset
	) * existing_connector.local_position
	var held_metric := GridPoseUtil.element_metric_transform(
		origin_cell,
		orientation_index
	)
	var delta: Vector3 = held_metric.basis.inverse() * (
		target_point - held_metric * new_connector.local_position
	)
	if delta.is_zero_approx():
		return Transform3D.IDENTITY
	return Transform3D(Basis.IDENTITY, delta)


static func _precise_attach_offset(
	world: SimulationWorld,
	command: PlaceElementCommand,
	validation_data: Dictionary
) -> Transform3D:
	var connections: Variant = validation_data.get("connections", [])
	if not (connections is Array):
		return Transform3D.IDENTITY
	var offset := Transform3D.IDENTITY
	for connection: Variant in connections:
		if not (connection is Dictionary):
			continue
		var existing := world.get_element(
			int(connection.get("existing_element_id", 0))
		)
		var candidate := precise_attach_pose_offset(
			existing,
			str(connection.get("existing_port_id", "")),
			command.archetype,
			command.origin_cell,
			command.orientation_index,
			str(connection.get("new_port_id", ""))
		)
		if candidate == Transform3D.IDENTITY:
			continue
		if offset == Transform3D.IDENTITY:
			offset = candidate
		elif not offset.is_equal_approx(candidate):
			# Two connections pull to different points; the grid pose is the
			# only one that satisfies every face pair, so keep it.
			return Transform3D.IDENTITY
	return offset


static func _connector_by_id(
	archetype: ElementArchetype,
	connector_id: String
) -> ConnectorDefinition:
	if archetype == null or connector_id.is_empty():
		return null
	for connector: ConnectorDefinition in archetype.effective_connectors():
		if connector != null and connector.id == connector_id:
			return connector
	return null


static func _resolve_attach_origin(
	world: SimulationWorld,
	archetype: ElementArchetype,
	snap_context: Dictionary,
	orientation_index: int,
	assembly_id: int,
	store_id: String,
	held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Vector3i:
	var target_port_cell: Vector3i = snap_context["target_port_cell"]
	var snap_dir: Vector3i = snap_context["snap_dir"]
	if held_attach_pivot.is_finite():
		var pivot_origin := GridPoseUtil.pivot_compensated_origin(
			archetype,
			target_port_cell,
			snap_dir,
			orientation_index
		)
		if _validate_attach_origin(
			world,
			assembly_id,
			archetype,
			pivot_origin,
			orientation_index,
			store_id
		):
			return pivot_origin
	return GridPoseUtil.snap_origin_for_target_cell(
		archetype,
		target_port_cell,
		snap_dir,
		orientation_index
	)


static func _ranked_attach_origins(
	world: SimulationWorld,
	archetype: ElementArchetype,
	snap_context: Dictionary,
	orientation_index: int,
	assembly_id: int,
	store_id: String,
	held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Array[Vector3i]:
	var target_port_cell: Vector3i = snap_context["target_port_cell"]
	var snap_dir: Vector3i = snap_context["snap_dir"]
	var candidates: Array[Vector3i] = []
	var seen: Dictionary = {}
	if held_attach_pivot.is_finite():
		var pivot_origin := GridPoseUtil.pivot_compensated_origin(
			archetype,
			target_port_cell,
			snap_dir,
			orientation_index
		)
		if (
			not seen.has(pivot_origin)
			and _validate_attach_origin(
				world,
				assembly_id,
				archetype,
				pivot_origin,
				orientation_index,
				store_id
			)
		):
			seen[pivot_origin] = true
			candidates.append(pivot_origin)
	for origin_cell: Vector3i in GridPoseUtil.snap_origin_candidates(
		archetype,
		target_port_cell,
		snap_dir,
		orientation_index
	):
		if seen.has(origin_cell):
			continue
		if not _validate_attach_origin(
			world,
			assembly_id,
			archetype,
			origin_cell,
			orientation_index,
			store_id
		):
			continue
		seen[origin_cell] = true
		candidates.append(origin_cell)
	if candidates.is_empty():
		return []
	# Center the placing contact face on the aimed pad (not lex-min origin).
	var best := GridPoseUtil.best_centered_snap_origin(
		archetype,
		target_port_cell,
		snap_dir,
		orientation_index,
		candidates
	)
	var ordered: Array[Vector3i] = [best]
	for origin_cell: Vector3i in candidates:
		if origin_cell != best:
			ordered.append(origin_cell)
	return ordered


static func _validate_attach_origin(
	world: SimulationWorld,
	assembly_id: int,
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int,
	store_id: String
) -> bool:
	var command := PlaceElementCommand.new()
	command.archetype = archetype
	command.orientation_index = orientation_index
	command.store_id = store_id
	command.assembly_id = assembly_id
	var assembly := world.get_assembly(assembly_id)
	if assembly == null:
		return false
	command.expected_assembly_revision = assembly.topology_revision
	command.origin_cell = origin_cell
	return world.preview_place_element(command).is_ok()


static func _failed(reason: StringName) -> Dictionary:
	return {
		"valid": false,
		"reason": reason,
		"data": {},
		"command": null,
		"world_transform": Transform3D.IDENTITY,
		"assembly_world_transform": Transform3D.IDENTITY,
		"preview_root_transform": Transform3D.IDENTITY,
		"origin_cell": Vector3i.ZERO,
		"orientation_index": 0,
		"archetype": null,
	}
