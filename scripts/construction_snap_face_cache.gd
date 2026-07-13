class_name ConstructionSnapFaceCache
extends RefCounted

var generation := 0
var cache_rebuilds := 0
var last_faces_in_cache := 0

var _world: SimulationWorld
var _faces: Array[Dictionary] = []
var _faces_by_bucket: Dictionary = {}
var _assembly_signatures: Dictionary = {}
var _assembly_ids: Array[int] = []
var _anchored_assembly_ids: Dictionary = {}
var _initialized := false

const BUCKET_SIZE := 1.0


func bind_world(world: SimulationWorld) -> void:
	if _world == world:
		return
	_world = world
	invalidate()


func invalidate() -> void:
	generation += 1
	_faces.clear()
	_faces_by_bucket.clear()
	_assembly_signatures.clear()
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
	for assembly_id: int in live_assembly_ids:
		var assembly := _world.get_assembly_raw(assembly_id)
		if (
			assembly == null
			or _assembly_signatures.get(assembly_id, "") != _assembly_signature(assembly)
		):
			_rebuild_all(live_assembly_ids)
			_touch()
			return true
	last_faces_in_cache = _faces.size()
	return false


func faces() -> Array[Dictionary]:
	return _faces


func faces_in_aabb(bounds: AABB) -> Array[Dictionary]:
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
	_assembly_signatures.clear()
	_assembly_ids = assembly_ids.duplicate()
	_rebuild_anchor_map()
	for assembly_id: int in assembly_ids:
		_rebuild_assembly(assembly_id)
	return true


func _rebuild_assembly(assembly_id: int) -> void:
	_remove_assembly_faces(assembly_id)
	var assembly := _world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		_assembly_signatures.erase(assembly_id)
		return
	_assembly_signatures[assembly_id] = _assembly_signature(assembly)
	if not _anchored_assembly_ids.has(assembly_id):
		return
	var assembly_transform := assembly.motion.transform
	for element_id: int in assembly.element_ids:
		var element := _world.get_element(element_id)
		if element == null:
			continue
		var archetype := element.get_archetype()
		if archetype == null:
			continue
		for port: PortDefinition in archetype.ports:
			if not _is_structural_port(port):
				continue
			var world_point := _port_world_point(
				element,
				port,
				assembly_transform
			)
			var port_direction := _element_port_direction(element, port)
			var world_normal := (
				assembly_transform.basis * Vector3(port_direction).normalized()
			)
			_add_face({
				"assembly_id": assembly_id,
				"element_id": element.element_id,
				"port_id": port.port_id,
				"collider_local_cell": port.local_cell,
				"world_point": world_point,
				"world_normal": world_normal,
			})


func _remove_assembly_faces(assembly_id: int) -> void:
	var kept: Array[Dictionary] = []
	for face: Dictionary in _faces:
		if int(face.get("assembly_id", 0)) != assembly_id:
			kept.append(face)
	_faces = kept
	_rebuild_bucket_index()


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
	for port: PortDefinition in archetype.ports:
		if not _is_structural_port(port):
			continue
		var port_direction := _element_port_direction(element, port)
		_add_face({
			"assembly_id": assembly_id,
			"element_id": element.element_id,
			"port_id": port.port_id,
			"collider_local_cell": port.local_cell,
			"world_point": _port_world_point(
				element,
				port,
				assembly.motion.transform
			),
			"world_normal": (
				assembly.motion.transform.basis
				* Vector3(port_direction).normalized()
			),
		})


func _add_face(face: Dictionary) -> void:
	_faces.append(face)
	var bucket_key := _bucket_for_point(face["world_point"])
	if not _faces_by_bucket.has(bucket_key):
		_faces_by_bucket[bucket_key] = []
	_faces_by_bucket[bucket_key].append(face)


func _rebuild_bucket_index() -> void:
	_faces_by_bucket.clear()
	for face: Dictionary in _faces:
		var bucket_key := _bucket_for_point(face["world_point"])
		if not _faces_by_bucket.has(bucket_key):
			_faces_by_bucket[bucket_key] = []
		_faces_by_bucket[bucket_key].append(face)


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
	for joint: SimulationJoint in _world.list_joints():
		if (
			joint.kind == SimulationJoint.Kind.ANCHOR
			and not _anchored_assembly_ids.has(joint.assembly_id)
		):
			_anchored_assembly_ids[joint.assembly_id] = true


func _sorted_live_assembly_ids() -> Array[int]:
	var ids: Array[int] = []
	for assembly: SimulationAssembly in _world.list_assemblies():
		if not assembly.tombstoned:
			ids.append(assembly.assembly_id)
	ids.sort()
	return ids


func _assembly_signature(assembly: SimulationAssembly) -> String:
	var transform := assembly.motion.transform
	return "%d|%s|%s|%s|%s" % [
		assembly.topology_revision,
		transform.origin,
		transform.basis.x,
		transform.basis.y,
		transform.basis.z,
	]


static func _port_world_point(
	element: SimulationElement,
	port: PortDefinition,
	assembly_transform: Transform3D
) -> Vector3:
	var port_cell := _element_port_cell(element, port)
	var port_direction := _element_port_direction(element, port)
	var local_normal := Vector3(port_direction).normalized()
	var local_center := (
		Vector3(port_cell)
		+ Vector3(0.5, 0.5, 0.5)
		+ local_normal * 0.5
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


static func _is_structural_port(port: PortDefinition) -> bool:
	return (
		port != null
		and port.kind == PortDefinition.Kind.MECHANICAL
		and port.compatibility_tags.has("structural")
	)
