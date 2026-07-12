@tool
class_name ElementMarker
extends Node3D

const PREVIEW_NODE_NAME := "_EditorFootprintPreview"

@export var local_id: String = "":
	set(value):
		local_id = value
		update_configuration_warnings()

@export var archetype: ElementArchetype:
	set(value):
		archetype = value
		_queue_preview_update()
		update_configuration_warnings()

@export_range(0, 23, 1) var orientation_index: int = 0:
	set(value):
		orientation_index = value
		_queue_preview_update()
		update_configuration_warnings()

@export var snap_to_grid: bool = true

var _last_snapped_position: Vector3 = Vector3.ZERO
var _preview_update_queued := false


func _ready() -> void:
	if Engine.is_editor_hint():
		_snap_position()
		_update_preview()
	else:
		_remove_preview()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	if snap_to_grid and position != _last_snapped_position:
		_snap_position()


func _get_configuration_warnings() -> PackedStringArray:
	return get_diagnostics()


func _snap_position() -> void:
	position = Vector3(
		roundf(position.x),
		roundf(position.y),
		roundf(position.z)
	)
	_last_snapped_position = position


func to_placement() -> BlueprintElementPlacement:
	if local_id.is_empty() or archetype == null:
		return null
	var placement := BlueprintElementPlacement.new()
	placement.local_id = local_id
	placement.archetype = archetype
	placement.origin_cell = Vector3i(
		int(round(position.x)),
		int(round(position.y)),
		int(round(position.z))
	)
	placement.orientation_index = orientation_index
	return placement


func get_diagnostics() -> PackedStringArray:
	var messages: PackedStringArray = PackedStringArray()
	if local_id.is_empty():
		messages.append("local_id is empty")
	if archetype == null:
		messages.append("archetype is not assigned")
	elif archetype.archetype_id.is_empty():
		messages.append("archetype_id is empty")
	if (
		orientation_index < 0
		or orientation_index >= OrientationUtil.ORIENTATION_COUNT
	):
		messages.append(
			"orientation_index %d out of range 0..%d"
			% [
				orientation_index,
				OrientationUtil.ORIENTATION_COUNT - 1,
			]
		)
	return messages


func preview_local_centers() -> Array[Vector3]:
	var centers: Array[Vector3] = []
	if archetype == null:
		return centers
	for cell: Vector3i in archetype.footprint_cells:
		var rotated: Vector3i = OrientationUtil.rotate_cell(
			cell,
			orientation_index
		)
		centers.append(Vector3(rotated) + Vector3(0.5, 0.5, 0.5))
	return centers


func _queue_preview_update() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _preview_update_queued:
		return
	_preview_update_queued = true
	call_deferred("_update_preview")


func _update_preview() -> void:
	_preview_update_queued = false
	_remove_preview()
	if not Engine.is_editor_hint() or archetype == null:
		return
	if (
		orientation_index < 0
		or orientation_index >= OrientationUtil.ORIENTATION_COUNT
	):
		return

	var preview_root := Node3D.new()
	preview_root.name = PREVIEW_NODE_NAME
	preview_root.set_meta("_edit_lock_", true)
	add_child(preview_root, false, Node.INTERNAL_MODE_BACK)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.65, 0.95, 0.35)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for center: Vector3 in preview_local_centers():
		var mesh_instance := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE
		mesh_instance.mesh = mesh
		mesh_instance.position = center
		mesh_instance.material_override = material
		preview_root.add_child(
			mesh_instance,
			false,
			Node.INTERNAL_MODE_BACK
		)


func _remove_preview() -> void:
	var preview := get_node_or_null(PREVIEW_NODE_NAME)
	if preview != null:
		remove_child(preview)
		preview.free()
