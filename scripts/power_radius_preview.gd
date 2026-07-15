extends Node3D
## Hold `/` while aiming at a power distributor to preview its wireless supply
## radius and highlight consumers within reach. Presentation only.

const AIM_MAX_DISTANCE := 4.0
const RING_SEGMENTS := 72
const RING_LIFT_M := 0.08
const MARKER_HALF_SIZE_M := 0.14

const COLOR_RING_SUPPLIED := Color(0.35, 0.92, 1.0, 0.42)
const COLOR_RING_UNSUPPLIED := Color(0.95, 0.62, 0.18, 0.28)
const COLOR_LINK_POWERED := Color(0.45, 1.0, 0.62, 0.55)
const COLOR_LINK_IN_RADIUS := Color(0.75, 0.85, 0.95, 0.32)
const COLOR_MARKER_POWERED := Color(0.4, 1.0, 0.58, 0.85)
const COLOR_MARKER_IN_RADIUS := Color(0.8, 0.88, 0.98, 0.5)

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var session_path: NodePath = NodePath("../../SimulationSession")

var _query: InteractionQuery
var _session: SimulationSession
var _mesh: ImmediateMesh
var _mesh_instance: MeshInstance3D
var _materials: Dictionary = {}


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_query = get_node(query_path) as InteractionQuery
	_session = get_node_or_null(session_path) as SimulationSession
	_mesh = ImmediateMesh.new()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _mesh
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	_create_materials()


func _process(_delta: float) -> void:
	if _mesh == null:
		return
	_mesh.clear_surfaces()
	if not _should_show():
		return
	var distributor_id := _aimed_distributor_id()
	if distributor_id <= 0:
		return
	var world := _session.world
	var distributor := world.get_element(distributor_id)
	if distributor == null:
		return
	var center := IndustryElectricBudget.element_world_position(world, distributor)
	var radius_m := IndustryElectricProfile.supply_radius_m(distributor)
	var supplied := IndustryElectricBudget.is_element_on_supplied_network(
		world,
		distributor_id
	)
	_draw_ring(center, radius_m, supplied)
	for consumer: SimulationElement in _consumers_in_radius(
		world,
		center,
		radius_m
	):
		var consumer_pos := IndustryElectricBudget.element_world_position(
			world,
			consumer
		)
		var runtime := world.ensure_industry_element_runtime(consumer.element_id)
		var powered := runtime.powered and runtime.power_reason == &"ok"
		var link_color := (
			COLOR_LINK_POWERED if powered else COLOR_LINK_IN_RADIUS
		)
		var marker_color := (
			COLOR_MARKER_POWERED if powered else COLOR_MARKER_IN_RADIUS
		)
		_draw_line(center, consumer_pos, link_color)
		_draw_consumer_marker(consumer_pos, marker_color)


func _should_show() -> bool:
	if not Input.is_action_pressed(&"show_power_radius"):
		return false
	var player := get_parent()
	if (
		player.has_method("is_gameplay_input_enabled")
		and not player.call("is_gameplay_input_enabled")
	):
		return false
	if player.has_method("is_in_vehicle") and player.call("is_in_vehicle"):
		return false
	return _session != null and _session.world != null


func _aimed_distributor_id() -> int:
	if _query == null or _session == null or _session.world == null:
		return 0
	var hit := _query.current_hit
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
		or hit.distance > AIM_MAX_DISTANCE
	):
		return 0
	var element_id := int(hit.metadata.get("element_id", 0))
	if element_id <= 0:
		return 0
	var element := _session.world.get_element(element_id)
	if element == null or not IndustryElectricProfile.is_distributor(element):
		return 0
	return element_id


func _consumers_in_radius(
	world: SimulationWorld,
	center: Vector3,
	radius_m: float
) -> Array[SimulationElement]:
	var result: Array[SimulationElement] = []
	for element: SimulationElement in world.list_elements():
		if not element.is_operational():
			continue
		if not IndustryElectricProfile.is_power_consumer(element):
			continue
		var position := IndustryElectricBudget.element_world_position(
			world,
			element
		)
		if center.distance_to(position) <= radius_m + 0.000001:
			result.append(element)
	return result


func _draw_ring(center: Vector3, radius_m: float, supplied: bool) -> void:
	var color := COLOR_RING_SUPPLIED if supplied else COLOR_RING_UNSUPPLIED
	var material: StandardMaterial3D = _materials["ring"]
	material.albedo_color = color
	material.emission = Color(color.r, color.g, color.b, 1.0)
	var y := center.y + RING_LIFT_M
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
	for segment: int in range(RING_SEGMENTS + 1):
		var angle := TAU * float(segment) / float(RING_SEGMENTS)
		_mesh.surface_add_vertex(
			Vector3(
				center.x + cos(angle) * radius_m,
				y,
				center.z + sin(angle) * radius_m
			)
		)
	_mesh.surface_end()


func _draw_line(from: Vector3, to: Vector3, color: Color) -> void:
	var material: StandardMaterial3D = _materials["line"]
	material.albedo_color = color
	material.emission = Color(color.r, color.g, color.b, 1.0)
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	_mesh.surface_add_vertex(from + Vector3.UP * RING_LIFT_M)
	_mesh.surface_add_vertex(to + Vector3.UP * RING_LIFT_M)
	_mesh.surface_end()


func _draw_consumer_marker(position: Vector3, color: Color) -> void:
	var material: StandardMaterial3D = _materials["marker"]
	material.albedo_color = color
	material.emission = Color(color.r, color.g, color.b, 1.0)
	var base := position + Vector3.UP * RING_LIFT_M
	var top := base + Vector3.UP * MARKER_HALF_SIZE_M
	var half := MARKER_HALF_SIZE_M * 0.65
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	_mesh.surface_add_vertex(base)
	_mesh.surface_add_vertex(top)
	_mesh.surface_add_vertex(top + Vector3(half, 0.0, 0.0))
	_mesh.surface_add_vertex(top + Vector3(-half, 0.0, 0.0))
	_mesh.surface_add_vertex(top)
	_mesh.surface_add_vertex(top + Vector3(0.0, 0.0, half))
	_mesh.surface_add_vertex(top + Vector3(0.0, 0.0, -half))
	_mesh.surface_end()


func _create_materials() -> void:
	for key: String in ["ring", "line", "marker"]:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.emission_enabled = true
		_materials[key] = material
