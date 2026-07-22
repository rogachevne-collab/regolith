extends Node3D
## The rope being pulled. Not a ghost line — the actual cable, tied to the end
## the player already clicked and trailing the cursor, sagging exactly as much
## as the wheel says it will when it is built. Presentation only: reads
## ToolController and InteractionQuery, never issues commands.

## Slightly brighter than a placed cable so the one in your hands reads as live.
const PENDING_COLOR := Color(0.10, 0.11, 0.12, 1.0)
const PENDING_EMISSION := Color(0.16, 0.55, 0.62, 1.0)
const ROPE_RADIUS := 0.024
const ROPE_SEGMENTS := 20
## Fallback reach when nothing is aimed at; the real limit is the tool's own
## throw range, so the rope trails as far as the throw would land.
const FALLBACK_AIM_DISTANCE := 4.0

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")

var _query: InteractionQuery
var _tools: ToolController
var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
## Verlet state of the rope in hand — the same solver the built ropes use, so
## what trails the cursor drapes over the ground instead of sinking through it.
var _rope_state: Dictionary = {}


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_material = StandardMaterial3D.new()
	_material.albedo_color = PENDING_COLOR
	_material.metallic = 0.2
	_material.roughness = 0.55
	_material.emission_enabled = true
	_material.emission = PENDING_EMISSION
	_material.emission_energy_multiplier = 0.35
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "PendingRope"
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.visible = false
	add_child(_mesh_instance)
	_query = get_node_or_null(query_path) as InteractionQuery
	_tools = get_node_or_null(tool_controller_path) as ToolController


func _process(delta: float) -> void:
	if _mesh_instance == null or _tools == null or _query == null:
		return
	if _tools.active_tool != &"connect" or not _tools.rope_routing_active():
		_mesh_instance.visible = false
		_rope_state = {}
		return
	var anchor := _tools.rope_anchor_world_position()
	if not anchor.is_finite():
		_mesh_instance.visible = false
		return
	var free_end := _free_end_position(anchor)
	var span := anchor.distance_to(free_end)
	if span < CableAnchorUtil.MIN_SPAN_M:
		_mesh_instance.visible = false
		return
	var rest_length := CableAnchorUtil.rest_length_m(span, _tools.rope_slack())
	var gravity := GravityField.resolve_gravity_accel(
		self,
		(anchor + free_end) * 0.5
	)
	if _rope_state.is_empty():
		_rope_state = CableRopeSolver.create_state(
			anchor,
			free_end,
			rest_length,
			-gravity.normalized() if gravity.length_squared() > 0.0 else Vector3.UP,
			get_world_3d().direct_space_state
		)
	CableRopeSolver.step(
		_rope_state,
		anchor,
		free_end,
		rest_length,
		gravity,
		delta,
		get_world_3d().direct_space_state
	)
	var path := CableRopeSolver.path(_rope_state)
	if path.size() < 2:
		_mesh_instance.visible = false
		return
	_mesh_instance.mesh = CableCurveUtil.build_tube_mesh(
		CableCurveUtil.smooth_adaptive(path),
		ROPE_RADIUS
	)
	_mesh_instance.visible = true


## Where the loose end hangs: on the aimed surface when there is one, otherwise
## at arm's length down the view ray, so the rope keeps trailing the cursor
## even while the player looks at the sky.
func _free_end_position(anchor: Vector3) -> Vector3:
	var hit := _query.current_hit
	if hit != null and hit.valid and hit.distance <= _tools.rope_click_range():
		return hit.point + hit.normal * 0.06
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return anchor
	return (
		camera.global_position
		- camera.global_transform.basis.z * FALLBACK_AIM_DISTANCE
	)
