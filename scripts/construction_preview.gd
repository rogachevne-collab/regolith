class_name ConstructionPreview
extends Node3D

const STATIONARY_DRILL_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/stationary_drill_visual.gd"
)
const PISTON_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/piston_visual.gd"
)
const ROVER_MODULE_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/rover_module_visual.gd"
)
const CONNECTED_BLOCK_VISUAL_SCRIPT := preload(
	"res://scripts/presentation/connected_block_visual.gd"
)

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
## Preview nodes are built once per (archetype, orientation, valid) at grid
## origin ZERO; this container translates them to the plan's origin_cell, so
## sweeping the aim over attach targets moves a transform instead of
## rebuilding/duplicating mesh nodes every cell change.
var _mesh_root: Node3D
var _manual_candidate_index := -1
var _manual_lock := false
var _cached_resolve_context_key := ""
var _ground_pivot_key := ""
var _held_ground_pivot := Vector3(INF, INF, INF)
var _attach_pivot_key := ""
var _held_attach_pivot := Vector3(INF, INF, INF)
var _held_attach_snap_context: Dictionary = {}
var _selection_archetype_id := ""
var _selection_footprint_cells := 1
const _AIM_ORIGIN_STEP := 0.04
const _AIM_DIRECTION_STEP := 0.02
## Large archetypes: a resolve costs ~ms (125-cell plan validation), and a
## 2.5m ghost does not need cm-level aim tracking — quantize coarser so
## walking/running does not re-resolve every physics frame.
const _LARGE_AIM_ORIGIN_STEP := 0.25
const _LARGE_AIM_DIRECTION_STEP := 0.1
const _RESOLVE_HEARTBEAT_MSEC := 150
var _last_resolve_msec := 0


func _ready() -> void:
	top_level = true
	process_physics_priority = 10
	_mesh_root = Node3D.new()
	add_child(_mesh_root)
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
	if _tools == null or _query == null:
		return
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
	_sync_preview_visuals()


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
	var held_ground_pivot := Vector3(INF, INF, INF)
	var held_attach_pivot := Vector3(INF, INF, INF)
	if (
		StringName(direct_hit.get("target_kind", &""))
		== InteractionHit.KIND_VOXEL
	):
		var pivot_key := _ground_pivot_key_for(direct_hit)
		if pivot_key != _ground_pivot_key:
			_ground_pivot_key = pivot_key
			_held_ground_pivot = Vector3(INF, INF, INF)
		if not _held_ground_pivot.is_finite():
			_held_ground_pivot = _gateway.baseline_ground_pivot(
				direct_hit,
				_tools.selected_archetype_id
			)
		if _held_ground_pivot.is_finite():
			held_ground_pivot = _held_ground_pivot
	elif (
		StringName(direct_hit.get("target_kind", &""))
		== InteractionHit.KIND_SIMULATION_ELEMENT
	):
		var attach_key := _attach_pivot_key_for(direct_hit)
		if attach_key != _attach_pivot_key:
			_attach_pivot_key = attach_key
			_held_attach_pivot = Vector3(INF, INF, INF)
			_held_attach_snap_context.clear()
		if _held_attach_pivot.is_finite():
			held_attach_pivot = _held_attach_pivot
			var metadata: Dictionary = direct_hit.get("metadata", {}).duplicate(true)
			metadata["locked_target_port_cell"] = (
				_held_attach_snap_context.get(
					"target_port_cell",
					Vector3i.ZERO
				)
			)
			metadata["locked_snap_dir"] = _held_attach_snap_context.get(
				"snap_dir",
				Vector3i.UP
			)
			direct_hit["metadata"] = metadata
	var context_key := _resolve_context_key(
		aim,
		direct_hit,
		held_ground_pivot,
		held_attach_pivot
	)
	if context_key != _cached_resolve_context_key and _manual_lock:
		_manual_lock = false
		_manual_candidate_index = -1
	# Heartbeat: attach permission follows vehicle velocity (parking brake)
	# without any structural event, so an unchanged context key must still
	# re-resolve occasionally or a rover parked in the crosshair never
	# becomes magnetic until the aim moves.
	var now_msec := Time.get_ticks_msec()
	if (
		not _manual_lock
		and context_key == _cached_resolve_context_key
		and now_msec - _last_resolve_msec < _RESOLVE_HEARTBEAT_MSEC
	):
		return
	_cached_resolve_context_key = context_key
	_last_resolve_msec = now_msec

	var resolved := _gateway.resolve_construction_placement({
		"direct_hit": direct_hit,
		"ray_origin": aim["origin"],
		"ray_direction": aim["direction"],
		"camera": _camera,
		"archetype_id": _tools.selected_archetype_id,
		"orientation_index": _tools.selected_orientation_index,
		"held_ground_pivot": held_ground_pivot,
		"held_attach_pivot": held_attach_pivot,
		"manual_candidate_index": (
			_manual_candidate_index if _manual_lock else -1
		),
	})
	resolved_target = resolved.get("selected_target", {})
	resolved_plan = resolved.get("selected_plan", {})
	resolved_candidates = resolved.get("candidates", [])
	resolved_candidate_index = int(resolved.get("selected_index", -1))
	resolved_candidate_count = resolved_candidates.size()
	if (
		StringName(direct_hit.get("target_kind", &""))
		== InteractionHit.KIND_SIMULATION_ELEMENT
		and bool(resolved_plan.get("valid", false))
		and not _held_attach_pivot.is_finite()
	):
		_held_attach_pivot = GridPoseUtil.world_footprint_pivot(
			resolved_plan.get(
				"preview_root_transform",
				Transform3D.IDENTITY
			),
			resolved_plan.get("archetype") as ElementArchetype,
			resolved_plan.get("origin_cell", Vector3i.ZERO),
			int(resolved_plan.get("orientation_index", 0))
		)
		_held_attach_snap_context = resolved_plan.get(
			"attach_snap_context",
			{}
		).duplicate(true)
		# Pivot capture changes origin selection. Re-resolve next physics frame
		# instead of keeping the initial no-hold plan in the preview cache.
		_cached_resolve_context_key = ""


