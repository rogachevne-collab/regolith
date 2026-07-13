extends Node3D
## Ghost polyline while routing a cable with the connect tool: pending element
## → placed скобы → current aim point. Presentation only — reads ToolController
## and InteractionQuery, never issues commands.

const GHOST_COLOR := Color(0.35, 0.95, 1.0, 0.9)
const MAX_AIM_DISTANCE := 4.0

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")
@export var gateway_path: NodePath = NodePath("../../WorldCommandGateway")

var _query: InteractionQuery
var _tools: ToolController
var _gateway: WorldCommandGateway
var _mesh: ImmediateMesh
var _material: StandardMaterial3D


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_query = get_node(query_path)
	_tools = get_node(tool_controller_path)
	_gateway = get_node_or_null(gateway_path) as WorldCommandGateway
	_mesh = ImmediateMesh.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = GHOST_COLOR
	_material.emission_enabled = true
	_material.emission = GHOST_COLOR


func _process(_delta: float) -> void:
	_mesh.clear_surfaces()
	if _tools.active_tool != &"connect":
		return
	var pending_id := _tools.connect_pending_element_id()
	if pending_id <= 0:
		return
	var world := _simulation_world()
	if world == null:
		return
	var element := world.get_element(pending_id)
	if element == null:
		return
	var points := PackedVector3Array()
	points.append(
		IndustryElectricBudget.element_world_position(world, element)
	)
	points.append_array(_tools.connect_waypoints())
	var hit := _query.current_hit
	if hit.valid and hit.distance <= MAX_AIM_DISTANCE:
		points.append(hit.point)
	if points.size() < 2:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _material)
	for point: Vector3 in points:
		_mesh.surface_add_vertex(point)
	_mesh.surface_end()


func _simulation_world() -> SimulationWorld:
	if _gateway == null:
		return null
	var session := _gateway.get_node_or_null(
		_gateway.simulation_session_path
	) as SimulationSession
	if session == null:
		return null
	return session.world
