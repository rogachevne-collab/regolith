class_name IndustryNetworkProjection
extends Node3D
## Electric wire mesh presentation sourced from authoritative `electric_links[]`.
## Cargo pipes render as placed element geometry only (INDUSTRY-V1 § Wire presentation).

const WIRE_MESH_PREFIX := "IndustryWire_"
const WIRE_RADIUS := 0.045
## Aim-collider radius: fatter than the visual so the grinder can target a wire.
const WIRE_AIM_RADIUS := 0.09
## Physics layer 4 — interaction-ray only; nothing moves or collides on it.
const WIRE_COLLISION_LAYER := 8
const WIRE_COLOR := Color(0.92, 0.74, 0.18, 1.0)
const WIRE_EMISSION := Color(0.55, 0.42, 0.08, 1.0)
## Dormant wire (endpoint damaged/incomplete or cable overstretched): the link
## persists in state and keeps rendering, dimmed, until the condition clears.
const WIRE_DORMANT_COLOR := Color(0.38, 0.34, 0.24, 1.0)

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
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = WIRE_RADIUS
	cylinder.bottom_radius = WIRE_RADIUS
	cylinder.radial_segments = 8
	cylinder.rings = 1
	mesh_instance.mesh = cylinder
	mesh_instance.material_override = _wire_material
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = WIRE_AIM_RADIUS
	collision.shape = capsule
	body.add_child(collision)
	_update_wire_body(body, link)
	return body


func _update_wire_body(
	body: StaticBody3D,
	link: IndustryElectricLink
) -> void:
	var element_a := _world.get_element(link.element_a)
	var element_b := _world.get_element(link.element_b)
	var collision := body.get_node_or_null("Collision") as CollisionShape3D
	if element_a == null or element_b == null:
		body.visible = false
		if collision != null:
			collision.disabled = true
		return
	var start := IndustryElectricPortUtil.port_anchor_world_position(
		_world,
		element_a,
		link.port_a
	)
	var end := IndustryElectricPortUtil.port_anchor_world_position(
		_world,
		element_b,
		link.port_b
	)
	var delta := end - start
	var length := delta.length()
	if length <= 0.05:
		body.visible = false
		if collision != null:
			collision.disabled = true
		return
	body.visible = true
	var mesh_instance := body.get_node_or_null("Mesh") as MeshInstance3D
	if mesh_instance != null:
		mesh_instance.material_override = (
			_wire_material
			if IndustryElectricPortUtil.link_still_valid(_world, link)
			else _wire_dormant_material
		)
		var cylinder := mesh_instance.mesh as CylinderMesh
		if cylinder != null:
			cylinder.height = length
	if collision != null:
		collision.disabled = false
		var capsule := collision.shape as CapsuleShape3D
		if capsule != null:
			capsule.height = maxf(length, WIRE_AIM_RADIUS * 2.1)
	var midpoint := (start + end) * 0.5
	var direction := delta / length
	var basis := _wire_basis(direction)
	body.global_transform = Transform3D(basis, midpoint)


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
	material.emission_enabled = true
	material.emission = WIRE_EMISSION
	material.emission_energy_multiplier = 0.35
	material.metallic = 0.85
	material.roughness = 0.35
	return material


func _create_dormant_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = WIRE_DORMANT_COLOR
	material.metallic = 0.6
	material.roughness = 0.6
	return material
