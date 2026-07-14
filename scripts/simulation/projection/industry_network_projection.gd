class_name IndustryNetworkProjection
extends Node3D
## Electric wire mesh presentation sourced from authoritative `electric_links[]`.
## Cargo pipes render as placed element geometry only (INDUSTRY-V1 § Wire presentation).

const WIRE_MESH_PREFIX := "IndustryWire_"
const WIRE_RADIUS := 0.022
## Aim-collider radius: fatter than the visual so the grinder can target a wire.
const WIRE_AIM_RADIUS := 0.09
## Physics layer 4 — interaction-ray only; nothing moves or collides on it.
const WIRE_COLLISION_LAYER := 8
## Decorative sag per polyline span (fraction of span length, capped). Kept
## shallow so floor/wall runs pinned by скобы do not sink into the surface.
const WIRE_SAG_FRACTION := 0.04
const WIRE_SAG_MAX_M := 0.15
const WIRE_SAG_SUBDIVISIONS := 4
## Black insulated cable with a slight sheen.
const WIRE_COLOR := Color(0.07, 0.07, 0.08, 1.0)
## Dormant wire (endpoint damaged/incomplete or cable overstretched): the link
## persists in state and keeps rendering, faded, until the condition clears.
const WIRE_DORMANT_COLOR := Color(0.46, 0.44, 0.4, 1.0)

var _world: SimulationWorld
var _physics_projection: SimulationPhysicsProjection
var _links_root: Node3D
var _wire_material: StandardMaterial3D
var _wire_dormant_material: StandardMaterial3D
var _cached_network_revision := -1
var _event_bound := false


func bind(
	world: SimulationWorld,
	physics_projection: SimulationPhysicsProjection
) -> void:
	if _world != null and _event_bound:
		_world.structural_event.disconnect(_on_structural_event)
	_world = world
	_physics_projection = physics_projection
	if _links_root == null:
		_links_root = Node3D.new()
		_links_root.name = "ElectricWireLinks"
		add_child(_links_root)
	if _wire_material == null:
		_wire_material = _create_wire_material()
	if _wire_dormant_material == null:
		_wire_dormant_material = _create_dormant_material()
	if _world != null and not _event_bound:
		_world.structural_event.connect(_on_structural_event)
		_event_bound = true
	rebuild_all()


func rebuild_all() -> void:
	if _world == null or _links_root == null:
		return
	for child: Node in _links_root.get_children():
		child.queue_free()
	for link: IndustryElectricLink in _world.get_industry_network().list_links():
		var wire := _make_wire_body(link)
		if wire != null:
			_links_root.add_child(wire)
	_cached_network_revision = _world.get_industry_network_revision()


func _process(_delta: float) -> void:
	if _world == null:
		return
	var revision := _world.get_industry_network_revision()
	if revision != _cached_network_revision:
		rebuild_all()
		return
	for child: Node in _links_root.get_children():
		var body := child as StaticBody3D
		if body == null:
			continue
		var link_id := int(body.get_meta("electric_link_id", 0))
		var link := _world.get_industry_network().get_link(link_id)
		if link != null:
			_update_wire_body(body, link)