func _resolve_context_key(
	aim: Dictionary,
	direct_hit: Dictionary,
	held_ground_pivot: Vector3,
	held_attach_pivot: Vector3
) -> String:
	var origin: Vector3 = aim["origin"]
	var direction: Vector3 = aim["direction"]
	var aim_step := _aim_quantize_step_for_selection()
	# Miss / empty aim still runs face-scan resolve; coarsen while walking so
	# camera origin noise does not re-resolve every physics frame.
	if not bool(direct_hit.get("valid", false)):
		aim_step = maxf(aim_step, 0.35)
	return "%d|%s|%s|%s|%d|%s|%s|%s" % [
		_gateway.snap_context_revision(),
		_quantize_vec3(origin, aim_step),
		_quantize_vec3(direction, aim_step * 0.5),
		_tools.selected_archetype_id,
		_tools.selected_orientation_index,
		StringName(direct_hit.get("target_id", &"")),
		_pivot_context_token(held_ground_pivot),
		_pivot_context_token(held_attach_pivot),
	]


func _pivot_context_token(pivot: Vector3) -> String:
	if not pivot.is_finite():
		return "unset"
	return str(_quantize_vec3(pivot, 0.05))


func _aim_quantize_step_for_selection() -> float:
	if _selection_footprint_cells >= 64:
		return _LARGE_AIM_ORIGIN_STEP
	return _AIM_ORIGIN_STEP


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
	# HUD status_reason is often actuator/power state (idle, no_power, …)
	# when aiming at a piston head/base. That must NOT kill construction
	# resolve — otherwise horizontal pistons show no ghost at all.
	var status := StringName(
		target.get("metadata", {}).get("status_reason", &"ok")
	)
	return status not in [
		&"element_broken",
		&"invalid_target",
		&"missing_archetype",
	]


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
	_ground_pivot_key = ""
	_held_ground_pivot = Vector3(INF, INF, INF)
	_attach_pivot_key = ""
	_held_attach_pivot = Vector3(INF, INF, INF)
	_held_attach_snap_context.clear()


