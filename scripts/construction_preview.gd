class_name ConstructionPreview
extends Node3D

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")
@export var gateway_path: NodePath = NodePath("../../WorldCommandGateway")

var _query: InteractionQuery
var _tools: ToolController
var _gateway: WorldCommandGateway
var _valid_material: StandardMaterial3D
var _invalid_material: StandardMaterial3D
var _signature := ""


func _ready() -> void:
	top_level = true
	_query = get_node(query_path)
	_tools = get_node(tool_controller_path)
	_gateway = get_node(gateway_path)
	_valid_material = _preview_material(Color(0.2, 0.95, 1.0, 0.35))
	_invalid_material = _preview_material(Color(1.0, 0.2, 0.15, 0.3))
	visible = false


func _process(_delta: float) -> void:
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
		_hide_preview()
		return
	var hit := _query.current_hit
	if not _should_preview(hit):
		_hide_preview()
		return
	var plan := _gateway.preview_construction(
		hit.snapshot(),
		_tools.selected_archetype_id,
		_tools.selected_orientation_index
	)
	var archetype := plan.get("archetype") as ElementArchetype
	if archetype == null:
		_hide_preview()
		return
	var next_signature := "%s|%d|%s" % [
		archetype.archetype_id,
		_tools.selected_orientation_index,
		str(bool(plan.get("valid", false))),
	]
	if next_signature != _signature:
		_rebuild(
			archetype,
			_tools.selected_orientation_index,
			bool(plan.get("valid", false))
		)
		_signature = next_signature
	global_transform = plan.get("world_transform", Transform3D.IDENTITY)
	visible = true


func _should_preview(hit: InteractionHit) -> bool:
	if not hit.valid:
		return false
	if hit.target_kind == InteractionHit.KIND_VOXEL:
		return _tools.selected_archetype_id == "foundation"
	if hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT:
		return false
	return StringName(
		hit.metadata.get("status_reason", &"element_incomplete")
	) == &"ok"


func _rebuild(
	archetype: ElementArchetype,
	_orientation_index: int,
	valid: bool
) -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	var material := _valid_material if valid else _invalid_material
	for collider: ColliderDefinition in archetype.colliders:
		if collider.shape_kind != ColliderDefinition.ShapeKind.BOX:
			continue
		var mesh := BoxMesh.new()
		mesh.size = collider.size * 1.015
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.transform = Transform3D(
			Basis.IDENTITY,
			Vector3(collider.local_cell) + collider.offset_in_cell
		)
		add_child(instance)


func _hide_preview() -> void:
	visible = false


func _preview_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material
