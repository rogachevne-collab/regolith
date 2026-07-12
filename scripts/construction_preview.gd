class_name ConstructionPreview
extends Node3D

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")
@export var gateway_path: NodePath = NodePath("../../WorldCommandGateway")
@export var camera_path: NodePath = NodePath("../Camera")

var resolved_target: Dictionary = {}
var resolved_plan: Dictionary = {}
var resolved_candidate_index := -1
var resolved_candidate_count := 0
var resolved_candidates: Array = []

var _query: InteractionQuery
var _tools: ToolController
var _gateway: WorldCommandGateway
var _camera: Camera3D
var _valid_material: StandardMaterial3D
var _invalid_material: StandardMaterial3D
var _signature := ""
var _mesh_cache: Dictionary = {}
var _manual_candidate_index := -1
var _manual_lock := false
var _cached_resolve_context_key := ""
const _AIM_ORIGIN_STEP := 0.04
const _AIM_DIRECTION_STEP := 0.02


func _ready() -> void:
	top_level = true
	process_physics_priority = -10
	_query = get_node(query_path)
	_tools = get_node(tool_controller_path)
	_gateway = get_node(gateway_path)
	_camera = get_node_or_null(camera_path) as Camera3D
	_tools.construction_selection_changed.connect(_on_selection_changed)
	_tools.active_tool_changed.connect(_on_active_tool_changed)
	_valid_material = _preview_material(Color(0.2, 0.95, 1.0, 0.35))
	_invalid_material = _preview_material(Color(1.0, 0.2, 0.15, 0.3))
	visible = false
	call_deferred("_warm_current_selection")


func _physics_process(_delta: float) -> void:
	var player := get_parent()
	if (
		(
			player.has_method("is_gameplay_input_enabled")
			and not player.call("is_gameplay_input_enabled")
		)
		or (
			player.has_method("is_in_vehicle")
			and player.call("is_in_vehicle")
		)
	):
		_clear_resolution()
		_hide_preview()
		return
	if _tools.active_tool != &"build":
		_clear_resolution()
		_hide_preview()
		return
	if Input.is_action_just_pressed(&"construction_cycle_snap"):
		_advance_manual_cycle()
	_update_resolution()
	if resolved_target.is_empty() or resolved_plan.is_empty():
		_hide_preview()
		return
	var archetype := resolved_plan.get("archetype") as ElementArchetype
	if archetype == null:
		_hide_preview()
		return
	var origin_cell: Vector3i = resolved_plan.get("origin_cell", Vector3i.ZERO)
	var next_signature := "%s|%d|%s|%s" % [
		archetype.archetype_id,
		_tools.selected_orientation_index,
		origin_cell,
		str(bool(resolved_plan.get("valid", false))),
	]
	if next_signature != _signature:
		_apply_cached_mesh(
			archetype,
			_tools.selected_orientation_index,
			origin_cell,
			bool(resolved_plan.get("valid", false))
		)
		_signature = next_signature
	global_transform = resolved_plan.get(
		"preview_root_transform",
		resolved_plan.get("assembly_world_transform", Transform3D.IDENTITY)
	)
	visible = true


func resolved_hit() -> InteractionHit:
	return InteractionHit.from_snapshot(resolved_target)


func has_resolved_placement() -> bool:
	return (
		not resolved_target.is_empty()
		and bool(resolved_plan.get("valid", false))
	)


func _update_resolution() -> void:
	var direct_hit := _query.current_hit.snapshot()
	if not _should_resolve(direct_hit):
		_clear_resolution()
		return
	var aim := _aim_ray()
	var context_key := _resolve_context_key(aim, direct_hit)
	if context_key != _cached_resolve_context_key and _manual_lock:
		_manual_lock = false
		_manual_candidate_index = -1
	if (
		not _manual_lock
		and context_key == _cached_resolve_context_key
	):
		return
	_cached_resolve_context_key = context_key

	var resolved := _gateway.resolve_construction_placement({
		"direct_hit": direct_hit,
		"ray_origin": aim["origin"],
		"ray_direction": aim["direction"],
		"camera": _camera,
		"archetype_id": _tools.selected_archetype_id,
		"orientation_index": _tools.selected_orientation_index,
		"manual_candidate_index": (
			_manual_candidate_index if _manual_lock else -1
		),
	})
	resolved_target = resolved.get("selected_target", {})
	resolved_plan = resolved.get("selected_plan", {})
	resolved_candidates = resolved.get("candidates", [])
	resolved_candidate_index = int(resolved.get("selected_index", -1))
	resolved_candidate_count = resolved_candidates.size()


func _resolve_context_key(aim: Dictionary, direct_hit: Dictionary) -> String:
	var origin: Vector3 = aim["origin"]
	var direction: Vector3 = aim["direction"]
	return "%d|%s|%s|%s|%d|%s" % [
		_gateway.snap_cache_generation(),
		_quantize_vec3(origin, _AIM_ORIGIN_STEP),
		_quantize_vec3(direction, _AIM_DIRECTION_STEP),
		_tools.selected_archetype_id,
		_tools.selected_orientation_index,
		StringName(direct_hit.get("target_id", &"")),
	]


