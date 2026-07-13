class_name IndustryPortProjection
extends Node3D
## Gameplay port markers for electric + cargo industry ports.

const MARKER_PREFIX := "IndustryPort_"
const FACE_OFFSET := GridMetric.HALF_CELL_SIZE_M - 0.02
const DISC_RADIUS := 0.14
const ARROW_LENGTH := 0.18
const ARROW_RADIUS := 0.035

const COLOR_ELECTRIC := Color(0.95, 0.78, 0.16, 0.92)
const COLOR_CARGO := Color(0.18, 0.82, 0.88, 0.92)
const COLOR_DIM := Color(0.55, 0.58, 0.62, 0.45)
const COLOR_HIGHLIGHT := Color(0.35, 0.98, 0.55, 0.98)
const COLOR_COMPATIBLE := Color(0.98, 0.92, 0.28, 0.98)

var _world: SimulationWorld
var _physics_projection: SimulationPhysicsProjection
var _markers_root: Node3D
var _materials: Dictionary = {}
var _marker_nodes: Dictionary = {}
var _disc_mesh: CylinderMesh
var _arrow_mesh: CylinderMesh
var _visible := false
var _highlight_element_ids: Dictionary = {}
var _compatible_ports: Dictionary = {}
var _event_bound := false
var _state_signature := ""
var _rebuild_count := 0


func bind(
	world: SimulationWorld,
	physics_projection: SimulationPhysicsProjection
) -> void:
	if _world != null and _event_bound:
		_world.structural_event.disconnect(_on_structural_event)
		_event_bound = false
	_world = world
	_physics_projection = physics_projection
	_state_signature = ""
	if _markers_root == null:
		_markers_root = Node3D.new()
		_markers_root.name = "IndustryPortMarkers"
		add_child(_markers_root)
	_create_materials()
	_create_meshes()
	if _world != null and not _event_bound:
		_world.structural_event.connect(_on_structural_event)
		_event_bound = true
	_apply_marker_state()


func set_presentation_state(
	visible: bool,
	highlight_element_ids: Array = [],
	compatible_ports: Array = []
) -> void:
	var next_element_ids: Dictionary = {}
	for element_id_variant: Variant in highlight_element_ids:
		var element_id := int(element_id_variant)
		if element_id > 0:
			next_element_ids[element_id] = true
		if next_element_ids.size() >= 2:
			break
	var next_compatible_ports: Dictionary = {}
	for entry_variant: Variant in compatible_ports:
		if entry_variant is Dictionary:
			var entry: Dictionary = entry_variant
			var key := _port_key(
				int(entry.get("element_id", 0)),
				str(entry.get("port_id", ""))
			)
			if not key.is_empty():
				next_compatible_ports[key] = true
	var next_signature := _presentation_signature(
		visible,
		next_element_ids,
		next_compatible_ports
	)
	if next_signature == _state_signature:
		return
	_visible = visible
	_highlight_element_ids = next_element_ids
	_compatible_ports = next_compatible_ports
	_state_signature = next_signature
	_apply_marker_state()


func rebuild_all() -> void:
	_apply_marker_state()


func marker_count() -> int:
	return _marker_nodes.size()


func visible_element_count() -> int:
	return _highlight_element_ids.size() if _visible else 0


func rebuild_count() -> int:
	return _rebuild_count


func _apply_marker_state() -> void:
	if _world == null or _markers_root == null:
		return
	_rebuild_count += 1
	var required: Dictionary = {}
	if _visible:
		for element_id_variant: Variant in _highlight_element_ids.keys():
			var element_id := int(element_id_variant)
			var element := _world.get_element(element_id)
			if element == null:
				continue
			for port: PortDefinition in IndustryPortUtil.list_industry_ports(element):
				var key := _port_key(element_id, port.port_id)
				required[key] = true
				_update_or_create_marker(key, element, port)
	for key_variant: Variant in _marker_nodes.keys():
		var key := str(key_variant)
		if required.has(key):
			continue
		var marker := _marker_nodes[key] as Node3D
		_marker_nodes.erase(key)
		if is_instance_valid(marker):
			var parent := marker.get_parent()
			if parent != null:
				parent.remove_child(marker)
			marker.queue_free()


func _update_or_create_marker(
	key: String,
	element: SimulationElement,
	port: PortDefinition
) -> void:
	var body := _physics_projection.get_physics_body(element.assembly_id)
	if body == null:
		return
	var marker := _marker_nodes.get(key) as Node3D
	if marker == null or not is_instance_valid(marker):
		marker = _make_port_marker(element, port)
		if marker == null:
			return
		_marker_nodes[key] = marker
		body.add_child(marker)
	_update_marker(marker, element, port)


