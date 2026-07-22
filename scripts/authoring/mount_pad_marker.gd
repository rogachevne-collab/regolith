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
	STRUCTURAL,    ## bolts onto a frame / another structural face (empty tag)
	WHEEL_SOCKET,  ## a wheel plugs into here
	WHEEL_PLUG,    ## this is a wheel's plug
	CUSTOM,        ## use custom_tag verbatim
	ELECTRIC_PORT, ## optional electrical connection point (not every part needs one)
}

## Only meaningful when socket_kind == ELECTRIC_PORT.
enum PortRole {
	BIDIRECTIONAL, ## can send or receive power
	IN,            ## draws power only
	OUT,           ## supplies power only
}

@export var socket_kind: SocketKind = SocketKind.STRUCTURAL:
	set(value):
		socket_kind = value
		_queue_preview_update()
		update_configuration_warnings()
		notify_property_list_changed()

## Only used when socket_kind == CUSTOM.
@export var custom_tag: String = "":
	set(value):
		custom_tag = value
		update_configuration_warnings()

## Only used when socket_kind == ELECTRIC_PORT.
@export var port_role: PortRole = PortRole.BIDIRECTIONAL:
	set(value):
		port_role = value
		_queue_preview_update()

## ON  — grid block behaviour: the point snaps to the centre of the nearest
##       cell face while you drag it.
## OFF — precise part behaviour: the point stays exactly where you put it (the
##       hub slot, the wheel centre). The cell/face are still derived from it
##       automatically, so mating with other parts keeps working.
@export var snap_to_face: bool = true:
	set(value):
		snap_to_face = value
		if is_inside_tree():
			resolve()
			_queue_preview_update()

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


func _validate_property(property: Dictionary) -> void:
	var prop_name := str(property.name)
	if prop_name == "custom_tag" and socket_kind != SocketKind.CUSTOM:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if prop_name == "port_role" and socket_kind != SocketKind.ELECTRIC_PORT:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func is_electric() -> bool:
	return socket_kind == SocketKind.ELECTRIC_PORT


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
		SocketKind.ELECTRIC_PORT:
			return "electric"
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


## Build the StructuralMountPad this marker represents, or null if unresolved
## or if this marker is an electrical port (see to_port() for those).
func to_pad() -> StructuralMountPad:
	if is_electric():
		return null
	if not resolve():
		return null
	var pad := StructuralMountPad.new()
	pad.local_cell = _resolved_cell
	pad.local_face = _resolved_face
	pad.socket_tag = socket_tag()
	if not snap_to_face:
		# Precise part: keep the point exactly where the author put it.
		pad.exact_point = true
		pad.local_position = position
	return pad


## Build the PortDefinition this marker represents, or null if unresolved or
## if this marker isn't an electrical port. `port_id` is assigned by the
## authoring root so multiple electric markers on one part stay unique;
## direction ("_in"/"_out"/"_io" suffix) is read from it at runtime by
## IndustryElectricPortUtil.electric_direction().
func to_port(port_id: String) -> PortDefinition:
	if not is_electric():
		return null
	if not resolve():
		return null
	var port := PortDefinition.new()
	port.port_id = port_id
	port.kind = PortDefinition.Kind.ELECTRIC
	port.local_cell = _resolved_cell
	port.local_face = _resolved_face
	# Every electric port needs the "electric" tag to conduct at all
	# (IndustryElectricPortUtil._electric_tags_compatible) — not an authoring
	# choice, just what makes the port a port.
	port.compatibility_tags = PackedStringArray(["electric"])
	return port


