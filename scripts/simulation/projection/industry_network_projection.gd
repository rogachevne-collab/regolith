class_name IndustryNetworkProjection
extends Node3D
## Electric wire mesh presentation sourced from authoritative `electric_links[]`.
## Cargo pipes render as placed element geometry only (INDUSTRY-V1 § Wire presentation).

const WIRE_MESH_PREFIX := "IndustryWire_"
const WIRE_RADIUS := 0.045
const WIRE_COLOR := Color(0.92, 0.74, 0.18, 1.0)
const WIRE_EMISSION := Color(0.55, 0.42, 0.08, 1.0)

var _world: SimulationWorld
var _physics_projection: SimulationPhysicsProjection
var _links_root: Node3D
var _wire_material: StandardMaterial3D
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
		var mesh_instance := _make_wire_mesh(link)
		if mesh_instance != null:
			_links_root.add_child(mesh_instance)
	_cached_network_revision = _world.get_industry_network_revision()


func _process(_delta: float) -> void:
	if _world == null:
		return
	var revision := _world.get_industry_network_revision()
	if revision != _cached_network_revision:
		rebuild_all()
		return
	for child: Node in _links_root.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null:
			continue
		var link_id := int(mesh_instance.get_meta("electric_link_id", 0))
		var link := _world.get_industry_network().get_link(link_id)
		if link != null:
			_update_wire_mesh(mesh_instance, link)


func _on_structural_event(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored", &"electric_link_added", &"electric_link_removed":
			rebuild_all()
		&"assembly_spawned", &"assembly_changed", &"assembly_removed", &"assembly_split", &"assembly_merged":
			rebuild_all()
		&"element_state_changed":
			rebuild_all()


func _make_wire_mesh(link: IndustryElectricLink) -> MeshInstance3D:
	var element_a := _world.get_element(link.element_a)
	var element_b := _world.get_element(link.element_b)
	if element_a == null or element_b == null:
		return null
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
		return null
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "%s%d" % [WIRE_MESH_PREFIX, link.link_id]
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = WIRE_RADIUS
	cylinder.bottom_radius = WIRE_RADIUS
	cylinder.radial_segments = 8
	cylinder.rings = 1
	mesh_instance.mesh = cylinder
	mesh_instance.material_override = _wire_material
	mesh_instance.set_meta("electric_link_id", link.link_id)
	_update_wire_mesh(mesh_instance, link)
	return mesh_instance


func _update_wire_mesh(
	mesh_instance: MeshInstance3D,
	link: IndustryElectricLink
) -> void:
	var element_a := _world.get_element(link.element_a)
	var element_b := _world.get_element(link.element_b)
	if element_a == null or element_b == null:
		mesh_instance.visible = false
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
		mesh_instance.visible = false
		return
	mesh_instance.visible = true
	var cylinder := mesh_instance.mesh as CylinderMesh
	if cylinder != null:
		cylinder.height = length
	var midpoint := (start + end) * 0.5
	var direction := delta / length
	var basis := _wire_basis(direction)
	mesh_instance.global_transform = Transform3D(basis, midpoint)


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
