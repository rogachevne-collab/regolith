extends Node3D
## Ghost polyline while routing a cable with the connect tool: pending element
## → placed скобы → current aim point. Presentation only — reads ToolController
## and InteractionQuery, never issues commands.

const GHOST_COLOR := Color(0.35, 0.95, 1.0, 0.9)
const MAX_AIM_DISTANCE := 4.0

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")

var _query: InteractionQuery
var _tools: ToolController
var _mesh: ImmediateMesh
var _material: StandardMaterial3D


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
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
	_query = get_node_or_null(query_path) as InteractionQuery
	_tools = get_node_or_null(tool_controller_path) as ToolController


func _process(_delta: float) -> void:
	if _mesh == null:
		return
	_mesh.clear_surfaces()
	if _tools == null or _query == null:
		return
	if _tools.active_tool != &"connect":
		return
	var pending_id := _tools.connect_pending_element_id()
	if pending_id <= 0:
		return
	var waypoints := _tools.connect_waypoints()
	var hit := _query.current_hit
	var aim_valid := hit.valid and hit.distance <= MAX_AIM_DISTANCE
	# The route starts at the pending element's electric port nearest to the
	# next routed point — not at the element pivot.
	var anchor_reference := (
		waypoints[0]
		if not waypoints.is_empty()
		else (hit.point if aim_valid else global_position)
	)
	var anchor := _tools.connect_anchor_position(anchor_reference)
	if not anchor.is_finite():
		return
	var points := PackedVector3Array()
	points.append(anchor)
	points.append_array(waypoints)
	if aim_valid:
		points.append(hit.point)
	if points.size() < 2:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _material)
	for point: Vector3 in points:
		_mesh.surface_add_vertex(point)
	_mesh.surface_end()
