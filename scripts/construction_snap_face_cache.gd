class_name ConstructionSnapFaceCache
extends RefCounted

var generation := 0
var cache_rebuilds := 0
var last_faces_in_cache := 0

var _world: SimulationWorld
var _faces: Array[Dictionary] = []
var _faces_by_bucket: Dictionary = {}
var _faces_by_assembly: Dictionary = {}
## assembly_id -> topology_revision only (structure). Motion never invalidates this.
var _assembly_topology: Dictionary = {}
## assembly_id -> last applied pose signature for world_point sync (no generation bump).
var _pose_signatures: Dictionary = {}
var _assembly_ids: Array[int] = []
var _anchored_assembly_ids: Dictionary = {}
var _initialized := false

const BUCKET_SIZE := GridMetric.CELL_SIZE_M
## Pose sync threshold. Must stay well above physics float-jitter on anchored
## bases: a 1mm eps caused ~15 pose-rebuilds/s × ~40ms while walking/aiming
## with build tool (no ghost / miss path). Half-cell still tracks real moves.
const MOTION_ORIGIN_EPS_M := GridMetric.HALF_CELL_SIZE_M
const MOTION_BASIS_EPS := 0.05


func bind_world(world: SimulationWorld) -> void:
	if _world == world:
		return
	_world = world
	invalidate()


func invalidate() -> void:
	generation += 1
	_faces.clear()
	_faces_by_bucket.clear()
	_faces_by_assembly.clear()
	_assembly_topology.clear()
	_pose_signatures.clear()
	_assembly_ids.clear()
	_anchored_assembly_ids.clear()
	last_faces_in_cache = 0
	_initialized = false


func ensure_current() -> bool:
	if _world == null:
		_faces.clear()
		last_faces_in_cache = 0
		return false
	if not _initialized:
		_rebuild_all(_sorted_live_assembly_ids())
		cache_rebuilds += 1
		_initialized = true
		last_faces_in_cache = _faces.size()
		return true
	var live_assembly_ids := _sorted_live_assembly_ids()
	if live_assembly_ids != _assembly_ids:
		_rebuild_all(live_assembly_ids)
		_touch()
		return true
	var dirty_topology: Array[int] = []
	for assembly_id: int in live_assembly_ids:
		var assembly := _world.get_assembly_raw(assembly_id)
		if assembly == null:
			dirty_topology.append(assembly_id)
			continue
		var prev_topology: int = int(_assembly_topology.get(assembly_id, -1))
		if prev_topology != assembly.topology_revision:
			dirty_topology.append(assembly_id)
	# Attach permission is dynamic (a rover parks / drives away), not only
	# structural: re-check per resolve and rebuild faces of assemblies whose
	# anchored state flipped. A parked rover becomes magnetic; a departing one
	# drops out of the cache instead of dragging stale faces around.
	for assembly_id: int in live_assembly_ids:
		var anchored_now := _world.construction_attach_allowed(assembly_id)
		if anchored_now == _anchored_assembly_ids.has(assembly_id):
			continue
		if anchored_now:
			_anchored_assembly_ids[assembly_id] = true
		else:
			_anchored_assembly_ids.erase(assembly_id)
		if not dirty_topology.has(assembly_id):
			dirty_topology.append(assembly_id)
	var topology_changed := not dirty_topology.is_empty()
	if topology_changed:
		for assembly_id: int in dirty_topology:
			_rebuild_assembly(assembly_id)
		_touch()
	# Motion never rebuilds face topology / never bumps generation — only refreshes
	# world_point from stored local poses (avoids preview resolve thrash).
	_sync_face_world_poses()
	last_faces_in_cache = _faces.size()
	return topology_changed


func faces() -> Array[Dictionary]:
	_sync_face_world_poses()
	return _faces


func faces_in_aabb(bounds: AABB) -> Array[Dictionary]:
	_sync_face_world_poses()
	var result: Array[Dictionary] = []
	var min_bucket := _bucket_for_point(bounds.position)
	var max_bucket := _bucket_for_point(bounds.end)
	for x: int in range(min_bucket.x, max_bucket.x + 1):
		for y: int in range(min_bucket.y, max_bucket.y + 1):
			for z: int in range(min_bucket.z, max_bucket.z + 1):
				var bucket: Array = _faces_by_bucket.get(
					Vector3i(x, y, z),
					[]
				)
				for face: Dictionary in bucket:
					result.append(face)
	return result


