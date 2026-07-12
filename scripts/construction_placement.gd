class_name ConstructionPlacement
extends RefCounted

const SURFACE_EPSILON := 0.05


static func plan(
	world: SimulationWorld,
	target: Dictionary,
	archetype: ElementArchetype,
	orientation_index: int,
	store_id: String = "player"
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
	var target_kind := StringName(target.get("target_kind", &""))
	if target_kind == InteractionHit.KIND_SIMULATION_ELEMENT:
		var metadata: Dictionary = target.get("metadata", {})
		var assembly_id := int(metadata.get("assembly_id", 0))
		var assembly := world.get_assembly(assembly_id)
		if assembly == null or assembly.tombstoned:
			return _failed(StructuralCommandResult.REASON_INVALID_REFERENCE)
		var point := Vector3(target.get("point", Vector3.ZERO))
		var normal := Vector3(target.get("normal", Vector3.UP)).normalized()
		command.assembly_id = assembly.assembly_id
		command.expected_assembly_revision = assembly.topology_revision
		var target_element := world.get_element(
			int(metadata.get("element_id", 0))
		)
		if target_element != null and metadata.has("collider_local_cell"):
			var local_normal := (
				assembly.motion.transform.basis.inverse() * normal
			)
			var collider_local_cell: Vector3i = metadata.get(
				"collider_local_cell",
				Vector3i.ZERO
			)
			var target_cell := (
				target_element.origin_cell
				+ OrientationUtil.rotate_cell(
					collider_local_cell,
					target_element.orientation_index
				)
			)
			command.origin_cell = (
				target_cell + _dominant_grid_direction(local_normal)
			)
		else:
			var local_point := assembly.motion.transform.affine_inverse() * (
				point + normal * SURFACE_EPSILON
			)
			command.origin_cell = Vector3i(
				floori(local_point.x),
				floori(local_point.y),
				floori(local_point.z)
			)
		world_transform = (
			assembly.motion.transform
			* GridPoseUtil.element_local_transform(
				command.origin_cell,
				command.orientation_index
			)
		)
	elif target_kind == InteractionHit.KIND_VOXEL:
		if archetype.archetype_id != "foundation":
			return _failed(StructuralCommandResult.REASON_ANCHOR_REQUIRED)
		var normal := Vector3(target.get("normal", Vector3.UP)).normalized()
		var metadata: Dictionary = target.get("metadata", {})
		var aim_direction := Vector3(
			metadata.get("aim_direction", Vector3.FORWARD)
		)
		var basis := _surface_basis(normal, aim_direction)
		assembly_world_transform = Transform3D(
			basis,
			Vector3(target.get("point", Vector3.ZERO))
		)
		world_transform = (
			assembly_world_transform
			* GridPoseUtil.element_local_transform(
				Vector3i.ZERO,
				command.orientation_index
			)
		)
		command.assembly_id = 0
		command.origin_cell = Vector3i.ZERO
		command.new_assembly_grid_frame = (
			GridSpawnUtil.grid_frame_from_transform(assembly_world_transform)
		)
	else:
		return _failed(StructuralCommandResult.REASON_INVALID_TARGET)

	var validation := world.preview_place_element(command)
	return {
		"valid": validation.is_ok(),
		"reason": validation.reason,
		"data": validation.data,
		"command": command,
		"world_transform": world_transform,
		"assembly_world_transform": (
			assembly_world_transform
			if command.assembly_id == 0
			else Transform3D.IDENTITY
		),
		"archetype": archetype,
	}


static func _surface_basis(up_direction: Vector3, aim_direction: Vector3) -> Basis:
	var up := up_direction.normalized()
	var forward := (
		aim_direction - up * aim_direction.dot(up)
	).normalized()
	if forward.length_squared() < 0.000001:
		forward = (
			Vector3.FORWARD - up * Vector3.FORWARD.dot(up)
		).normalized()
	if forward.length_squared() < 0.000001:
		forward = Vector3.RIGHT
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


static func _failed(reason: StringName) -> Dictionary:
	return {
		"valid": false,
		"reason": reason,
		"data": {},
		"command": null,
		"world_transform": Transform3D.IDENTITY,
		"assembly_world_transform": Transform3D.IDENTITY,
		"archetype": null,
	}