## Suffix that encodes port_role for IndustryElectricPortUtil.electric_direction().
func port_role_suffix() -> String:
	match port_role:
		PortRole.IN:
			return "in"
		PortRole.OUT:
			return "out"
		_:
			return "io"


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
		SocketKind.ELECTRIC_PORT:
			return Color(0.95, 0.90, 0.15, 0.9)
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
	# Shaded + a touch of emission: readable depth while dragging, still
	# visible in dark corners. The old flat unshaded cone read as a floating
	# "spike to stab somewhere", which it never was.
	var solid := StandardMaterial3D.new()
	solid.albedo_color = Color(color.r, color.g, color.b, 1.0)
	solid.emission_enabled = true
	solid.emission = Color(color.r, color.g, color.b) * 0.35
	solid.roughness = 0.5

	var normal := Vector3(OrientationUtil.face_to_vector(_resolved_face))
	var along := _basis_aligning_up_to(normal)

	# The attach POINT itself — this is what mates with the other part.
	var point := MeshInstance3D.new()
	var point_mesh := SphereMesh.new()
	point_mesh.radius = 0.045
	point_mesh.height = 0.09
	point.mesh = point_mesh
	point.material_override = solid
	preview_root.add_child(point, false, Node.INTERNAL_MODE_BACK)

	# Crosshair through the centre: the CENTRE of the ball is the point that
	# mates, the ball radius is pure cosmetics. Drawn on top of everything so
	# it stays readable inside a hub.
	var cross_mat := StandardMaterial3D.new()
	cross_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.95)
	cross_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cross_mat.no_depth_test = true
	cross_mat.render_priority = 10
	for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		var bar := MeshInstance3D.new()
		var bar_mesh := CylinderMesh.new()
		bar_mesh.top_radius = 0.005
		bar_mesh.bottom_radius = 0.005
		bar_mesh.height = 0.16
		bar.mesh = bar_mesh
		bar.material_override = cross_mat
		bar.basis = _basis_aligning_up_to(axis)
		preview_root.add_child(bar, false, Node.INTERNAL_MODE_BACK)

	# Arrow OUTWARD along the mating direction: "the other part arrives from
	# here". Shaft + head so it reads as an arrow, not a lone cone.
	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.015
	shaft_mesh.bottom_radius = 0.015
	shaft_mesh.height = 0.14
	shaft.mesh = shaft_mesh
	shaft.material_override = solid
	shaft.basis = along
	shaft.position = normal * 0.11
	preview_root.add_child(shaft, false, Node.INTERNAL_MODE_BACK)
	var head := MeshInstance3D.new()
	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = 0.045
	head_mesh.height = 0.09
	head.mesh = head_mesh
	head.material_override = solid
	head.basis = along
	head.position = normal * 0.22
	preview_root.add_child(head, false, Node.INTERNAL_MODE_BACK)

	# Face disc only in grid-snap mode — precise points live off the face
	# plane and the big disc just confused the picture there.
	if snap_to_face:
		var translucent := StandardMaterial3D.new()
		translucent.albedo_color = Color(color.r, color.g, color.b, 0.35)
		translucent.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var disc := MeshInstance3D.new()
		var disc_mesh := CylinderMesh.new()
		disc_mesh.top_radius = GridMetric.HALF_CELL_SIZE_M * 0.7
		disc_mesh.bottom_radius = disc_mesh.top_radius
		disc_mesh.height = 0.01
		disc.mesh = disc_mesh
		disc.material_override = translucent
		disc.basis = along
		preview_root.add_child(disc, false, Node.INTERNAL_MODE_BACK)

	# Name tag so the author never guesses which kind this point is.
	var label := Label3D.new()
	label.text = _kind_label()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0006
	label.modulate = Color(color.r, color.g, color.b, 0.95)
	label.outline_size = 8
	label.position = normal * 0.3
	preview_root.add_child(label, false, Node.INTERNAL_MODE_BACK)


func _kind_label() -> String:
	match socket_kind:
		SocketKind.STRUCTURAL:
			return "крепление"
		SocketKind.WHEEL_SOCKET:
			return "гнездо колеса"
		SocketKind.WHEEL_PLUG:
			return "ось колеса"
		SocketKind.CUSTOM:
			return custom_tag if not custom_tag.is_empty() else "свой тег"
		SocketKind.ELECTRIC_PORT:
			match port_role:
				PortRole.IN:
					return "⚡ вход"
				PortRole.OUT:
					return "⚡ выход"
				_:
					return "⚡ вход/выход"
	return ""


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
