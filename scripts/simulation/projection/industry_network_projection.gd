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
## Tube extrusion along the smoothed spline: sample spacing and ring detail.
const TUBE_BAKE_INTERVAL_M := 0.3
const TUBE_RING_SEGMENTS := 6
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
## link_id → last sampled tube path; skips remeshing static cables.
var _tube_path_cache: Dictionary = {}


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
	_tube_path_cache.clear()
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
	# The visual is ONE smooth tube mesh extruded along a Catmull-Rom spline
	# through the routed points; invisible capsules only serve the aim ray.
	var path := _smooth_polyline(display)
	_update_wire_colliders(body, display)
	var mesh_instance := _ensure_tube_mesh_instance(body)
	mesh_instance.material_override = (
		_wire_material
		if IndustryElectricPortUtil.link_still_valid(_world, link)
		else _wire_dormant_material
	)
	if _tube_path_changed(link.link_id, path):
		mesh_instance.mesh = _build_tube_mesh(path)
		_tube_path_cache[link.link_id] = path


## Rebuild the tube only when the sampled path actually moved (anchors follow
## their assemblies; скобы are world-pinned and static).
func _tube_path_changed(link_id: int, path: PackedVector3Array) -> bool:
	var cached: PackedVector3Array = _tube_path_cache.get(
		link_id,
		PackedVector3Array()
	)
	if cached.size() != path.size():
		return true
	for index: int in range(path.size()):
		if cached[index].distance_squared_to(path[index]) > 0.000025:
			return true
	return false


func _ensure_tube_mesh_instance(body: StaticBody3D) -> MeshInstance3D:
	var mesh_instance := body.get_node_or_null("Tube") as MeshInstance3D
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "Tube"
		mesh_instance.top_level = true
		mesh_instance.global_transform = Transform3D.IDENTITY
		body.add_child(mesh_instance)
	return mesh_instance


## Catmull-Rom smoothing through the routed points: скобы stay interpolated
## (the cable still touches every mount), corners round off naturally.
func _smooth_polyline(points: PackedVector3Array) -> PackedVector3Array:
	if points.size() <= 2:
		return points
	var curve := Curve3D.new()
	curve.bake_interval = TUBE_BAKE_INTERVAL_M
	for point: Vector3 in points:
		curve.add_point(point)
	for index: int in range(points.size()):
		var previous := points[maxi(index - 1, 0)]
		var next := points[mini(index + 1, points.size() - 1)]
		var tangent := (next - previous) / 6.0
		curve.set_point_in(index, -tangent)
		curve.set_point_out(index, tangent)
	var baked := curve.get_baked_points()
	return baked if baked.size() >= 2 else points


## Single continuous tube (ring extrusion with parallel-transport frames, so
## the section never twists through bends).
func _build_tube_mesh(path: PackedVector3Array) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array[PackedVector3Array] = []
	var ring_normals: Array[PackedVector3Array] = []
	var normal := Vector3.UP
	var first_tangent := (path[1] - path[0]).normalized()
	if absf(first_tangent.dot(normal)) > 0.95:
		normal = Vector3.RIGHT
	for index: int in range(path.size()):
		var previous := path[maxi(index - 1, 0)]
		var next := path[mini(index + 1, path.size() - 1)]
		var tangent := next - previous
		if tangent.length_squared() < 0.0000001:
			tangent = first_tangent
		tangent = tangent.normalized()
		normal = (normal - tangent * normal.dot(tangent))
		if normal.length_squared() < 0.0001:
			normal = tangent.cross(Vector3.UP)
			if normal.length_squared() < 0.0001:
				normal = tangent.cross(Vector3.RIGHT)
		normal = normal.normalized()
		var binormal := tangent.cross(normal).normalized()
		var ring := PackedVector3Array()
		var normals := PackedVector3Array()
		for segment: int in range(TUBE_RING_SEGMENTS):
			var angle := TAU * float(segment) / float(TUBE_RING_SEGMENTS)
			var offset := normal * cos(angle) + binormal * sin(angle)
			ring.append(path[index] + offset * WIRE_RADIUS)
			normals.append(offset)
		rings.append(ring)
		ring_normals.append(normals)
	for ring_index: int in range(rings.size() - 1):
		for segment: int in range(TUBE_RING_SEGMENTS):
			var next_segment := (segment + 1) % TUBE_RING_SEGMENTS
			var a := rings[ring_index][segment]
			var b := rings[ring_index][next_segment]
			var c := rings[ring_index + 1][next_segment]
			var d := rings[ring_index + 1][segment]
			var na := ring_normals[ring_index][segment]
			var nb := ring_normals[ring_index][next_segment]
			var nc := ring_normals[ring_index + 1][next_segment]
			var nd := ring_normals[ring_index + 1][segment]
			surface.set_normal(na)
			surface.add_vertex(a)
			surface.set_normal(nb)
			surface.add_vertex(b)
			surface.set_normal(nc)
			surface.add_vertex(c)
			surface.set_normal(na)
			surface.add_vertex(a)
			surface.set_normal(nc)
			surface.add_vertex(c)
			surface.set_normal(nd)
			surface.add_vertex(d)
	return surface.commit()


## Invisible aim capsules along the un-smoothed display polyline — enough for
## the grinder ray, no need to hug the spline exactly.
func _update_wire_colliders(
	body: StaticBody3D,
	path: PackedVector3Array
) -> void:
	var segment_count := path.size() - 1
	_ensure_wire_segments(body, segment_count)
	for index: int in range(segment_count):
		var start := path[index]
		var end := path[index + 1]
		var delta := end - start
		var length := delta.length()
		var collision := body.get_node("Col%d" % index) as CollisionShape3D
		if length <= 0.01:
			collision.disabled = true
			continue
		collision.disabled = false
		var capsule := collision.shape as CapsuleShape3D
		if capsule != null:
			capsule.height = maxf(length, WIRE_AIM_RADIUS * 2.1)
		collision.global_transform = Transform3D(
			_wire_basis(delta / length),
			(start + end) * 0.5
		)


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
	while body.get_node_or_null("Col%d" % current) != null:
		current += 1
	if current == count:
		return
	for index: int in range(count, current):
		body.get_node("Col%d" % index).queue_free()
	for index: int in range(current, count):
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
