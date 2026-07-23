extends Node3D
## Нарисованное колесо обязано совпадать с физическим.
##
## Физика крутит тело вокруг оси в точке `axle_point_assembly_local` и ставит
## туда цилиндр размером `radius_m` × `width_m`. Игрок видит меш. Разошлись —
## колесо либо катится по воздуху, либо тонет в грунте, либо (если разъехались
## центры) шина обходит стойку по кругу вместо того, чтобы вращаться. Ни один
## зелёный тест этого не ловил: расхождение видно только глазом.
##
## Здесь оно меряется числом. Риг строится тем же кодом, что и в игре, шина —
## самый крупный меш в риге.

const _HeadlessTestHarness := preload(
	"res://scripts/testing/headless_test_harness.gd"
)
## Модели рисуются руками, точного равенства не будет. 5 см — предел, за
## которым расхождение уже видно в игре.
const FIT_TOLERANCE_M := 0.05


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "WHEEL-VISUAL-FIT")
	var failures: Array[String] = []
	var checked := 0
	for archetype: ElementArchetype in _wheel_archetypes():
		var measured := _measure(archetype)
		if measured.is_empty():
			print("FIT %s: no visual to measure" % archetype.archetype_id)
			continue
		checked += 1
		var definition: WheelDefinition = archetype.wheel_definition
		var radius: float = measured["radius_m"]
		var width: float = measured["width_m"]
		var offset: float = measured["axle_offset_m"]
		var axial: float = measured["axial_offset_m"]
		print(
			"FIT %s: radius %.3f/%.3f  width %.3f/%.3f  off-axis %.3f  along-axis %.3f"
			% [
				archetype.archetype_id,
				radius,
				definition.radius_m,
				width,
				definition.width_m,
				offset,
				axial,
			]
		)
		var axle := _physics_axle(archetype)
		if absf(axle.dot(Vector3.UP)) > 0.01:
			failures.append(
				"%s: physics axle %v is not horizontal — the wheel is a spinning top"
				% [archetype.archetype_id, axle]
			)
		if offset > FIT_TOLERANCE_M:
			failures.append(
				"%s: mesh centre is %.3f m off the axle LINE — the tire orbits"
				% [archetype.archetype_id, offset]
			)
		if axial > FIT_TOLERANCE_M:
			failures.append(
				"%s: mesh sits %.3f m sideways along the axle from the hub"
				% [archetype.archetype_id, axial]
			)
		if absf(radius - definition.radius_m) > FIT_TOLERANCE_M:
			failures.append(
				"%s: radius_m %.3f but the mesh is %.3f"
				% [archetype.archetype_id, definition.radius_m, radius]
			)
		if absf(width - definition.width_m) > FIT_TOLERANCE_M:
			failures.append(
				"%s: width_m %.3f but the mesh is %.3f"
				% [archetype.archetype_id, definition.width_m, width]
			)
	if checked <= 0:
		failures.append("no wheel visual could be measured")
	if not failures.is_empty():
		for failure: String in failures:
			push_error("test_wheel_visual_fit: %s" % failure)
			print("WHEEL-VISUAL-FIT: FAIL %s" % failure)
		get_tree().quit(1)
		return
	print("WHEEL-VISUAL-FIT: PASS (%d wheels)" % checked)
	get_tree().quit(0)


func _wheel_archetypes() -> Array[ElementArchetype]:
	var wheels: Array[ElementArchetype] = []
	var seen: Dictionary = {}
	var candidates: Array[ElementArchetype] = []
	candidates.append_array(Slice01Archetypes.load_rover_archetypes())
	var dir := DirAccess.open("res://resources/archetypes/authored")
	if dir != null:
		var files: Array[String] = []
		for file_name: String in dir.get_files():
			if file_name.ends_with(".tres"):
				files.append(file_name)
		files.sort()
		for file_name: String in files:
			candidates.append(
				load("res://resources/archetypes/authored/%s" % file_name)
				as ElementArchetype
			)
	for archetype: ElementArchetype in candidates:
		if (
			archetype != null
			and archetype.is_wheel()
			and not seen.has(archetype.archetype_id)
		):
			seen[archetype.archetype_id] = true
			wheels.append(archetype)
	return wheels