func apply_structural_event(event: Dictionary) -> void:
	if _world == null:
		return
	var kind := StringName(event.get("kind", &""))
	if kind == &"world_restored" or kind == &"assembly_split" or kind == &"assembly_merged":
		invalidate()
		return
	if not _initialized:
		invalidate()
		return
	var assembly_id := int(event.get("assembly_id", 0))
	if assembly_id == 0:
		invalidate()
		return
	if kind == &"assembly_spawned":
		_rebuild_anchor_map()
		_rebuild_assembly(assembly_id)
		_touch()
		return
	if kind == &"assembly_changed" and event.has("placed_element_id"):
		_add_element_faces(
			assembly_id,
			int(event["placed_element_id"])
		)
		_touch()
		return
	if kind == &"assembly_removed":
		invalidate()
		return
	invalidate()


func is_assembly_anchored(assembly_id: int) -> bool:
	return _anchored_assembly_ids.has(assembly_id)


func _rebuild_all(assembly_ids: Array[int]) -> bool:
	_faces.clear()
	_faces_by_bucket.clear()
	_faces_by_assembly.clear()
	_assembly_topology.clear()
	_pose_signatures.clear()
	_assembly_ids = assembly_ids.duplicate()
	_rebuild_anchor_map()
	for assembly_id: int in assembly_ids:
		_rebuild_assembly(assembly_id)
	return true


func _rebuild_assembly(assembly_id: int) -> void:
	_remove_assembly_faces(assembly_id)
	var assembly := _world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		_assembly_topology.erase(assembly_id)
		_pose_signatures.erase(assembly_id)
		return
	_assembly_topology[assembly_id] = assembly.topology_revision
	_pose_signatures[assembly_id] = _capture_pose_signature(assembly)
	if not _anchored_assembly_ids.has(assembly_id):
		return
	for element_id: int in assembly.element_ids:
		var element := _world.get_element(element_id)
		if element == null:
			continue
		var archetype := element.get_archetype()
		if archetype == null:
			continue
		var assembly_transform := (
			_world.element_group_transform(element.element_id)
		)
		for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
			GridSurfaceUtil.get_surface_descriptors(
				archetype,
				element.orientation_index
			)
		):
			var local_pose := _surface_face_local_pose(element, descriptor)
			_add_face({
				"assembly_id": assembly_id,
				"element_id": element.element_id,
				"port_id": descriptor.structural_id,
				"collider_local_cell": descriptor.local_cell,
				"local_point": local_pose["point"],
				"local_normal": local_pose["normal"],
				"world_point": assembly_transform * local_pose["point"],
				"world_normal": (
					assembly_transform.basis * local_pose["normal"]
				).normalized(),
			})


func _remove_assembly_faces(assembly_id: int) -> void:
	var assembly_faces: Array = _faces_by_assembly.get(assembly_id, [])
	for face: Dictionary in assembly_faces:
		_unbucket_face(face)
	_faces_by_assembly.erase(assembly_id)
	if assembly_faces.is_empty():
		return
	var kept: Array[Dictionary] = []
	for face: Dictionary in _faces:
		if int(face.get("assembly_id", 0)) != assembly_id:
			kept.append(face)
	_faces = kept


func _add_element_faces(assembly_id: int, element_id: int) -> void:
	var assembly := _world.get_assembly_raw(assembly_id)
	var element := _world.get_element(element_id)
	if (
		assembly == null
		or assembly.tombstoned
		or element == null
		or not _anchored_assembly_ids.has(assembly_id)
	):
		return
	var archetype := element.get_archetype()
	if archetype == null:
		return
	var assembly_transform := (
		_world.element_group_transform(element.element_id)
	)
	for descriptor: GridSurfaceUtil.SurfaceFaceDescriptor in (
		GridSurfaceUtil.get_surface_descriptors(
			archetype,
			element.orientation_index
		)
	):
		var local_pose := _surface_face_local_pose(element, descriptor)
		_add_face({
			"assembly_id": assembly_id,
			"element_id": element.element_id,
			"port_id": descriptor.structural_id,
			"collider_local_cell": descriptor.local_cell,
			"local_point": local_pose["point"],
			"local_normal": local_pose["normal"],
			"world_point": assembly_transform * local_pose["point"],
			"world_normal": (
				assembly_transform.basis * local_pose["normal"]
			).normalized(),
		})
	_assembly_topology[assembly_id] = assembly.topology_revision
	_pose_signatures[assembly_id] = _capture_pose_signature(assembly)