func _make_port_marker(
	element: SimulationElement,
	port: PortDefinition
) -> Node3D:
	var body := _physics_projection.get_physics_body(element.assembly_id)
	if body == null:
		return null
	var root := Node3D.new()
	root.name = "%s%d_%s" % [MARKER_PREFIX, element.element_id, port.port_id]
	var disc := MeshInstance3D.new()
	disc.name = "Disc"
	disc.mesh = _disc_mesh
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(disc)
	var arrow := MeshInstance3D.new()
	arrow.name = "Arrow"
	arrow.mesh = _arrow_mesh
	arrow.position = Vector3(0.0, ARROW_LENGTH * 0.5 + 0.01, 0.0)
	arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(arrow)
	return root


func _update_marker(
	marker: Node3D,
	element: SimulationElement,
	port: PortDefinition
) -> void:
	var body := _physics_projection.get_physics_body(element.assembly_id)
	if body == null:
		return
	if marker.get_parent() != body:
		marker.reparent(body, false)
	marker.transform = IndustryPortUtil.port_marker_local_transform(
		element,
		port,
		FACE_OFFSET
	)
	var material := _material_for(element, port)
	(marker.get_node("Disc") as MeshInstance3D).material_override = material
	(marker.get_node("Arrow") as MeshInstance3D).material_override = material


func _material_for(
	element: SimulationElement,
	port: PortDefinition
) -> StandardMaterial3D:
	var key := _port_key(element.element_id, port.port_id)
	if _compatible_ports.has(key):
		return _materials["compatible"]
	match port.kind:
		PortDefinition.Kind.CARGO:
			return _materials["cargo"]
		PortDefinition.Kind.ELECTRIC:
			return _materials["electric"]
		_:
			return _materials["dim"]


func _port_key(element_id: int, port_id: String) -> String:
	if element_id <= 0 or port_id.is_empty():
		return ""
	return "%d|%s" % [element_id, port_id]


func _on_structural_event(event: Dictionary) -> void:
	if not _visible:
		return
	var kind := StringName(event.get("kind", &""))
	if kind == &"world_restored":
		_apply_marker_state()
		return
	var event_element_id := int(event.get("element_id", 0))
	var placed_element_id := int(event.get("placed_element_id", 0))
	var removed_element_id := int(event.get("removed_element_id", 0))
	if (
		(event_element_id > 0 and _highlight_element_ids.has(event_element_id))
		or (placed_element_id > 0 and _highlight_element_ids.has(placed_element_id))
		or (
			removed_element_id > 0
			and _highlight_element_ids.has(removed_element_id)
		)
		or _event_affects_visible_assembly(event)
	):
		_apply_marker_state()


func _event_affects_visible_assembly(event: Dictionary) -> bool:
	var assembly_ids: Dictionary = {}
	for field: String in [
		"assembly_id",
		"survivor_assembly_id",
		"loser_assembly_id",
	]:
		var assembly_id := int(event.get(field, 0))
		if assembly_id > 0:
			assembly_ids[assembly_id] = true
	if assembly_ids.is_empty():
		return false
	for element_id_variant: Variant in _highlight_element_ids.keys():
		var element := _world.get_element(int(element_id_variant))
		if element != null and assembly_ids.has(element.assembly_id):
			return true
	return false


func _create_materials() -> void:
	if not _materials.is_empty():
		return
	_materials["electric"] = _marker_material(COLOR_ELECTRIC)
	_materials["cargo"] = _marker_material(COLOR_CARGO)
	_materials["dim"] = _marker_material(COLOR_DIM)
	_materials["compatible"] = _marker_material(COLOR_COMPATIBLE, 0.65)
	_materials["highlight"] = _marker_material(COLOR_HIGHLIGHT, 0.65)


func _create_meshes() -> void:
	if _disc_mesh == null:
		_disc_mesh = CylinderMesh.new()
		_disc_mesh.top_radius = DISC_RADIUS
		_disc_mesh.bottom_radius = DISC_RADIUS
		_disc_mesh.height = 0.02
		_disc_mesh.radial_segments = 12
	if _arrow_mesh == null:
		_arrow_mesh = CylinderMesh.new()
		_arrow_mesh.top_radius = ARROW_RADIUS
		_arrow_mesh.bottom_radius = ARROW_RADIUS
		_arrow_mesh.height = ARROW_LENGTH
		_arrow_mesh.radial_segments = 6


func _presentation_signature(
	visible: bool,
	element_ids: Dictionary,
	compatible_ports: Dictionary
) -> String:
	var sorted_element_ids: Array = element_ids.keys()
	sorted_element_ids.sort()
	var sorted_ports: Array = compatible_ports.keys()
	sorted_ports.sort()
	return "%s|%s|%s" % [visible, sorted_element_ids, sorted_ports]


func _marker_material(color: Color, emission_scale: float = 0.35) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b, 1.0)
	material.emission_energy_multiplier = emission_scale
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
