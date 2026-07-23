@tool
extends EditorPlugin

## «Мастер деталей»: dock со степами (модель → поза → крепления → испечь)
## плюс режим «поставить точку крепления кликом по модели» прямо в 3D-вью.

const _DockScript := preload("res://addons/part_wizard/part_wizard_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = _DockScript.new()
	_dock.name = "Мастер деталей"
	_dock.plugin = self
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.free()
		_dock = null


func _handles(object: Object) -> bool:
	# Claim the 3D viewport whenever a part scene is being edited so the
	# click-to-place-connector mode receives input — no matter which node
	# inside the part scene happens to be selected.
	if (
		object is PartAuthoringRoot
		or object is MountPadMarker
		or object is SuspensionTravelMarker
	):
		return true
	return (
		object is Node
		and EditorInterface.get_edited_scene_root() is PartAuthoringRoot
	)


func _forward_3d_gui_input(
	viewport_camera: Camera3D,
	event: InputEvent
) -> int:
	if _dock == null or not _dock.place_mode_active():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var root := _edited_part_root()
	if root == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var button := event as InputEventMouseButton
	if (
		button == null
		or button.button_index != MOUSE_BUTTON_LEFT
		or not button.pressed
	):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var hit := _raycast_part_meshes(viewport_camera, button.position, root)
	if hit.is_empty():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	_dock.handle_viewport_click(root, hit["point"], hit["normal"])
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _edited_part_root() -> PartAuthoringRoot:
	var scene_root := EditorInterface.get_edited_scene_root()
	return scene_root as PartAuthoringRoot


## Editor-scene meshes have no physics bodies, so intersect the ray with the
## visible triangles directly. Authoring models are small; this is instant.
func _raycast_part_meshes(
	camera: Camera3D,
	screen_position: Vector2,
	root: Node3D
) -> Dictionary:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var best: Dictionary = {}
	var best_distance := INF
	for mesh_instance: MeshInstance3D in _collect_mesh_instances(root):
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		var to_global := mesh_instance.global_transform
		var faces := mesh.get_faces()
		var triangle_count := int(faces.size() / 3.0)
		for triangle: int in range(triangle_count):
			var a := to_global * faces[triangle * 3]
			var b := to_global * faces[triangle * 3 + 1]
			var c := to_global * faces[triangle * 3 + 2]
			var point: Variant = Geometry3D.ray_intersects_triangle(
				origin,
				direction,
				a,
				b,
				c
			)
			if point == null:
				continue
			var distance := (point as Vector3).distance_to(origin)
			if distance >= best_distance:
				continue
			best_distance = distance
			best = {
				"point": root.global_transform.affine_inverse() * (point as Vector3),
				"normal": (
					root.global_transform.basis.inverse()
					* (b - a).cross(c - a)
				).normalized(),
			}
	return best


## Editor decoration is not clickable geometry: the footprint ghost, the
## connector balls and the travel stick would otherwise swallow the click that
## was aimed at the model behind them. The visual preview IS the model, so it
## stays in.
const _NON_CLICKABLE := [
	PartAuthoringRoot.FOOTPRINT_PREVIEW_NAME,
	MountPadMarker.PREVIEW_NODE_NAME,
	SuspensionTravelMarker.PREVIEW_NODE_NAME,
	WheelTireMarker.PREVIEW_NODE_NAME,
]


func _collect_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if _NON_CLICKABLE.has(str(current.name)):
			continue
		var mesh_instance := current as MeshInstance3D
		if mesh_instance != null:
			result.append(mesh_instance)
		for child: Node in current.get_children(true):
			stack.append(child)
	return result