func _on_structural_event(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored", &"electric_link_added", &"electric_link_removed":
			rebuild_all()
		&"assembly_spawned", &"assembly_changed", &"assembly_removed", &"assembly_split", &"assembly_merged":
			rebuild_all()
		&"element_state_changed":
			rebuild_all()


## Wires are StaticBody3D on an interaction-only layer so the aim ray can
## target them (grinder → disconnect_network). They collide with nothing.
## A wire renders as a polyline: port anchor → routed скобы → port anchor,
## each span subdivided with a light catenary-style sag.
func _make_wire_body(link: IndustryElectricLink) -> StaticBody3D:
	var element_a := _world.get_element(link.element_a)
	var element_b := _world.get_element(link.element_b)
	if element_a == null or element_b == null:
		return null
	var body := StaticBody3D.new()
	body.name = "%s%d" % [WIRE_MESH_PREFIX, link.link_id]
	body.collision_layer = WIRE_COLLISION_LAYER
	body.collision_mask = 0
	body.set_meta("electric_link_id", link.link_id)
	body.set_meta(
		"interaction_metadata",
		{"electric_link_id": link.link_id}
	)
	_update_wire_body(body, link)
	return body


func _update_wire_body(
	body: StaticBody3D,
	link: IndustryElectricLink
) -> void:
	var points := _wire_points(link)
	if points.size() < 2:
		body.visible = false
		_set_segments_disabled(body, true)
		return
	body.visible = true
	var display := _display_points(points)
	var segment_count := display.size() - 1
	_ensure_wire_segments(body, segment_count)
	_set_segments_disabled(body, false)
	var material := (
		_wire_material
		if IndustryElectricPortUtil.link_still_valid(_world, link)
		else _wire_dormant_material
	)
	for index: int in range(segment_count):
		var start := display[index]
		var end := display[index + 1]
		var delta := end - start
		var length := delta.length()
		var mesh_instance := body.get_node("Mesh%d" % index) as MeshInstance3D
		var collision := body.get_node("Col%d" % index) as CollisionShape3D
		if length <= 0.01:
			mesh_instance.visible = false
			collision.disabled = true
			continue
		mesh_instance.visible = true
		collision.disabled = false
		mesh_instance.material_override = material
		# Capsule ends overlap into neighbouring segments, so bends read as one
		# continuous cable instead of tearing between straight pieces.
		var capsule_mesh := mesh_instance.mesh as CapsuleMesh
		if capsule_mesh != null:
			capsule_mesh.height = length + WIRE_RADIUS * 2.0
		var capsule := collision.shape as CapsuleShape3D
		if capsule != null:
			capsule.height = maxf(length, WIRE_AIM_RADIUS * 2.1)
		var transform := Transform3D(
			_wire_basis(delta / length),
			(start + end) * 0.5
		)
		mesh_instance.global_transform = transform
		collision.global_transform = transform


## Authoritative polyline: anchor_a → link.waypoints → anchor_b.
func _wire_points(link: IndustryElectricLink) -> PackedVector3Array:
	var element_a := _world.get_element(link.element_a)
	var element_b := _world.get_element(link.element_b)
	if element_a == null or element_b == null:
		return PackedVector3Array()
	var points := PackedVector3Array()
	points.append(
		IndustryElectricPortUtil.port_anchor_world_position(
			_world,
			element_a,
			link.port_a
		)
	)
	points.append_array(link.waypoints)
	points.append(
		IndustryElectricPortUtil.port_anchor_world_position(
			_world,
			element_b,
			link.port_b
		)
	)
	return points


## Decorative sag: each span is subdivided and dipped parabolically. The dip
## scales with the horizontal share of the span so vertical runs stay straight.
func _display_points(points: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.append(points[0])
	for span_index: int in range(points.size() - 1):
		var start := points[span_index]
		var end := points[span_index + 1]
		var span := end - start
		var length := span.length()
		var sag := 0.0
		if length > 0.001:
			var horizontal := Vector2(span.x, span.z).length()
			sag = (
				minf(WIRE_SAG_FRACTION * length, WIRE_SAG_MAX_M)
				* horizontal / length
			)
		if sag <= 0.005:
			result.append(end)
			continue
		for step: int in range(1, WIRE_SAG_SUBDIVISIONS):
			var t := float(step) / float(WIRE_SAG_SUBDIVISIONS)
			result.append(
				start
				+ span * t
				+ Vector3.DOWN * (sag * 4.0 * t * (1.0 - t))
			)
		result.append(end)
	return result


func _ensure_wire_segments(body: StaticBody3D, count: int) -> void:
	var current := 0
	while body.get_node_or_null("Mesh%d" % current) != null:
		current += 1
	if current == count:
		return
	for index: int in range(count, current):
		body.get_node("Mesh%d" % index).queue_free()
		body.get_node("Col%d" % index).queue_free()
	for index: int in range(current, count):
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "Mesh%d" % index
		var capsule_mesh := CapsuleMesh.new()
		capsule_mesh.radius = WIRE_RADIUS
		capsule_mesh.radial_segments = 8
		capsule_mesh.rings = 2
		mesh_instance.mesh = capsule_mesh
		mesh_instance.material_override = _wire_material
		body.add_child(mesh_instance)
		var collision := CollisionShape3D.new()
		collision.name = "Col%d" % index
		var capsule := CapsuleShape3D.new()
		capsule.radius = WIRE_AIM_RADIUS
		collision.shape = capsule
		body.add_child(collision)


func _set_segments_disabled(body: StaticBody3D, disabled: bool) -> void:
	for child: Node in body.get_children():
		var collision := child as CollisionShape3D
		if collision != null:
			collision.disabled = disabled


func _wire_basis(direction: Vector3) -> Basis:
	if direction.is_equal_approx(Vector3.UP):
		return Basis.IDENTITY
	if direction.is_equal_approx(Vector3.DOWN):
		return Basis.IDENTITY.rotated(Vector3.RIGHT, PI)
	var look := Basis.looking_at(direction, Vector3.UP)
	return look.rotated(look.x, -PI * 0.5)


func _create_wire_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = WIRE_COLOR
	material.metallic = 0.3
	material.roughness = 0.5
	return material


func _create_dormant_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = WIRE_DORMANT_COLOR
	material.metallic = 0.1
	material.roughness = 0.8
	return material
