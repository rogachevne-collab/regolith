@tool
class_name WheelTireMarker
extends Node3D

## Цилиндр шины: где крутится колесо (центр + радиус + ширина).
## Точка «ось колеса» (MountPadMarker / wheel_plug) остаётся СТЫКОМ — кончик
## ступицы к гнезду подвески. Этот маркер отвечает только за хаб качения.

const PREVIEW_NODE_NAME := "_EditorWheelTirePreview"
const MIN_RADIUS_M := 0.05
const MIN_WIDTH_M := 0.05

@export var radius_m: float = 0.4:
	set(value):
		radius_m = maxf(value, MIN_RADIUS_M)
		_queue_preview_update()
		update_configuration_warnings()

@export var width_m: float = 0.3:
	set(value):
		width_m = maxf(value, MIN_WIDTH_M)
		_queue_preview_update()
		update_configuration_warnings()

var _preview_signature := ""
var _preview_update_queued := false


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_preview()
	else:
		_remove_preview()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	if _signature() != _preview_signature:
		_update_preview()


func _get_configuration_warnings() -> PackedStringArray:
	return get_diagnostics()


func authoring_root() -> PartAuthoringRoot:
	return get_parent() as PartAuthoringRoot


## Центр шины в координатах детали — хаб для физики и визуала.
func hub_point_local() -> Vector3:
	return position


## Ось цилиндра: нормаль грани plug-маркера, иначе оценка по футпринту.
func axle_direction_local() -> Vector3:
	var root := authoring_root()
	if root == null:
		return Vector3.RIGHT
	for marker: MountPadMarker in root.collect_pad_markers():
		if marker.socket_kind != MountPadMarker.SocketKind.WHEEL_PLUG:
			continue
		var resolved := MountPadMarker.resolve_face_for_point(
			root.footprint_cells(),
			marker.position
		)
		if resolved.is_empty():
			break
		var face: OrientationUtil.Face = resolved["face"]
		return Vector3(OrientationUtil.face_to_vector(face)).normalized()
	var resolved_hub := MountPadMarker.resolve_face_for_point(
		root.footprint_cells(),
		position
	)
	if resolved_hub.is_empty():
		return Vector3.RIGHT
	var hub_face: OrientationUtil.Face = resolved_hub["face"]
	return Vector3(OrientationUtil.face_to_vector(hub_face)).normalized()


func set_from_click(local_point: Vector3) -> void:
	position = local_point


func fit_defaults_from_root() -> void:
	var root := authoring_root()
	if root == null:
		return
	radius_m = maxf(root.wheel_radius_m, MIN_RADIUS_M)
	width_m = maxf(root.wheel_radius_m * 0.75, MIN_WIDTH_M)
	var plug := _plug_point_local(root)
	if plug.is_finite():
		# Центр шины — от кончика ступицы ПРОТИВ нормали plug (нормаль
		# смотрит из tip наружу, шина лежит с другой стороны).
		position = plug - axle_direction_local() * (width_m * 0.5)
	else:
		position = Vector3(root.size_cells) * GridMetric.CELL_SIZE_M * 0.5


func get_diagnostics() -> PackedStringArray:
	var messages := PackedStringArray()
	var root := authoring_root()
	if root == null:
		messages.append("цилиндр шины должен быть ребёнком PartAuthoringRoot")
		return messages
	if root.part_kind != PartAuthoringRoot.PartKind.WHEEL:
		messages.append("деталь не помечена как «Колесо» — цилиндр в бак не попадёт")
	if radius_m < MIN_RADIUS_M:
		messages.append("радиус шины слишком мал")
	if width_m < MIN_WIDTH_M:
		messages.append("ширина шины слишком мала")
	var plug := _plug_point_local(root)
	if plug.is_finite():
		var axle := axle_direction_local()
		var delta := hub_point_local() - plug
		var radial := delta - axle * delta.dot(axle)
		if radial.length() > 0.05:
			messages.append(
				"центр шины не на оси ступицы (%.2f м в сторону) — подвинь цилиндр"
				% radial.length()
			)
	return messages


func _plug_point_local(root: PartAuthoringRoot) -> Vector3:
	for marker: MountPadMarker in root.collect_pad_markers():
		if marker.socket_kind == MountPadMarker.SocketKind.WHEEL_PLUG:
			return marker.position
	return Vector3(INF, INF, INF)


func _signature() -> String:
	return "%s|%.3f|%.3f|%s" % [
		position,
		radius_m,
		width_m,
		axle_direction_local(),
	]


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
	_preview_signature = _signature()

	var preview_root := Node3D.new()
	preview_root.name = PREVIEW_NODE_NAME
	preview_root.set_meta("_edit_lock_", true)
	add_child(preview_root, false, Node.INTERNAL_MODE_BACK)

	const TIRE_COLOR := Color(0.35, 0.75, 1.0)
	var axle := axle_direction_local()

	var tire := MeshInstance3D.new()
	var tire_mesh := CylinderMesh.new()
	tire_mesh.top_radius = radius_m
	tire_mesh.bottom_radius = radius_m
	tire_mesh.height = width_m
	tire.mesh = tire_mesh
	tire.material_override = _overlay_material(TIRE_COLOR, 0.28)
	# CylinderMesh ось = +Y → кладём на ось ступицы.
	tire.basis = MountPadMarker.basis_aligning_up_to(axle)
	tire.position = Vector3.ZERO
	preview_root.add_child(tire, false, Node.INTERNAL_MODE_BACK)

	var hub_ball := MeshInstance3D.new()
	var hub_mesh := SphereMesh.new()
	hub_mesh.radius = 0.04
	hub_mesh.height = 0.08
	hub_ball.mesh = hub_mesh
	var solid := StandardMaterial3D.new()
	solid.albedo_color = TIRE_COLOR
	solid.emission_enabled = true
	solid.emission = TIRE_COLOR * 0.45
	hub_ball.material_override = solid
	preview_root.add_child(hub_ball, false, Node.INTERNAL_MODE_BACK)

	var label := Label3D.new()
	label.text = "шина • Ø %.2f × %.2f м" % [radius_m * 2.0, width_m]
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0006
	label.modulate = TIRE_COLOR
	label.outline_size = 8
	label.position = axle * (width_m * 0.5 + 0.08)
	preview_root.add_child(label, false, Node.INTERNAL_MODE_BACK)


func _overlay_material(color: Color, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 9
	return material


func _remove_preview() -> void:
	var preview := get_node_or_null(PREVIEW_NODE_NAME)
	if preview != null:
		remove_child(preview)
		preview.free()
