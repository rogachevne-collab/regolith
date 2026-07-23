@tool
class_name SuspensionTravelMarker
extends Node3D

## Ход подвески «палкой»: два конца — где колесо стоит на полном ОТБОЕ (ниже
## всего) и куда оно уходит на полном СЖАТИИ (к раме). Тащи концы мышкой,
## длина палки и есть ход.
##
## Низ палки — это И ЕСТЬ гнездо колеса: деталь встаёт в мир именно так, а
## сжатие поднимает колесо вдоль оси «вверх» сборки. Поэтому отдельный маркер
## «гнездо колеса» с палкой не нужен — пекарь берёт отсюда и точку, и
## suspension_travel_m, руками число вводить больше не надо.

const PREVIEW_NODE_NAME := "_EditorSuspensionTravelPreview"
const MIN_TRAVEL_M := 0.02
## Насколько палка может отклониться от оси хода, прежде чем это станет
## предупреждением: ход всё равно считается по проекции на ось.
const MAX_OFF_AXIS_DEG := 5.0

## Второй конец палки, относительно самого маркера (part-local метры).
## Кто из концов низ, а кто верх, решает ось хода — тащи любой конец куда надо.
@export var top_offset: Vector3 = Vector3(0.0, 0.6, 0.0):
	set(value):
		top_offset = value
		_queue_preview_update()
		update_configuration_warnings()

## Колесо какого радиуса примерить: кольца на обоих пределах хода показывают,
## куда оно реально уедет. На испечённую деталь не влияет — это только превью.
@export var preview_wheel_radius_m: float = 0.4:
	set(value):
		preview_wheel_radius_m = maxf(value, 0.0)
		_queue_preview_update()

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
	# Маркер таскают обычным гизмо, а ось хода зависит от позы детали —
	# перерисовываем, как только что-то из этого поменялось.
	if _signature() != _preview_signature:
		_update_preview()


func _get_configuration_warnings() -> PackedStringArray:
	return get_diagnostics()


func authoring_root() -> PartAuthoringRoot:
	return get_parent() as PartAuthoringRoot


## Ось хода в координатах ДЕТАЛИ. Сжатие всегда идёт вдоль «вверх» СБОРКИ, а
## деталь встаёт в мир повёрнутой на default_orientation_index — значит здесь
## вверх это тот вектор, который после поворота станет мировым верхом.
func up_axis_local() -> Vector3:
	var root := authoring_root()
	if root == null:
		return Vector3.UP
	var axis: Vector3 = (
		OrientationUtil.orientation_basis(
			root.default_orientation_index
		).inverse()
		* Vector3.UP
	)
	if axis.is_zero_approx():
		return Vector3.UP
	return axis.normalized()


## Колесо на полном отбое — оно же точка гнезда.
func bottom_point_local() -> Vector3:
	return position if top_offset.dot(up_axis_local()) >= 0.0 else position + top_offset


## Колесо на полном сжатии.
func top_point_local() -> Vector3:
	return position + top_offset if top_offset.dot(up_axis_local()) >= 0.0 else position


## Ход, который уйдёт в бак: проекция палки на ось хода. Косая палка даёт
## меньше, чем её длина — об этом предупреждаем, а не молча округляем.
func travel_m() -> float:
	return absf(top_offset.dot(up_axis_local()))


func stick_length_m() -> float:
	return top_offset.length()


func off_axis_deg() -> float:
	var length := stick_length_m()
	if length <= 0.0001:
		return 0.0
	var cosine := clampf(absf(top_offset.dot(up_axis_local())) / length, 0.0, 1.0)
	return rad_to_deg(acos(cosine))


## Поставить палку по двум кликам. Порядок неважен: низ/верх разбираются по оси.
func set_points(first: Vector3, second: Vector3) -> void:
	position = first
	top_offset = second - first


## Задать ход числом: низ остаётся на месте, палка выпрямляется вдоль оси.
func set_travel_m(meters: float) -> void:
	var bottom := bottom_point_local()
	var axis := up_axis_local()
	position = bottom
	top_offset = axis * maxf(meters, MIN_TRAVEL_M)


## Гнездо колеса из низа палки. Грань футпринта резолвится ровно так же, как у
## обычного маркера, — мейтинг с колесом работает без изменений.
func to_socket_pad() -> StructuralMountPad:
	var root := authoring_root()
	if root == null:
		return null
	var bottom := bottom_point_local()
	var resolved := MountPadMarker.resolve_face_for_point(
		root.footprint_cells(),
		bottom
	)
	if resolved.is_empty():
		return null
	var pad := StructuralMountPad.new()
	pad.local_cell = resolved["cell"]
	pad.local_face = resolved["face"]
	pad.socket_tag = "wheel_socket"
	pad.exact_point = true
	pad.local_position = bottom
	return pad