static func _quantize_vec3(value: Vector3, step: float) -> Vector3:
	if step <= 0.0:
		return value
	return Vector3(
		snapped(value.x, step),
		snapped(value.y, step),
		snapped(value.z, step),
	)


func _should_resolve(target: Dictionary) -> bool:
	if not bool(target.get("valid", false)):
		return true
	var kind := StringName(target.get("target_kind", &""))
	if kind == InteractionHit.KIND_VOXEL:
		return true
	if kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		return false
	var status := StringName(
		target.get("metadata", {}).get("status_reason", &"element_incomplete")
	)
	return (
		status == &"ok"
		or status == &"element_incomplete"
		or status == &"damaged"
	)


func _aim_ray() -> Dictionary:
	if _camera != null and _camera.has_method("aim_transform"):
		var aim: Transform3D = _camera.call("aim_transform")
		return {
			"origin": aim.origin,
			"direction": -aim.basis.z.normalized(),
		}
	if _camera != null:
		return {
			"origin": _camera.global_position,
			"direction": -_camera.global_basis.z.normalized(),
		}
	return {
		"origin": global_position,
		"direction": -global_basis.z.normalized(),
	}


func _advance_manual_cycle() -> void:
	if resolved_candidates.is_empty():
		return
	if resolved_candidates.size() == 1:
		_manual_candidate_index = 0
		_manual_lock = true
		_cached_resolve_context_key = ""
		_update_resolution()
		return
	var start_index := (
		resolved_candidate_index
		if resolved_candidate_index >= 0
		else 0
	)
	var helper := ConstructionSnapResolver.new()
	_manual_candidate_index = helper.cycle_candidate(
		resolved_candidates,
		start_index,
		1
	)
	_manual_lock = true
	_cached_resolve_context_key = ""
	_update_resolution()


func _clear_resolution() -> void:
	resolved_target = {}
	resolved_plan = {}
	resolved_candidates = []
	resolved_candidate_index = -1
	resolved_candidate_count = 0
	_manual_candidate_index = -1
	_manual_lock = false
	_cached_resolve_context_key = ""


func _apply_cached_mesh(
	archetype: ElementArchetype,
	orientation_index: int,
	origin_cell: Vector3i,
	valid: bool
) -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	var cache_key := _cache_key(
		archetype.archetype_id,
		orientation_index,
		origin_cell,
		valid
	)
	if not _mesh_cache.has(cache_key):
		_mesh_cache[cache_key] = _build_mesh_nodes(
			archetype,
			orientation_index,
			origin_cell,
			valid
		)
	for node: Node in _mesh_cache[cache_key]:
		add_child(node.duplicate())


func _build_mesh_nodes(
	archetype: ElementArchetype,
	orientation_index: int,
	origin_cell: Vector3i,
	valid: bool
) -> Array[Node]:
	var material := _valid_material if valid else _invalid_material
	var nodes: Array[Node] = []
	for collider: ColliderDefinition in archetype.colliders:
		if collider.shape_kind != ColliderDefinition.ShapeKind.BOX:
			continue
		var mesh := BoxMesh.new()
		mesh.size = collider.size * 1.015
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.transform = GridPoseUtil.collider_local_transform(
			origin_cell,
			orientation_index,
			collider
		)
		nodes.append(instance)
	return nodes


func _cache_key(
	archetype_id: String,
	orientation_index: int,
	origin_cell: Vector3i,
	valid: bool
) -> String:
	return "%s|%d|%s|%s" % [archetype_id, orientation_index, origin_cell, valid]


func _warm_current_selection() -> void:
	var archetype := Slice01Archetypes.load_required(
		_tools.selected_archetype_id
	)
	if archetype == null:
		return
	for valid: bool in [true, false]:
		var cache_key := _cache_key(
			archetype.archetype_id,
			_tools.selected_orientation_index,
			Vector3i.ZERO,
			valid
		)
		if not _mesh_cache.has(cache_key):
			_mesh_cache[cache_key] = _build_mesh_nodes(
				archetype,
				_tools.selected_orientation_index,
				Vector3i.ZERO,
				valid
			)


func _on_selection_changed(
	_archetype_id: String,
	_orientation_index: int
) -> void:
	_signature = ""
	_manual_candidate_index = -1
	_manual_lock = false
	_cached_resolve_context_key = ""
	_gateway.reset_construction_snap()
	call_deferred("_warm_archetype", _archetype_id, _orientation_index)


func _on_active_tool_changed(_active_tool: StringName) -> void:
	_manual_candidate_index = -1
	_manual_lock = false
	_cached_resolve_context_key = ""
	_gateway.reset_construction_snap()


func _warm_archetype(archetype_id: String, orientation_index: int) -> void:
	var archetype := Slice01Archetypes.load_required(archetype_id)
	if archetype == null:
		return
	for valid: bool in [true, false]:
		var cache_key := _cache_key(
			archetype_id,
			orientation_index,
			Vector3i.ZERO,
			valid
		)
		if not _mesh_cache.has(cache_key):
			_mesh_cache[cache_key] = _build_mesh_nodes(
				archetype,
				orientation_index,
				Vector3i.ZERO,
				valid
			)


func _hide_preview() -> void:
	visible = false


func _preview_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material
