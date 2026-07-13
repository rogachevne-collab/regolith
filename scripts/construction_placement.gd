class_name ConstructionPlacement
extends RefCounted

const SURFACE_EPSILON := 0.05


static func plan(
	world: SimulationWorld,
	target: Dictionary,
	archetype: ElementArchetype,
	orientation_index: int,
	store_id: String = "player",
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
		assembly_world_transform = assembly.motion.transform
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
		# Gravity-upright orientation keeps the base level on slopes; only the
		# discrete grid frame is snapped. The continuous root keeps the exact
		# surface contact height so the block neither floats nor tilts.
		var aim_basis := _upright_basis(aim_direction)
		command.assembly_id = 0
		command.origin_cell = Vector3i.ZERO
		command.new_assembly_grid_frame = (
			GridSpawnUtil.grid_frame_from_transform(
				Transform3D(aim_basis, surface_point)
			)
		)
		var upright_basis := OrientationUtil.orientation_basis(
			command.new_assembly_grid_frame.orientation_index
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
	store_id: String = "player"
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


static func _upright_basis(aim_direction: Vector3) -> Basis:
	var up := Vector3.UP
	var forward := aim_direction - up * aim_direction.dot(up)
	if forward.length_squared() < 0.000001:
		forward = Vector3.FORWARD - up * Vector3.FORWARD.dot(up)
	forward = forward.normalized()
	if forward.length_squared() < 0.000001:
		forward = Vector3.FORWARD
	var right := forward.cross(up).normalized()
	forward = up.cross(right).normalized()
	return Basis(right, up, -forward).orthonormalized()


static func _dominant_grid_direction(direction: Vector3) -> Vector3i:
	var absolute := direction.abs()
	if absolute.x >= absolute.y and absolute.x >= absolute.z:
		return Vector3i.RIGHT if direction.x >= 0.0 else Vector3i.LEFT
	if absolute.y >= absolute.z:
		return Vector3i.UP if direction.y >= 0.0 else Vector3i.DOWN
	return Vector3i.BACK if direction.z >= 0.0 else Vector3i.FORWARD


static func _attach_snap_context(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	target: Dictionary,
	metadata: Dictionary
) -> Dictionary:
	if (
		metadata.has("locked_target_port_cell")
		and metadata.has("locked_snap_dir")
	):
		return {
			"target_port_cell": metadata["locked_target_port_cell"],
			"snap_dir": metadata["locked_snap_dir"],
			"assembly_world_transform": assembly.motion.transform,
		}
	var point := Vector3(target.get("point", Vector3.ZERO))
	var normal := Vector3(target.get("normal", Vector3.UP)).normalized()
	var local_normal := assembly.motion.transform.basis.inverse() * normal
	var snap_dir := _dominant_grid_direction(local_normal)
	var target_port_cell: Vector3i
	if point.is_finite() and normal.is_finite() and normal.length_squared() > 0.0:
		var local_point := assembly.motion.transform.affine_inverse() * (
			point + normal * SURFACE_EPSILON
		)
		target_port_cell = GridMetric.meters_to_cell_floor(local_point) - snap_dir
	elif metadata.has("element_id"):
		var target_element := world.get_element(int(metadata.get("element_id", 0)))
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
		"assembly_world_transform": assembly.motion.transform,
	}


static func _resolve_attach_origin(
	world: SimulationWorld,
	archetype: ElementArchetype,
	snap_context: Dictionary,
	orientation_index: int,
	assembly_id: int,
	store_id: String,
	_held_attach_pivot: Vector3 = Vector3(INF, INF, INF)
) -> Vector3i:
	var target_port_cell: Vector3i = snap_context["target_port_cell"]
	var snap_dir: Vector3i = snap_context["snap_dir"]
	var snap_origin := GridPoseUtil.snap_origin_without_pivot(
		archetype,
		target_port_cell,
		snap_dir,
		orientation_index
	)
	# Attach rotation is locked to the currently aimed face. Searching nearby
	# cells can bind to a different element in the same assembly, which makes a
	# rotated block visibly jump along a platform or enter its volume.
	return snap_origin


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