func _attach_pivot_key_for(target: Dictionary) -> String:
	var point := _quantize_vec3(
		Vector3(target.get("point", Vector3.ZERO)),
		0.1
	)
	var normal := _quantize_vec3(
		Vector3(target.get("normal", Vector3.UP)),
		0.1
	)
	return "%s|%s|%s" % [
		_tools.selected_archetype_id,
		point,
		normal,
	]


func _ground_pivot_key_for(target: Dictionary) -> String:
	var point := _quantize_vec3(
		Vector3(target.get("point", Vector3.ZERO)),
		0.1
	)
	var normal := _quantize_vec3(
		Vector3(target.get("normal", Vector3.UP)),
		0.1
	)
	return "%s|%s|%s" % [_tools.selected_archetype_id, point, normal]


func _apply_cached_mesh(
	archetype: ElementArchetype,
	orientation_index: int,
	valid: bool
) -> void:
	for child_node: Node in _mesh_root.get_children():
		_mesh_root.remove_child(child_node)
		child_node.queue_free()
	var cache_key := _cache_key(
		archetype.archetype_id,
		orientation_index,
		valid
	)
	if not _mesh_cache.has(cache_key):
		_mesh_cache[cache_key] = _build_mesh_nodes(
			archetype,
			orientation_index,
			Vector3i.ZERO,
			valid
		)
	for node: Node in _mesh_cache[cache_key]:
		_mesh_root.add_child(node.duplicate())


func _build_mesh_nodes(
	archetype: ElementArchetype,
	orientation_index: int,
	origin_cell: Vector3i,
	valid: bool
) -> Array[Node]:
	var mat := _valid_material if valid else _invalid_material
	var nodes: Array[Node] = []
	if archetype.piston_definition != null:
		var head_archetype := Slice01Archetypes.load_required(
			archetype.piston_definition.head_archetype_id
		)
		if head_archetype != null:
			nodes.append_array(
				PISTON_VISUAL_SCRIPT.build_placement_preview_nodes(
					archetype,
					head_archetype,
					origin_cell,
					orientation_index,
					valid
				)
			)
		nodes.append_array(
			_build_preview_port_markers(
				archetype,
				origin_cell,
				orientation_index
			)
		)
		return nodes
	if ROVER_MODULE_VISUAL_SCRIPT.is_rover_module(archetype.archetype_id):
		nodes.append_array(
			ROVER_MODULE_VISUAL_SCRIPT.build_placement_preview_nodes(
				archetype,
				origin_cell,
				orientation_index,
				valid
			)
		)
		nodes.append_array(
			_build_preview_port_markers(
				archetype,
				origin_cell,
				orientation_index
			)
		)
		return nodes
	if archetype.rotor_definition != null:
		var top_archetype := Slice01Archetypes.load_required(
			archetype.rotor_definition.top_archetype_id
		)
		if top_archetype != null:
			var top_origin := RotorPlacementUtil.top_origin_cell(
				origin_cell,
				orientation_index,
				archetype.rotor_definition
			)
			nodes.append_array(
				_build_collider_preview_nodes(
					top_archetype,
					top_origin,
					orientation_index,
					mat
				)
			)
	if archetype.hinge_definition != null:
		var hinge_top_archetype := Slice01Archetypes.load_required(
			archetype.hinge_definition.top_archetype_id
		)
		if hinge_top_archetype != null:
			var hinge_top_origin := HingePlacementUtil.top_origin_cell(
				origin_cell,
				orientation_index,
				archetype.hinge_definition
			)
			nodes.append_array(
				_build_collider_preview_nodes(
					hinge_top_archetype,
					hinge_top_origin,
					orientation_index,
					mat
				)
			)
	nodes.append_array(
		_build_collider_preview_nodes(
			archetype,
			origin_cell,
			orientation_index,
			mat
		)
	)
	nodes.append_array(
		_build_preview_port_markers(
			archetype,
			origin_cell,
			orientation_index
		)
	)
	if archetype.archetype_id == "stationary_drill":
		var drill_visual: Node3D = STATIONARY_DRILL_VISUAL_SCRIPT.instantiate_for_element(
			origin_cell,
			orientation_index,
			archetype
		)
		STATIONARY_DRILL_VISUAL_SCRIPT.apply_preview_material(
			drill_visual,
			mat
		)
		nodes.append(drill_visual)
	return nodes