func _add_face(face: Dictionary) -> void:
	_faces.append(face)
	var assembly_id := int(face.get("assembly_id", 0))
	if not _faces_by_assembly.has(assembly_id):
		_faces_by_assembly[assembly_id] = []
	(_faces_by_assembly[assembly_id] as Array).append(face)
	_bucket_face(face)


func _bucket_face(face: Dictionary) -> void:
	var bucket_key := _bucket_for_point(face["world_point"])
	face["_bucket"] = bucket_key
	if not _faces_by_bucket.has(bucket_key):
		_faces_by_bucket[bucket_key] = []
	(_faces_by_bucket[bucket_key] as Array).append(face)


func _unbucket_face(face: Dictionary) -> void:
	var bucket_key: Variant = face.get("_bucket")
	if bucket_key == null:
		bucket_key = _bucket_for_point(face["world_point"])
	var bucket: Array = _faces_by_bucket.get(bucket_key, [])
	bucket.erase(face)
	if bucket.is_empty():
		_faces_by_bucket.erase(bucket_key)
	else:
		_faces_by_bucket[bucket_key] = bucket


func _sync_face_world_poses() -> void:
	if _world == null or _faces_by_assembly.is_empty():
		return
	var needs_rebucket := false
	for assembly_id_variant: Variant in _faces_by_assembly.keys():
		var assembly_id := int(assembly_id_variant)
		var assembly := _world.get_assembly_raw(assembly_id)
		if assembly == null or assembly.tombstoned:
			continue
		# Frozen / terrain-anchored bases do not need continuous world_point
		# refresh for snap — topology rebuild already wrote correct poses.
		# Real teleports still go through structural events or unfreeze.
		if (
			assembly.motion.frozen
			or _world.assembly_has_anchor(assembly_id)
		):
			continue
		var current := _capture_pose_signature(assembly)
		var previous: Variant = _pose_signatures.get(assembly_id)
		if (
			previous is Dictionary
			and _motion_signature_close(previous, current)
		):
			continue
		_refresh_assembly_world_points(assembly_id)
		_pose_signatures[assembly_id] = current
		needs_rebucket = true
	if needs_rebucket:
		_rebuild_bucket_index()


func _refresh_assembly_world_points(assembly_id: int) -> void:
	var assembly_faces: Array = _faces_by_assembly.get(assembly_id, [])
	var assembly := _world.get_assembly_raw(assembly_id)
	# Single body-group: one root transform for every face element.
	var shared_xf := Transform3D.IDENTITY
	var use_shared := (
		assembly != null
		and not assembly.tombstoned
		and assembly.motion != null
		and _world.assembly_is_single_body_group(assembly_id)
	)
	if use_shared:
		shared_xf = assembly.motion.transform
	for face: Dictionary in assembly_faces:
		var element_id := int(face.get("element_id", 0))
		if _world.get_element(element_id) == null:
			continue
		var xf := (
			shared_xf
			if use_shared
			else _world.element_group_transform(element_id)
		)
		var local_point: Vector3 = face.get("local_point", Vector3.ZERO)
		var local_normal: Vector3 = face.get("local_normal", Vector3.UP)
		face["world_point"] = xf * local_point
		face["world_normal"] = (xf.basis * local_normal).normalized()


func _rebuild_bucket_index() -> void:
	_faces_by_bucket.clear()
	for face: Dictionary in _faces:
		_bucket_face(face)


func _touch() -> void:
	generation += 1
	cache_rebuilds += 1
	last_faces_in_cache = _faces.size()


static func _bucket_for_point(point: Vector3) -> Vector3i:
	return Vector3i(
		floori(point.x / BUCKET_SIZE),
		floori(point.y / BUCKET_SIZE),
		floori(point.z / BUCKET_SIZE)
	)


func _rebuild_anchor_map() -> void:
	_anchored_assembly_ids.clear()
	if _world == null:
		return
	for assembly: SimulationAssembly in _world.list_assemblies():
		if assembly == null or assembly.tombstoned:
			continue
		if _world.construction_attach_allowed(assembly.assembly_id):
			_anchored_assembly_ids[assembly.assembly_id] = true


func _sorted_live_assembly_ids() -> Array[int]:
	var ids: Array[int] = []
	for assembly: SimulationAssembly in _world.list_assemblies():
		if not assembly.tombstoned:
			ids.append(assembly.assembly_id)
	ids.sort()
	return ids