## Шина в сборочных координатах: центр, радиус и ширина вдоль физической оси.
func _measure(archetype: ElementArchetype) -> Dictionary:
	var element := SimulationElement.frame(
		1,
		1,
		archetype,
		Vector3i.ZERO,
		archetype.default_orientation_index,
		{}
	)
	var root := _build_rig(element, archetype)
	if root == null:
		return {}
	add_child(root)
	var tire := _largest_mesh(root)
	var result: Dictionary = {}
	if tire != null:
		# Кадр сборки: риг ставится в него своим transform, физика меряет в нём же.
		var to_assembly := root.get_parent_node_3d().global_transform.affine_inverse()
		var box: AABB = (
			to_assembly * tire.global_transform
		) * tire.mesh.get_aabb()
		var axle := _physics_axle(archetype).abs()
		var centre := box.position + box.size * 0.5
		var half := box.size * 0.5
		var width := 2.0 * half.dot(axle)
		var radial := half - axle * half.dot(axle)
		var offset := (
			centre - WheelBodyProjectionUtil.axle_point_assembly_local(element)
		)
		# Осевое смещение — колесо просто стоит вбок от оси; радиальное — центр
		# шины не на оси, и тогда она обходит стойку по кругу.
		var axial := offset.dot(_physics_axle(archetype))
		result = {
			"radius_m": maxf(maxf(radial.x, radial.y), radial.z),
			"width_m": width,
			"axle_offset_m": (offset - _physics_axle(archetype) * axial).length(),
			"axial_offset_m": absf(axial),
		}
	root.queue_free()
	return result


## Тот же риг, что строит игра: авторская модель заворачивается
## ElementVisualProjection, сеточная приходит готовой сценой.
func _build_rig(
	element: SimulationElement,
	archetype: ElementArchetype
) -> Node3D:
	if not archetype.visual_scene_path.is_empty():
		if not ResourceLoader.exists(archetype.visual_scene_path):
			return null
		var packed := load(archetype.visual_scene_path) as PackedScene
		if packed == null:
			return null
		var instance := packed.instantiate() as Node3D
		if instance == null:
			return null
		var projection := ElementVisualProjection.new()
		var rig: Node3D = projection._wrap_spinning_wheel(
			instance,
			element,
			archetype
		)
		projection.free()
		return rig
	return RoverModuleVisual.instantiate_for_element(
		element.origin_cell,
		element.orientation_index,
		archetype
	)


## Ось вращения берём у самой физики, а не пересчитываем формулу в тесте:
## иначе тест зелёный ровно тогда, когда ошибается вместе с ней. Так и вышло —
## сеточные детали сходились, авторские в игре крутились вокруг вертикали.
func _physics_axle(archetype: ElementArchetype) -> Vector3:
	var frame := WheelBodyProjectionUtil.wheel_frame_assembly_local(
		SimulationElement.frame(
			1,
			1,
			archetype,
			Vector3i.ZERO,
			archetype.default_orientation_index,
			{}
		)
	)
	if frame.is_empty():
		return Vector3.RIGHT
	return Vector3(frame["axle"]).normalized()


## Шина — самый объёмный меш рига; ступицы, штыри и метки протектора мельче и
## мерить по ним размер колеса нельзя.
func _largest_mesh(root: Node) -> MeshInstance3D:
	var best: MeshInstance3D = null
	var best_volume := 0.0
	for node: Node in _walk(root):
		if not node is MeshInstance3D:
			continue
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var size := mesh_instance.mesh.get_aabb().size
		var volume := size.x * size.y * size.z
		if volume > best_volume:
			best_volume = volume
			best = mesh_instance
	return best


func _walk(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child: Node in node.get_children():
		out.append_array(_walk(child))
	return out