func _build_collider_preview_nodes(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int,
	preview_material: Material
) -> Array[Node]:
	var nodes: Array[Node] = []
	# Wizard-baked parts ghost with their real model, not collider boxes.
	var scene_visual := _scene_visual_preview_node(
		archetype,
		origin_cell,
		orientation_index,
		preview_material
	)
	if scene_visual != null:
		nodes.append(scene_visual)
		return nodes
	var use_connected := CONNECTED_BLOCK_VISUAL_SCRIPT.is_connected_archetype(
		archetype.archetype_id
	)
	var rim_material := _connected_rim_preview_material(preview_material)
	for collider: ColliderDefinition in archetype.colliders:
		if (
			use_connected
			and collider.shape_kind == ColliderDefinition.ShapeKind.BOX
		):
			var root := Node3D.new()
			root.transform = GridPoseUtil.collider_local_transform(
				origin_cell,
				orientation_index,
				collider
			)
			var fill := MeshInstance3D.new()
			fill.mesh = CONNECTED_BLOCK_VISUAL_SCRIPT.make_fill_mesh(
				collider.size,
				0
			)
			fill.material_override = preview_material
			fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(fill)
			var rim := MeshInstance3D.new()
			rim.mesh = CONNECTED_BLOCK_VISUAL_SCRIPT.make_rim_mesh(
				collider.size,
				0
			)
			rim.material_override = rim_material
			rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(rim)
			nodes.append(root)
			continue
		var mesh := collider.make_preview_mesh(1.015)
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = preview_material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.transform = GridPoseUtil.collider_local_transform(
			origin_cell,
			orientation_index,
			collider
		)
		nodes.append(instance)
	return nodes


func _scene_visual_preview_node(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int,
	preview_material: Material
) -> Node3D:
	if archetype.visual_scene_path.is_empty():
		return null
	if not ResourceLoader.exists(archetype.visual_scene_path):
		return null
	var packed := load(archetype.visual_scene_path) as PackedScene
	if packed == null:
		return null
	var instance := packed.instantiate() as Node3D
	if instance == null:
		return null
	instance.transform = (
		GridPoseUtil.element_metric_transform(origin_cell, orientation_index)
		* Transform3D(Basis.IDENTITY, archetype.visual_offset)
	)
	_apply_preview_material_recursive(instance, preview_material)
	return instance


func _apply_preview_material_recursive(node: Node, material: Material) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		mesh_instance.material_override = material
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child: Node in node.get_children():
		_apply_preview_material_recursive(child, material)


func _connected_rim_preview_material(base: Material) -> Material:
	var source := base as StandardMaterial3D
	if source == null:
		return base
	var rim := source.duplicate() as StandardMaterial3D
	rim.albedo_color = source.albedo_color.darkened(0.45)
	rim.metallic = minf(source.metallic + 0.15, 1.0)
	return rim


func _build_preview_port_markers(
	archetype: ElementArchetype,
	origin_cell: Vector3i,
	orientation_index: int
) -> Array[Node]:
	var nodes: Array[Node] = []
	if archetype == null:
		return nodes
	var preview_element := SimulationElement.frame(
		-1,
		-1,
		archetype,
		origin_cell,
		orientation_index,
		{}
	)
	for port: PortDefinition in archetype.ports:
		if not IndustryPortUtil.is_industry_port(port):
			continue
		var marker_root := Node3D.new()
		marker_root.transform = IndustryPortUtil.port_marker_local_transform(
			preview_element,
			port
		)
		var color := (
			Color(0.95, 0.78, 0.16, 0.92)
			if port.kind == PortDefinition.Kind.ELECTRIC
			else Color(0.18, 0.82, 0.88, 0.92)
		)
		var mat := _preview_material(color)
		var disc := MeshInstance3D.new()
		var disc_mesh := CylinderMesh.new()
		disc_mesh.top_radius = 0.14
		disc_mesh.bottom_radius = 0.14
		disc_mesh.height = 0.02
		disc.mesh = disc_mesh
		disc.material_override = mat
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		marker_root.add_child(disc)
		var arrow := MeshInstance3D.new()
		var arrow_mesh := CylinderMesh.new()
		arrow_mesh.top_radius = 0.035
		arrow_mesh.bottom_radius = 0.035
		arrow_mesh.height = 0.18
		arrow.mesh = arrow_mesh
		arrow.material_override = mat
		arrow.position = Vector3(0.0, 0.1, 0.0)
		arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		marker_root.add_child(arrow)
		nodes.append(marker_root)
	return nodes