func get_diagnostics() -> PackedStringArray:
	var messages := PackedStringArray()
	var root := authoring_root()
	if root == null:
		messages.append("палка хода должна быть ребёнком PartAuthoringRoot")
		return messages
	if root.part_kind != PartAuthoringRoot.PartKind.SUSPENSION:
		messages.append(
			"деталь не помечена как «Подвеска» — ход в бак не попадёт"
		)
	if travel_m() < MIN_TRAVEL_M:
		messages.append("палка нулевой длины — растяни её вдоль хода")
	elif off_axis_deg() > MAX_OFF_AXIS_DEG:
		messages.append(
			"палка косая (%.0f°): ход = %.2f м вместо длины %.2f м"
			% [off_axis_deg(), travel_m(), stick_length_m()]
		)
	if to_socket_pad() == null:
		messages.append("низ палки не привязался к детали — придвинь его к модели")
	return messages


## Ось колеса: нормаль грани, к которой привязался низ палки. По ней же
## ориентируются кольца превью.
func _axle_direction() -> Vector3:
	var root := authoring_root()
	if root == null:
		return Vector3.RIGHT
	var resolved := MountPadMarker.resolve_face_for_point(
		root.footprint_cells(),
		bottom_point_local()
	)
	if resolved.is_empty():
		return Vector3.RIGHT
	var face: OrientationUtil.Face = resolved["face"]
	return Vector3(OrientationUtil.face_to_vector(face))


func _signature() -> String:
	return "%s|%s|%.3f|%s" % [
		position,
		top_offset,
		preview_wheel_radius_m,
		up_axis_local(),
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

	# Всё рисуем относительно самого маркера.
	var bottom := bottom_point_local() - position
	var top := top_point_local() - position
	var stick := top - bottom
	var axle := _axle_direction()

	const BOTTOM_COLOR := Color(0.30, 0.85, 0.40)
	const TOP_COLOR := Color(0.95, 0.45, 0.25)
	const STICK_COLOR := Color(0.45, 0.80, 1.0)

	# Палка сквозь модель: без неё непонятно, где ход, если стойка внутри меша.
	if stick.length() > 0.0001:
		var shaft := MeshInstance3D.new()
		var shaft_mesh := CylinderMesh.new()
		shaft_mesh.top_radius = 0.014
		shaft_mesh.bottom_radius = 0.014
		shaft_mesh.height = stick.length()
		shaft.mesh = shaft_mesh
		shaft.material_override = _overlay_material(STICK_COLOR, 0.9)
		shaft.basis = MountPadMarker.basis_aligning_up_to(stick)
		shaft.position = bottom + stick * 0.5
		preview_root.add_child(shaft, false, Node.INTERNAL_MODE_BACK)

	_add_end(preview_root, bottom, BOTTOM_COLOR, axle, "низ • отбой")
	_add_end(
		preview_root,
		top,
		TOP_COLOR,
		axle,
		"верх • сжатие\nход %.2f м" % travel_m()
	)


## Один предел хода: шарик (это и есть точка), кольцо колеса и подпись.
func _add_end(
	preview_root: Node3D,
	point: Vector3,
	color: Color,
	axle: Vector3,
	text: String
) -> void:
	var ball := MeshInstance3D.new()
	var ball_mesh := SphereMesh.new()
	ball_mesh.radius = 0.05
	ball_mesh.height = 0.1
	ball.mesh = ball_mesh
	var solid := StandardMaterial3D.new()
	solid.albedo_color = color
	solid.emission_enabled = true
	solid.emission = color * 0.4
	solid.roughness = 0.5
	ball.material_override = solid
	ball.position = point
	preview_root.add_child(ball, false, Node.INTERNAL_MODE_BACK)

	# Кольцо = колесо на этом пределе. Именно оно показывает, что подвеска
	# «ходит» туда, куда автор думает, а не в середину собственной стойки.
	if preview_wheel_radius_m > 0.02:
		var ring := MeshInstance3D.new()
		var ring_mesh := TorusMesh.new()
		ring_mesh.outer_radius = preview_wheel_radius_m
		ring_mesh.inner_radius = maxf(preview_wheel_radius_m - 0.03, 0.005)
		ring.mesh = ring_mesh
		ring.material_override = _overlay_material(color, 0.35)
		ring.basis = MountPadMarker.basis_aligning_up_to(axle)
		ring.position = point
		preview_root.add_child(ring, false, Node.INTERNAL_MODE_BACK)

	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0006
	label.modulate = color
	label.outline_size = 8
	label.position = point
	label.offset = Vector2(0.0, 24.0)
	preview_root.add_child(label, false, Node.INTERNAL_MODE_BACK)


## Видно сквозь модель — иначе ход подвески прячется внутри собственной стойки.
func _overlay_material(color: Color, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, alpha)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.render_priority = 9
	return material


func _remove_preview() -> void:
	var preview := get_node_or_null(PREVIEW_NODE_NAME)
	if preview != null:
		remove_child(preview)
		preview.free()