func _capture_pose_signature(assembly: SimulationAssembly) -> Dictionary:
	var transform := assembly.motion.transform
	var groups: Array = []
	var group_ids: Array = assembly.body_group_motions.keys()
	group_ids.sort()
	for group_id_variant: Variant in group_ids:
		var group_motion: AssemblyMotionState = (
			assembly.body_group_motions.get(group_id_variant)
		)
		if group_motion == null:
			continue
		var gt := group_motion.transform
		groups.append({
			"id": int(group_id_variant),
			"origin": gt.origin,
			"basis_y": gt.basis.y,
		})
	return {
		"origin": transform.origin,
		"basis_x": transform.basis.x,
		"basis_y": transform.basis.y,
		"basis_z": transform.basis.z,
		"groups": groups,
	}


func _motion_signature_close(a: Dictionary, b: Dictionary) -> bool:
	if not _vec_close(
		a.get("origin", Vector3.ZERO),
		b.get("origin", Vector3.ZERO),
		MOTION_ORIGIN_EPS_M
	):
		return false
	if not _vec_close(a.get("basis_x", Vector3.ZERO), b.get("basis_x", Vector3.ZERO), MOTION_BASIS_EPS):
		return false
	if not _vec_close(a.get("basis_y", Vector3.ZERO), b.get("basis_y", Vector3.ZERO), MOTION_BASIS_EPS):
		return false
	if not _vec_close(a.get("basis_z", Vector3.ZERO), b.get("basis_z", Vector3.ZERO), MOTION_BASIS_EPS):
		return false
	var groups_a: Array = a.get("groups", [])
	var groups_b: Array = b.get("groups", [])
	if groups_a.size() != groups_b.size():
		return false
	for i: int in range(groups_a.size()):
		var ga: Dictionary = groups_a[i]
		var gb: Dictionary = groups_b[i]
		if int(ga.get("id", -1)) != int(gb.get("id", -1)):
			return false
		if not _vec_close(
			ga.get("origin", Vector3.ZERO),
			gb.get("origin", Vector3.ZERO),
			MOTION_ORIGIN_EPS_M
		):
			return false
		if not _vec_close(
			ga.get("basis_y", Vector3.ZERO),
			gb.get("basis_y", Vector3.ZERO),
			MOTION_BASIS_EPS
		):
			return false
	return true


static func _vec_close(a: Vector3, b: Vector3, eps: float) -> bool:
	return (
		absf(a.x - b.x) <= eps
		and absf(a.y - b.y) <= eps
		and absf(a.z - b.z) <= eps
	)


static func _surface_face_local_pose(
	element: SimulationElement,
	descriptor: GridSurfaceUtil.SurfaceFaceDescriptor
) -> Dictionary:
	var grid_cell := (
		element.origin_cell
		+ OrientationUtil.rotate_cell(
			descriptor.local_cell,
			element.orientation_index
		)
	)
	var grid_dir := OrientationUtil.rotate_direction(
		OrientationUtil.face_to_vector(descriptor.local_face),
		element.orientation_index
	)
	var local_normal := Vector3(grid_dir).normalized()
	var local_point := (
		GridMetric.cell_center_meters(grid_cell)
		+ local_normal * GridMetric.HALF_CELL_SIZE_M
	)
	return {
		"point": local_point,
		"normal": local_normal,
	}


static func _surface_face_world_point(
	element: SimulationElement,
	descriptor: GridSurfaceUtil.SurfaceFaceDescriptor,
	assembly_transform: Transform3D
) -> Vector3:
	var local_pose := _surface_face_local_pose(element, descriptor)
	return assembly_transform * local_pose["point"]


static func _port_world_point(
	element: SimulationElement,
	port: PortDefinition,
	assembly_transform: Transform3D
) -> Vector3:
	var port_cell := _element_port_cell(element, port)
	var port_direction := _element_port_direction(element, port)
	var local_normal := Vector3(port_direction).normalized()
	var local_center := (
		GridMetric.cell_center_meters(port_cell)
		+ local_normal * GridMetric.HALF_CELL_SIZE_M
	)
	return assembly_transform * local_center


static func _element_port_cell(
	element: SimulationElement,
	port: PortDefinition
) -> Vector3i:
	return (
		element.origin_cell
		+ OrientationUtil.rotate_cell(
			port.local_cell,
			element.orientation_index
		)
	)


static func _element_port_direction(
	element: SimulationElement,
	port: PortDefinition
) -> Vector3i:
	return OrientationUtil.rotate_direction(
		OrientationUtil.face_to_vector(port.local_face),
		element.orientation_index
	)