func _cache_key(
	archetype_id: String,
	orientation_index: int,
	valid: bool
) -> String:
	return "%s|%d|%s" % [archetype_id, orientation_index, valid]


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
			valid
		)
		if not _mesh_cache.has(cache_key):
			_mesh_cache[cache_key] = _build_mesh_nodes(
				archetype,
				_tools.selected_orientation_index,
				Vector3i.ZERO,
				valid
			)


func _sync_preview_visuals() -> void:
	if resolved_target.is_empty() or resolved_plan.is_empty():
		_hide_preview()
		return
	var archetype := resolved_plan.get("archetype") as ElementArchetype
	if archetype == null:
		_hide_preview()
		return
	var origin_cell: Vector3i = resolved_plan.get("origin_cell", Vector3i.ZERO)
	var orientation_index := int(
		resolved_plan.get("orientation_index", _tools.selected_orientation_index)
	)
	var valid := bool(resolved_plan.get("valid", false))
	var next_signature := _cache_key(
		archetype.archetype_id,
		orientation_index,
		valid
	)
	if next_signature != _signature:
		_apply_cached_mesh(archetype, orientation_index, valid)
		_signature = next_signature
	var pose_offset := Transform3D.IDENTITY
	var command := resolved_plan.get("command") as PlaceElementCommand
	if command != null:
		pose_offset = command.pose_offset
	# The ghost must sit exactly where the placed element will: the precise
	# connector pull (wheel hub onto axle slot) rides in as pose_offset.
	_mesh_root.transform = (
		GridPoseUtil.element_pose_delta(
			origin_cell,
			orientation_index,
			pose_offset
		)
		* Transform3D(Basis.IDENTITY, GridMetric.cell_to_meters(origin_cell))
	)
	global_transform = resolved_plan.get(
		"preview_root_transform",
		resolved_plan.get("assembly_world_transform", Transform3D.IDENTITY)
	)
	visible = true


func _on_selection_changed(
	archetype_id: String,
	orientation_index: int
) -> void:
	var archetype_changed := archetype_id != _selection_archetype_id
	_signature = ""
	_manual_candidate_index = -1
	_manual_lock = false
	_cached_resolve_context_key = ""
	if archetype_changed:
		_ground_pivot_key = ""
		_held_ground_pivot = Vector3(INF, INF, INF)
		_attach_pivot_key = ""
		_held_attach_pivot = Vector3(INF, INF, INF)
		_selection_archetype_id = archetype_id
		var archetype := Slice01Archetypes.load_required(archetype_id)
		_selection_footprint_cells = (
			archetype.footprint_cells.size() if archetype != null else 1
		)
	_gateway.reset_construction_snap()
	call_deferred("_warm_archetype", archetype_id, orientation_index)
	if not archetype_changed and _tools.active_tool == &"build":
		_update_resolution()
		_sync_preview_visuals()


func _on_active_tool_changed(_active_tool: StringName) -> void:
	_manual_candidate_index = -1
	_manual_lock = false
	_cached_resolve_context_key = ""
	_attach_pivot_key = ""
	_held_attach_pivot = Vector3(INF, INF, INF)
	_gateway.reset_construction_snap()


func _warm_archetype(archetype_id: String, orientation_index: int) -> void:
	var archetype := Slice01Archetypes.load_required(archetype_id)
	if archetype == null:
		return
	for valid: bool in [true, false]:
		var cache_key := _cache_key(
			archetype_id,
			orientation_index,
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
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	return mat
