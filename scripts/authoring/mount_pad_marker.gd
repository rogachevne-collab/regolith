@tool
class_name MountPadMarker
extends Node3D

## Human-authored mount point on a single part. Drop it as a child of a
## PartAuthoringRoot, drag it onto a face of the footprint, and pick a kind.
## The marker snaps to the nearest external cell face and resolves the
## (local_cell, local_face, socket_tag) triple a StructuralMountPad needs —
## the author never types cell coordinates or face enum integers.

const PREVIEW_NODE_NAME := "_EditorMountPadPreview"

enum SocketKind {
	STRUCTURAL,   ## bolts onto a frame / another structural face (empty tag)
	WHEEL_SOCKET, ## a wheel plugs into here
	WHEEL_PLUG,   ## this is a wheel's plug
	CUSTOM,       ## use custom_tag verbatim
}

@export var socket_kind: SocketKind = SocketKind.STRUCTURAL:
	set(value):
		socket_kind = value
		_queue_preview_update()
		update_configuration_warnings()

## Only used when socket_kind == CUSTOM.
@export var custom_tag: String = "":
	set(value):
		custom_tag = value
		update_configuration_warnings()

## Keep the marker glued to the nearest face while dragging in the editor.
@export var snap_to_face: bool = true

var _resolved_cell: Vector3i = Vector3i.ZERO
var _resolved_face: OrientationUtil.Face = OrientationUtil.Face.POS_Y
var _resolved_ok: bool = false
var _last_snapped_position: Vector3 = Vector3.ZERO
var _preview_update_queued := false


func _ready() -> void:
	if Engine.is_editor_hint():
		resolve()
		_update_preview()
	else:
		_remove_preview()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	if snap_to_face and position != _last_snapped_position:
		resolve()
		_update_preview()


func _get_configuration_warnings() -> PackedStringArray:
	return get_diagnostics()


## Socket tag written to the baked StructuralMountPad.
func socket_tag() -> String:
	match socket_kind:
		SocketKind.STRUCTURAL:
			return ""
		SocketKind.WHEEL_SOCKET:
			return "wheel_socket"
		SocketKind.WHEEL_PLUG:
			return "wheel_plug"
		SocketKind.CUSTOM:
			return custom_tag
	return ""


func authoring_root() -> PartAuthoringRoot:
	return get_parent() as PartAuthoringRoot


## Footprint cells this marker snaps against, in part-local grid space.
func _footprint_cells() -> Array[Vector3i]:
	var root := authoring_root()
	if root == null:
		return []
	return root.footprint_cells()


## Find the external footprint face nearest to the marker's local position.
## Sets _resolved_cell / _resolved_face; snaps position onto that face.
func resolve() -> bool:
	_resolved_ok = false
	var cells := _footprint_cells()
	if cells.is_empty():
		_last_snapped_position = position
		return false
	var occupied: Dictionary = {}
	for cell: Vector3i in cells:
		occupied[cell] = true

	var best_cell := Vector3i.ZERO
	var best_face := OrientationUtil.Face.POS_Y
	var best_center := Vector3.ZERO
	var best_distance := INF
	for cell: Vector3i in cells:
		for face: OrientationUtil.Face in _all_faces():
			var neighbour := cell + OrientationUtil.face_to_vector(face)
			if occupied.has(neighbour):
				continue  # internal face — nothing can mount there
			var center := (
				GridMetric.cell_center_meters(cell)
				+ Vector3(OrientationUtil.face_to_vector(face))
				* GridMetric.HALF_CELL_SIZE_M
			)
			var distance := position.distance_to(center)
			if distance < best_distance:
				best_distance = distance
				best_cell = cell
				best_face = face
				best_center = center

	if best_distance == INF:
		_last_snapped_position = position
		return false

	_resolved_cell = best_cell
	_resolved_face = best_face
	_resolved_ok = true
	if snap_to_face and Engine.is_editor_hint():
		position = best_center
	_last_snapped_position = position
	return true


func resolved_cell() -> Vector3i:
	return _resolved_cell


func resolved_face() -> OrientationUtil.Face:
	return _resolved_face


## Build the StructuralMountPad this marker represents, or null if unresolved.
func to_pad() -> StructuralMountPad:
	if not resolve():
		return null
	var pad := StructuralMountPad.new()
	pad.local_cell = _resolved_cell
	pad.local_face = _resolved_face
	pad.socket_tag = socket_tag()
	return pad


func get_diagnostics() -> PackedStringArray:
	var messages: PackedStringArray = PackedStringArray()
	if authoring_root() == null:
		messages.append("must be a child of a PartAuthoringRoot")
	elif _footprint_cells().is_empty():
		messages.append("root archetype has no footprint to snap against")
	elif not _resolved_ok:
		messages.append("could not resolve a face (drag onto the part)")
	if socket_kind == SocketKind.CUSTOM and custom_tag.strip_edges().is_empty():
		messages.append("CUSTOM kind needs a non-empty custom_tag")
	return messages


func _all_faces() -> Array:
	return [
		OrientationUtil.Face.POS_X,
		OrientationUtil.Face.NEG_X,
		OrientationUtil.Face.POS_Y,
		OrientationUtil.Face.NEG_Y,
		OrientationUtil.Face.POS_Z,
		OrientationUtil.Face.NEG_Z,
	]


func _tag_color() -> Color:
	match socket_kind:
		SocketKind.STRUCTURAL:
			return Color(0.25, 0.55, 0.95, 0.75)
		SocketKind.WHEEL_SOCKET:
			return Color(0.30, 0.85, 0.40, 0.85)
		SocketKind.WHEEL_PLUG:
			return Color(0.95, 0.60, 0.20, 0.85)
		SocketKind.CUSTOM:
			return Color(0.75, 0.40, 0.90, 0.85)
	return Color.WHITE


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
	if not Engine.is_editor_hint():
		return

	var preview_root := Node3D.new()
	preview_root.name = PREVIEW_NODE_NAME
	preview_root.set_meta("_edit_lock_", true)
	add_child(preview_root, false, Node.INTERNAL_MODE_BACK)

	var color := _tag_color()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Disc on the face plane…
	var disc := MeshInstance3D.new()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = GridMetric.HALF_CELL_SIZE_M * 0.7
	disc_mesh.bottom_radius = disc_mesh.top_radius
	disc_mesh.height = 0.02
	disc.mesh = disc_mesh
	disc.material_override = mat
	var normal := Vector3(OrientationUtil.face_to_vector(_resolved_face))
	disc.basis = _basis_aligning_up_to(normal)
	preview_root.add_child(disc, false, Node.INTERNAL_MODE_BACK)

	# …and an arrow pointing outward along the face normal.
	var arrow := MeshInstance3D.new()
	var arrow_mesh := CylinderMesh.new()
	arrow_mesh.top_radius = 0.0
	arrow_mesh.bottom_radius = 0.06
	arrow_mesh.height = 0.16
	arrow.mesh = arrow_mesh
	arrow.material_override = mat
	arrow.basis = disc.basis
	arrow.position = normal * 0.12
	preview_root.add_child(arrow, false, Node.INTERNAL_MODE_BACK)


func _basis_aligning_up_to(direction: Vector3) -> Basis:
	if direction.is_zero_approx():
		return Basis.IDENTITY
	var up := direction.normalized()
	var reference := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x_axis := reference.cross(up).normalized()
	var z_axis := x_axis.cross(up).normalized()
	return Basis(x_axis, up, z_axis)


func _remove_preview() -> void:
	var preview := get_node_or_null(PREVIEW_NODE_NAME)
	if preview != null:
		remove_child(preview)
		preview.free()
