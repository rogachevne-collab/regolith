@tool
class_name PartAuthoringRoot
extends Node3D

## One-node authoring for a single building part. Everything lives here: the
## model, a few plain fields, and MountPadMarker children for "attaches here".
## Bake writes a COMPLETE, valid ElementArchetype .tres — footprint, colliders,
## mass, mount pads, wheel/suspension tuning and drive axis are all derived for
## you. No separate .tres editing, no sub-resources, no orientation math.

enum PartKind {
	PLAIN,        ## a structural block / frame; bolts on its faces
	WHEEL,        ## a driven wheel (one attach point = the hub)
	SUSPENSION,   ## a wheel mount (bolts to frame + one wheel socket)
	BATTERY,      ## stores power; needs at least one electric marker
	POWER_SOURCE, ## generates power; needs at least one electric marker
}

enum MountGeneration {
	FULL_SURFACE,  ## no markers at all — the whole outer surface bolts on
	PER_SIDE,      ## one marker per side of the bounding box (6)
	PER_CELL,      ## one marker per external cell face (a lot on big parts)
}

const _ALL_FACES: Array[OrientationUtil.Face] = [
	OrientationUtil.Face.POS_X,
	OrientationUtil.Face.NEG_X,
	OrientationUtil.Face.POS_Y,
	OrientationUtil.Face.NEG_Y,
	OrientationUtil.Face.POS_Z,
	OrientationUtil.Face.NEG_Z,
]

## Насколько игрок может ужать ход в пульте относительно авторской палки.
## Больше палки — нельзя (стойки такой длины нет), меньше половины — уже не
## подвеска, а распорка.
const TRAVEL_TUNE_FLOOR_FRACTION := 0.5

const FOOTPRINT_PREVIEW_NAME := "_EditorFootprintPreview"
const VISUAL_PREVIEW_NAME := "_EditorVisualPreview"
const AUTHORED_DIR := "res://resources/archetypes/authored/"

@export var part_id: String = "":
	set(value):
		part_id = value.strip_edges()
@export var display_name: String = ""
@export var part_kind: PartKind = PartKind.PLAIN:
	set(value):
		part_kind = value
		# Wheels/suspensions need tagged points, so "whole surface" makes no
		# sense for them — move to per-side unless the author picked otherwise.
		# Batteries/sources bolt on like a plain block (only their electric
		# markers are special), so FULL_SURFACE stays valid for them.
		if (
			(part_kind == PartKind.WHEEL or part_kind == PartKind.SUSPENSION)
			and mount_generation == MountGeneration.FULL_SURFACE
		):
			mount_generation = MountGeneration.PER_SIDE
		notify_property_list_changed()
		_queue_preview_update()

## The part's mesh/scene, shown so markers land on real geometry.
## Assigning it auto-fits size_cells — no toggle dance needed.
@export var visual_scene: PackedScene:
	set(value):
		var changed := visual_scene != value
		visual_scene = value
		_queue_preview_update()
		if changed and value != null and Engine.is_editor_hint() and is_inside_tree():
			call_deferred("fit_size_to_model")

## Footprint is a simple box this many cells on each side (1 cell = 0.5 m).
@export var size_cells: Vector3i = Vector3i.ONE:
	set(value):
		size_cells = Vector3i(maxi(value.x, 1), maxi(value.y, 1), maxi(value.z, 1))
		_queue_preview_update()

## 0 = auto (from footprint size).
@export var mass_kg: float = 0.0

# --- Wheel fields (shown only when part_kind == WHEEL) ---
@export var wheel_radius_m: float = 0.4
@export var wheel_drive_torque_n_m: float = 65.0
@export var wheel_steerable: bool = false
## Макс. угол руля (рад). 0.4887 ≈ 28°. Потолок для уставки в пульте.
@export var wheel_max_steering_angle_rad: float = 0.4887
## Скорость доворота к цели руля (рад/с на единицу команды).
@export var wheel_steering_response: float = 2.5
## Сцепление: предел силы = прижимающая сила × коэффициент. Вдоль — тяга и
## тормоз, поперёк — сопротивление сносу. Оба делят один запас (эллипс трения),
## поэтому газ в повороте съедает боковое держание.
@export var wheel_grip_longitudinal: float = 1.2
@export var wheel_grip_lateral: float = 0.9
## Как круто нарастает сила от проскальзывания (Н на м/с), пока не упрётся в
## предел выше. Меньше — резина мягче и «расползается» плавнее.
@export var wheel_slip_stiffness: float = 800.0
@export var wheel_lateral_stiffness: float = 1000.0

# --- Suspension fields (shown only when part_kind == SUSPENSION) ---
@export var suspension_travel_m: float = 0.6
## Жёсткость — сила от того, НАСКОЛЬКО сжата подвеска. Держит вес.
@export var suspension_stiffness_n_per_m: float = 1600.0
## Демпфирование — сила от того, КАК БЫСТРО она сжимается. Гасит раскачку,
## веса не держит. Критическое ≈ 2·√(жёсткость · масса на колесо).
@export var suspension_damping_n_s_per_m: float = 400.0

# --- Battery fields (shown only when part_kind == BATTERY) ---
@export var battery_capacity_kwh: float = 10.0
@export var battery_charge_w: float = 500.0
@export var battery_discharge_w: float = 500.0

# --- Power source fields (shown only when part_kind == POWER_SOURCE) ---
@export var source_output_w: float = 2000.0

## Стоимость постройки. Пусто = авто по типу детали (блок — plate_metal,
## колесо/подвеска — mechanism, количество от размера).
@export var build_requirements: Array[BuildRequirement] = []

# Everything below is written by the wizard / fit; hand-editing is a
# fallback for working without the Part Wizard dock.
@export_group("Сервис — визард делает это сам", "")

## Set by fit_size_to_model: shifts the visual so the model's minimum corner
## lands on the origin no matter where its pivot is (hub-tip pivots are fine —
## no re-export or manual nudging needed).
@export var model_offset: Vector3 = Vector3.ZERO

## How "Generate mounts" lays attach points out. FULL_SURFACE needs no markers.
@export var mount_generation: MountGeneration = MountGeneration.FULL_SURFACE

## The ghost orientation the player starts with when selecting this part.
## Set from the wizard's "player view" step; 0 = as authored in the scene.
@export_range(0, 23) var default_orientation_index: int = 0

## Toggle: read the model's bounds and set size_cells to match.
## (Happens automatically when visual_scene is assigned.)
@export var fit_size_to_model_now: bool = false:
	set(value):
		fit_size_to_model_now = false
		if value and Engine.is_editor_hint():
			fit_size_to_model()

## Toggle: (re)generate MountPadMarker children per mount_generation.
## Generated markers are real, selectable, deletable nodes.
@export var generate_mounts_now: bool = false:
	set(value):
		generate_mounts_now = false
		if value and Engine.is_editor_hint():
			generate_mounts()

@export var bake_now: bool = false:
	set(value):
		bake_now = value
		if value and Engine.is_editor_hint():
			_perform_bake()
			bake_now = false

@export var last_bake_diagnostics: PackedStringArray = PackedStringArray()

## Where the previous bake landed. Lets the wizard notice a part_id rename
## and offer to delete the orphaned old .tres instead of leaving it around.
@export var last_baked_path: String = ""

@export_group("")

## Where baked .tres land. Authored parts go to the shared dir by default;
## tests point this at user:// so they never touch the project tree.
var save_dir: String = AUTHORED_DIR


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_preview()
	else:
		_remove_preview()


## Hide the fields that don't apply to the chosen part kind.
func _validate_property(property: Dictionary) -> void:
	var prop_name := str(property.name)
	var is_wheel := prop_name.begins_with("wheel_")
	var is_susp := prop_name.begins_with("suspension_")
	var is_battery := prop_name.begins_with("battery_")
	var is_source := prop_name.begins_with("source_")
	if is_wheel and part_kind != PartKind.WHEEL:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if is_susp and part_kind != PartKind.SUSPENSION:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if is_battery and part_kind != PartKind.BATTERY:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if is_source and part_kind != PartKind.POWER_SOURCE:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Footprint cells (a box from size_cells), in part-local grid space.
##
## A WHEEL is the exception: it occupies only the cell its axle sits in. The
## tyre hangs outside the grid the way the stock 1.5 m wheel does — otherwise
## a wheel would claim a wall of cells and block every neighbour.
func footprint_cells() -> Array[Vector3i]:
	if part_kind == PartKind.WHEEL:
		return [GridMetric.meters_to_cell_floor(_hub_point_local())]
	var cells: Array[Vector3i] = []
	for x: int in range(size_cells.x):
		for y: int in range(size_cells.y):
			for z: int in range(size_cells.z):
				cells.append(Vector3i(x, y, z))
	return cells


func collect_pad_markers() -> Array[MountPadMarker]:
	var markers: Array[MountPadMarker] = []
	for child: Node in get_children():
		var marker := child as MountPadMarker
		if marker != null:
			markers.append(marker)
	return markers


## Structural mount markers only — electric ports are collected separately
## (see collect_electric_markers) since they bake into archetype.ports, not
## structural_mount_pads.
func collect_structural_markers() -> Array[MountPadMarker]:
	var markers: Array[MountPadMarker] = []
	for marker: MountPadMarker in collect_pad_markers():
		if not marker.is_electric():
			markers.append(marker)
	return markers


## Нижняя граница ползунка «ход» в пульте для стойки с таким ходом.
static func travel_tune_floor(travel_m: float) -> float:
	return clampf(travel_m * TRAVEL_TUNE_FLOOR_FRACTION, 0.05, travel_m)


## Палка хода подвески, если автор её поставил. Она задаёт и точку гнезда
## колеса (низ), и suspension_travel_m (длина вдоль оси хода).
func travel_marker() -> SuspensionTravelMarker:
	for child: Node in get_children():
		var marker := child as SuspensionTravelMarker
		if marker != null:
			return marker
	return null


## Цилиндр шины: центр вращения + радиус/ширина. Точка wheel_plug — стык.
func tire_marker() -> WheelTireMarker:
	for child: Node in get_children():
		var marker := child as WheelTireMarker
		if marker != null:
			return marker
	return null


## Optional electrical connection points — most parts have none.
func collect_electric_markers() -> Array[MountPadMarker]:
	var markers: Array[MountPadMarker] = []
	for marker: MountPadMarker in collect_pad_markers():
		if marker.is_electric():
			markers.append(marker)
	return markers


## Measure the model and set size_cells to the matching cell box.
func fit_size_to_model() -> Dictionary:
	last_bake_diagnostics = PackedStringArray()
	if visual_scene == null:
		last_bake_diagnostics.append("нет модели (visual_scene) — нечего мерить")
		return {"ok": false}
	var instance := visual_scene.instantiate()
	var state: Dictionary = {}
	_collect_aabb(instance, Transform3D.IDENTITY, state)
	instance.free()
	if not state.has("aabb"):
		last_bake_diagnostics.append("в модели нет видимой геометрии")
		return {"ok": false}
	var bounds: AABB = state["aabb"]
	if bounds.size.length() <= 0.0001:
		last_bake_diagnostics.append("модель нулевого размера")
		return {"ok": false}
	# Export/scale noise routinely makes a 2-cell model 1.001 m; without a
	# tolerance a single "pixel" of overshoot buys a whole extra cell row.
	const FIT_TOLERANCE_M := 0.02
	size_cells = Vector3i(
		maxi(ceili((bounds.size.x - FIT_TOLERANCE_M) / GridMetric.CELL_SIZE_M), 1),
		maxi(ceili((bounds.size.y - FIT_TOLERANCE_M) / GridMetric.CELL_SIZE_M), 1),
		maxi(ceili((bounds.size.z - FIT_TOLERANCE_M) / GridMetric.CELL_SIZE_M), 1)
	)
	last_bake_diagnostics.append(
		"модель %.2f×%.2f×%.2f м → %d×%d×%d клеток"
		% [
			bounds.size.x, bounds.size.y, bounds.size.z,
			size_cells.x, size_cells.y, size_cells.z,
		]
	)
	# Convention: cell (0,0,0) is the cube [0..0.5]³, so the model's minimum
	# corner belongs at the origin. Whatever the pivot is (hub tip, centre),
	# compensate automatically instead of making the author re-export.
	model_offset = -bounds.position
	if bounds.position.length() > 0.01:
		last_bake_diagnostics.append(
			"пивот модели смещён на (%.2f, %.2f, %.2f) — скомпенсировал сам"
			% [bounds.position.x, bounds.position.y, bounds.position.z]
		)
	_queue_preview_update()
	return {"ok": true, "size_cells": size_cells, "bounds": bounds}


## (Re)create marker nodes on the candidate faces. Markers made by a previous
## generate are replaced; ones you added by hand are left alone.
func generate_mounts() -> int:
	last_bake_diagnostics = PackedStringArray()
	for marker: MountPadMarker in collect_pad_markers():
		if bool(marker.get_meta("auto_generated", false)):
			remove_child(marker)
			marker.queue_free()
	if mount_generation == MountGeneration.FULL_SURFACE:
		last_bake_diagnostics.append(
			"режим «вся поверхность» — маркеры не нужны, сразу Bake"
		)
		return 0
	var created := 0
	for face_data: Dictionary in _candidate_faces():
		var cell: Vector3i = face_data["cell"]
		var face: OrientationUtil.Face = face_data["face"]
		var marker := MountPadMarker.new()
		marker.socket_kind = _guess_socket_kind(face)
		marker.name = "Mount_%s_%d_%d_%d" % [
			_face_suffix(face), cell.x, cell.y, cell.z
		]
		add_child(marker)
		marker.owner = _scene_owner()
		marker.position = _face_center_local(cell, face)
		marker.set_meta("auto_generated", true)
		created += 1
	last_bake_diagnostics.append(
		"создано %d маркер(ов) — лишние удали, нужные подвинь" % created
	)
	return created


func _candidate_faces() -> Array[Dictionary]:
	var faces: Array[Dictionary] = []
	var cells := footprint_cells()
	if cells.is_empty():
		return faces
	if mount_generation == MountGeneration.PER_CELL:
		var occupied: Dictionary = {}
		for cell: Vector3i in cells:
			occupied[cell] = true
		for cell: Vector3i in cells:
			for face: OrientationUtil.Face in _ALL_FACES:
				if occupied.has(cell + OrientationUtil.face_to_vector(face)):
					continue
				faces.append({"cell": cell, "face": face})
		return faces
	# PER_SIDE — one marker at the middle of each bounding-box side.
	var last := size_cells - Vector3i.ONE
	var mid := Vector3i(int(last.x / 2), int(last.y / 2), int(last.z / 2))
	faces.append({"cell": Vector3i(last.x, mid.y, mid.z), "face": OrientationUtil.Face.POS_X})
	faces.append({"cell": Vector3i(0, mid.y, mid.z), "face": OrientationUtil.Face.NEG_X})
	faces.append({"cell": Vector3i(mid.x, last.y, mid.z), "face": OrientationUtil.Face.POS_Y})
	faces.append({"cell": Vector3i(mid.x, 0, mid.z), "face": OrientationUtil.Face.NEG_Y})
	faces.append({"cell": Vector3i(mid.x, mid.y, last.z), "face": OrientationUtil.Face.POS_Z})
	faces.append({"cell": Vector3i(mid.x, mid.y, 0), "face": OrientationUtil.Face.NEG_Z})
	return faces


## Best guess at what each generated face is for — you can retag any of them.
func _guess_socket_kind(face: OrientationUtil.Face) -> MountPadMarker.SocketKind:
	match part_kind:
		PartKind.WHEEL:
			if face == OrientationUtil.Face.POS_Y:
				return MountPadMarker.SocketKind.WHEEL_PLUG
		PartKind.SUSPENSION:
			# С палкой хода гнездо уже задано её низом — не плодим маркер,
			# который потом придётся удалять.
			if face == OrientationUtil.Face.NEG_Y and travel_marker() == null:
				return MountPadMarker.SocketKind.WHEEL_SOCKET
		PartKind.PLAIN:
			pass
	return MountPadMarker.SocketKind.STRUCTURAL


func _face_center_local(cell: Vector3i, face: OrientationUtil.Face) -> Vector3:
	return (
		GridMetric.cell_center_meters(cell)
		+ Vector3(OrientationUtil.face_to_vector(face)) * GridMetric.HALF_CELL_SIZE_M
	)


func _face_suffix(face: OrientationUtil.Face) -> String:
	match face:
		OrientationUtil.Face.POS_X:
			return "px"
		OrientationUtil.Face.NEG_X:
			return "nx"
		OrientationUtil.Face.POS_Y:
			return "py"
		OrientationUtil.Face.NEG_Y:
			return "ny"
		OrientationUtil.Face.POS_Z:
			return "pz"
		_:
			return "nz"


func _scene_owner() -> Node:
	var tree := get_tree()
	if tree != null and tree.edited_scene_root != null:
		return tree.edited_scene_root
	return self


func _collect_aabb(node: Node, xform: Transform3D, state: Dictionary) -> void:
	var current := xform
	var spatial := node as Node3D
	if spatial != null:
		current = xform * spatial.transform
	var visual := node as VisualInstance3D
	if visual != null:
		var box := current * visual.get_aabb()
		if state.has("aabb"):
			state["aabb"] = (state["aabb"] as AABB).merge(box)
		else:
			state["aabb"] = box
	for child: Node in node.get_children():
		_collect_aabb(child, current, state)


## Build a full archetype from the current node, validate it, and save it.
## Returns { ok, errors, archetype, path }.
func bake() -> Dictionary:
	last_bake_diagnostics = PackedStringArray()
	var errors: Array[String] = []

	if part_id.is_empty():
		errors.append("part_id is empty (give the part a name)")
	if part_id.contains("/") or part_id.contains("\\") or part_id.contains(" "):
		errors.append("part_id must be a bare id (no spaces or slashes)")

	var archetype := _build_archetype(errors)
	for error: String in errors:
		last_bake_diagnostics.append(error)
	if archetype == null:
		return {"ok": false, "errors": errors}

	var validation := BlueprintValidator.validate_archetype(archetype)
	for error: String in validation.errors:
		errors.append(error)
		last_bake_diagnostics.append(error)
	# validate_archetype doesn't run wheel/suspension rules — do it here so the
	# "exactly one wheel_plug" / "forward ⟂ plug" checks reach the author.
	if archetype.wheel_definition != null:
		for message: String in archetype.wheel_definition.validate(archetype):
			errors.append("колесо: %s" % message)
			last_bake_diagnostics.append(errors[-1])
	if archetype.suspension_definition != null:
		for message: String in archetype.suspension_definition.validate(archetype):
			errors.append("подвеска: %s" % message)
			last_bake_diagnostics.append(errors[-1])
	if archetype.battery_definition != null:
		for message: String in archetype.battery_definition.validate(archetype):
			errors.append("батарея: %s" % message)
			last_bake_diagnostics.append(errors[-1])
	if archetype.power_source_definition != null:
		for message: String in archetype.power_source_definition.validate(archetype):
			errors.append("источник энергии: %s" % message)
			last_bake_diagnostics.append(errors[-1])

	if not part_id.is_empty():
		var path := "%s%s.tres" % [save_dir, part_id]
		_ensure_dir(save_dir)
		var save_error := ResourceSaver.save(archetype, path)
		if save_error != OK:
			errors.append("ResourceSaver failed with code %d" % save_error)
			last_bake_diagnostics.append(errors[-1])
			return {"ok": false, "errors": errors, "archetype": archetype}
		last_bake_diagnostics.append(
			"baked '%s' -> %s%s" % [part_id, "OK " if errors.is_empty() else "with issues ", path]
		)
		var stale_path := ""
		if (
			not last_baked_path.is_empty()
			and last_baked_path != path
			and ResourceLoader.exists(last_baked_path)
		):
			stale_path = last_baked_path
			last_bake_diagnostics.append(
				"part_id сменился: старый файл остался — %s" % stale_path
			)
		last_baked_path = path
		return {
			"ok": errors.is_empty(),
			"errors": errors,
			"archetype": archetype,
			"path": path,
			"stale_path": stale_path,
		}
	return {"ok": false, "errors": errors, "archetype": archetype}


func _build_archetype(errors: Array[String]) -> ElementArchetype:
	var cells := footprint_cells()
	if cells.is_empty():
		errors.append("footprint is empty")
		return null

	var archetype := ElementArchetype.new()
	archetype.archetype_id = part_id
	archetype.display_name = display_name if not display_name.is_empty() else part_id
	archetype.footprint_cells = cells
	archetype.max_integrity = 100.0
	archetype.mass_kg = mass_kg if mass_kg > 0.0 else maxf(float(cells.size()) * 8.0, 1.0)
	archetype.colliders = _auto_colliders(cells)
	archetype.roles = _roles_for_kind()
	# A part without a build cost is UNPLACEABLE: the command validator
	# rejects it as invalid_target before matching even runs.
	archetype.build_requirements = (
		build_requirements
		if not build_requirements.is_empty()
		else _default_build_requirements(cells.size())
	)
	archetype.default_orientation_index = clampi(
		default_orientation_index,
		0,
		OrientationUtil.ORIENTATION_COUNT - 1
	)
	if visual_scene != null and not visual_scene.resource_path.is_empty():
		archetype.visual_scene_path = visual_scene.resource_path
		archetype.visual_offset = model_offset

	var socket_face_holder: Array = [OrientationUtil.Face.NEG_Y]
	var pads := _build_pads(errors, socket_face_holder)
	var ports := _build_ports(errors)
	if not ports.is_empty():
		archetype.ports = ports

	var whole_surface := (
		(
			part_kind == PartKind.PLAIN
			or part_kind == PartKind.BATTERY
			or part_kind == PartKind.POWER_SOURCE
		)
		and (
			mount_generation == MountGeneration.FULL_SURFACE
			or pads.is_empty()
		)
	)
	if whole_surface:
		# A plain block bolting on every side — no markers needed at all.
		archetype.structural_surface_policy = (
			ElementArchetype.StructuralSurfacePolicy.FULL_SURFACE
		)
	else:
		archetype.structural_surface_policy = (
			ElementArchetype.StructuralSurfacePolicy.MOUNT_PADS
		)
		archetype.structural_mount_pads = pads

	match part_kind:
		PartKind.WHEEL:
			archetype.wheel_definition = _build_wheel_definition(pads)
		PartKind.SUSPENSION:
			archetype.suspension_definition = _build_suspension_definition(
				socket_face_holder[0]
			)
		PartKind.BATTERY:
			archetype.battery_definition = _build_battery_definition()
		PartKind.POWER_SOURCE:
			archetype.power_source_definition = _build_power_source_definition()
		PartKind.PLAIN:
			pass
	return archetype


## Turn the markers into pads, applying roles by part kind. socket_face_holder[0]
## receives the wheel_socket face for suspension tuning.
func _build_pads(
	errors: Array[String],
	socket_face_holder: Array
) -> Array[StructuralMountPad]:
	var markers := collect_structural_markers()
	var by_key: Dictionary = {}
	var pads: Array[StructuralMountPad] = []

	match part_kind:
		PartKind.WHEEL:
			if markers.size() != 1:
				errors.append(
					"Колесо: поставь ровно один маркер крепления (сейчас %d)"
					% markers.size()
				)
			for marker: MountPadMarker in markers:
				var pad := marker.to_pad()
				if pad == null:
					continue
				pad.socket_tag = "wheel_plug"
				_insert_pad(pad, by_key, pads)
				break
		PartKind.SUSPENSION:
			var sockets := 0
			var structurals := 0
			# Палка идёт ПЕРВОЙ: её низ — это гнездо, и если на ту же грань
			# автор посадил ещё и обычное крепление, побеждать должно гнездо.
			var travel := travel_marker()
			if travel != null:
				var travel_pad := travel.to_socket_pad()
				if travel_pad == null:
					errors.append(
						"Подвеска: низ палки хода не привязался к детали —"
						+ " придвинь его к модели"
					)
				else:
					socket_face_holder[0] = travel_pad.local_face
					_insert_pad(travel_pad, by_key, pads)
					sockets += 1
			for marker: MountPadMarker in markers:
				var pad := marker.to_pad()
				if pad == null:
					continue
				if marker.socket_kind == MountPadMarker.SocketKind.WHEEL_SOCKET:
					if travel != null:
						last_bake_diagnostics.append(
							"маркер «гнездо колеса» (%s) не нужен: точку берём"
							% marker.name
							+ " с низа палки хода — удали маркер"
						)
						continue
					pad.socket_tag = "wheel_socket"
				else:
					pad.socket_tag = ""
				if not _insert_pad(pad, by_key, pads):
					last_bake_diagnostics.append(
						"маркер «%s» встал на уже занятую грань — пропущен"
						% marker.name
					)
					continue
				if marker.socket_kind == MountPadMarker.SocketKind.WHEEL_SOCKET:
					socket_face_holder[0] = pad.local_face
					sockets += 1
				else:
					structurals += 1
			if sockets != 1:
				errors.append(
					"Подвеска: нужен ровно один маркер «сюда встаёт колесо» (%d)"
					% sockets
				)
			if structurals < 1:
				errors.append(
					"Подвеска: нужен хотя бы один маркер «крепится к раме»"
				)
		PartKind.PLAIN:
			for marker: MountPadMarker in markers:
				var pad := marker.to_pad()
				if pad == null:
					continue
				pad.socket_tag = ""
				_insert_pad(pad, by_key, pads)
	return pads


## Optional electrical ports — most parts have none. Each marker's port_role
## picks the "_in"/"_out"/"_io" suffix IndustryElectricPortUtil reads the
## direction from; a second marker of the same role gets a numbered id
## (power2_in) so the suffix — and therefore the direction — stays intact.
func _build_ports(errors: Array[String]) -> Array[PortDefinition]:
	var ports: Array[PortDefinition] = []
	var role_counts: Dictionary = {}
	for marker: MountPadMarker in collect_electric_markers():
		var suffix := marker.port_role_suffix()
		var count: int = role_counts.get(suffix, 0) + 1
		role_counts[suffix] = count
		var port_id := "power_%s" % suffix if count == 1 else "power%d_%s" % [count, suffix]
		var port := marker.to_port(port_id)
		if port == null:
			errors.append(
				"электроточка «%s» не удалось привязать к грани — придвинь к модели"
				% marker.name
			)
			continue
		ports.append(port)
	return ports


func _build_wheel_definition(
	pads: Array[StructuralMountPad]
) -> WheelDefinition:
	var definition := WheelDefinition.new()
	definition.radius_m = wheel_radius_m
	definition.width_m = maxf(wheel_radius_m * 0.75, 0.05)
	definition.drive_torque_n_m = wheel_drive_torque_n_m
	definition.steerable_default = wheel_steerable
	definition.max_steering_angle_rad = wheel_max_steering_angle_rad
	definition.steering_response = wheel_steering_response
	definition.longitudinal_grip = wheel_grip_longitudinal
	definition.lateral_grip = wheel_grip_lateral
	definition.slip_stiffness = wheel_slip_stiffness
	definition.lateral_stiffness = wheel_lateral_stiffness
	var plug_face := OrientationUtil.Face.POS_Y
	for pad: StructuralMountPad in pads:
		if pad.socket_tag == "wheel_plug":
			plug_face = pad.local_face
			break
	# Стабильный forward при перепеке: если прошлый выбор всё ещё ⊥ plug —
	# оставляем. Иначе лотерея _perpendicular_face даёт флип по оси ступицы.
	definition.forward_axis_face = _stable_forward_axis_face(plug_face)
	var tire := tire_marker()
	if tire != null:
		definition.radius_m = tire.radius_m
		definition.width_m = tire.width_m
		definition.hub_local_authored = true
		definition.hub_local = tire.hub_point_local()
		wheel_radius_m = tire.radius_m
		last_bake_diagnostics.append(
			"шина: Ø %.2f м, ширина %.2f м, хаб %s (цилиндр); стык — точка plug"
			% [tire.radius_m * 2.0, tire.width_m, tire.hub_point_local()]
		)
	else:
		last_bake_diagnostics.append(
			"цилиндр шины не поставлен — радиус из инспектора, хаб = точка plug"
		)
	return definition


func _stable_forward_axis_face(
	plug_face: OrientationUtil.Face
) -> OrientationUtil.Face:
	var fallback := _perpendicular_face(plug_face)
	if last_baked_path.is_empty() or not ResourceLoader.exists(last_baked_path):
		return fallback
	var baked := load(last_baked_path) as ElementArchetype
	if baked == null or baked.wheel_definition == null:
		return fallback
	var previous := baked.wheel_definition.forward_axis_face
	var plug_axis := OrientationUtil.face_to_vector(plug_face)
	var forward_axis := OrientationUtil.face_to_vector(previous)
	if (
		forward_axis.x * plug_axis.x
		+ forward_axis.y * plug_axis.y
		+ forward_axis.z * plug_axis.z
		!= 0
	):
		return fallback
	return previous


func _build_suspension_definition(
	socket_face: OrientationUtil.Face
) -> SuspensionDefinition:
	var definition := SuspensionDefinition.new()
	definition.wheel_socket_face = socket_face
	var travel := travel_marker()
	var travel_m := suspension_travel_m
	if travel != null:
		travel_m = travel.travel_m()
		# Палка — ФИЗИЧЕСКИЙ предел стойки, а не «примерно столько». Игроку в
		# пульте остаётся ужимать ход, но не выдумывать сантиметры, которых у
		# детали нет: иначе колесо уезжает ниже собственной модели.
		definition.max_travel_m = travel_m
		definition.min_travel_m = travel_tune_floor(travel_m)
		definition.suspension_travel_m = travel_m
		definition.spring_stiffness_n_per_m = suspension_stiffness_n_per_m
		definition.spring_damping_n_s_per_m = suspension_damping_n_s_per_m
		last_bake_diagnostics.append(
			"ход подвески: %.2f м (палка %.2f м, отклонение %.0f°);"
			% [travel_m, travel.stick_length_m(), travel.off_axis_deg()]
			+ " регулировка в игре %.2f…%.2f м"
			% [definition.min_travel_m, definition.max_travel_m]
		)
		return definition
	last_bake_diagnostics.append(
		"ход подвески не отмечен палкой — беру %.2f м из инспектора" % travel_m
	)
	# Раздвигаем пределы под авторский ход вместо молчаливой обрезки: короткая
	# стойка на 0.15 м — это выбор автора, а не ошибка. Пределы заодно задают
	# диапазон ползунка настройки в игре.
	if travel_m < definition.min_travel_m or travel_m > definition.max_travel_m:
		definition.min_travel_m = minf(definition.min_travel_m, travel_m)
		definition.max_travel_m = maxf(definition.max_travel_m, travel_m)
		last_bake_diagnostics.append(
			"пределы настройки хода раздвинуты под деталь: %.2f…%.2f м"
			% [definition.min_travel_m, definition.max_travel_m]
		)
	definition.suspension_travel_m = travel_m
	definition.spring_stiffness_n_per_m = suspension_stiffness_n_per_m
	definition.spring_damping_n_s_per_m = suspension_damping_n_s_per_m
	return definition


func _build_battery_definition() -> BatteryDefinition:
	var definition := BatteryDefinition.new()
	definition.capacity_kwh = battery_capacity_kwh
	definition.charge_w = battery_charge_w
	definition.discharge_w = battery_discharge_w
	return definition


func _build_power_source_definition() -> PowerSourceDefinition:
	var definition := PowerSourceDefinition.new()
	definition.output_w = source_output_w
	return definition


## Any axis face perpendicular to `plug_face` — this is the drive/forward axis.
## Guarantees the "forward must be perpendicular to plug" rule automatically.
func _perpendicular_face(plug_face: OrientationUtil.Face) -> OrientationUtil.Face:
	var plug := OrientationUtil.face_to_vector(plug_face)
	for face: OrientationUtil.Face in [
		OrientationUtil.Face.NEG_Z,
		OrientationUtil.Face.POS_Z,
		OrientationUtil.Face.NEG_X,
		OrientationUtil.Face.POS_X,
		OrientationUtil.Face.NEG_Y,
		OrientationUtil.Face.POS_Y,
	]:
		var candidate := OrientationUtil.face_to_vector(face)
		var dot := candidate.x * plug.x + candidate.y * plug.y + candidate.z * plug.z
		if dot == 0:
			return face
	return OrientationUtil.Face.NEG_Z


func _default_build_requirements(cell_count: int) -> Array[BuildRequirement]:
	var requirement := BuildRequirement.new()
	match part_kind:
		PartKind.WHEEL, PartKind.SUSPENSION:
			requirement.resource_id = "mechanism"
			requirement.amount = maxf(2.0, roundf(float(cell_count) * 0.25))
		PartKind.BATTERY:
			requirement.resource_id = "conduit"
			requirement.amount = maxf(4.0, roundf(float(cell_count) * 0.5))
		PartKind.POWER_SOURCE:
			requirement.resource_id = "plate_metal"
			requirement.amount = maxf(8.0, roundf(float(cell_count) * 0.3))
		_:
			requirement.resource_id = "plate_metal"
			requirement.amount = maxf(1.0, roundf(float(cell_count) * 0.5))
	return [requirement] as Array[BuildRequirement]


func _roles_for_kind() -> PackedStringArray:
	match part_kind:
		PartKind.WHEEL:
			return PackedStringArray(["Support", "Actuator"])
		PartKind.SUSPENSION:
			return PackedStringArray(["Support"])
		PartKind.BATTERY:
			return PackedStringArray(["Tank"])
		PartKind.POWER_SOURCE:
			return PackedStringArray(["Source"])
		_:
			return PackedStringArray(["Frame"])


## The footprint is always a solid box, so one box collider covers it. Emitting
## one per cell would give a 2.5 m cube 125 shapes for no benefit.
##
## A WHEEL is the exception: it is simulated as a suspension raycast, not as a
## solid tyre, and its visual rides up and down with the spring. A collider the
## size of the tyre would sit rigidly in the element's cells, plough into the
## ground and leave the wheel looking sunk. Stock wheels carry a small stub at
## the hub for mass and picking; do the same.
func _auto_colliders(_cells: Array[Vector3i]) -> Array[ColliderDefinition]:
	var collider := ColliderDefinition.new()
	if part_kind == PartKind.WHEEL:
		collider.local_cell = GridMetric.meters_to_cell_floor(_hub_point_local())
		var stub := clampf(wheel_radius_m * 0.5, 0.1, GridMetric.CELL_SIZE_M)
		collider.size = Vector3.ONE * stub
		collider.offset_in_cell = Vector3.ONE * GridMetric.HALF_CELL_SIZE_M
		return [collider] as Array[ColliderDefinition]
	collider.local_cell = Vector3i.ZERO
	collider.size = Vector3(size_cells) * GridMetric.CELL_SIZE_M
	collider.offset_in_cell = collider.size * 0.5
	return [collider] as Array[ColliderDefinition]


## Where the wheel sits on its axle — the marked plug point, or the centre of
## the footprint when nothing is marked yet.
func _hub_point_local() -> Vector3:
	for marker: MountPadMarker in collect_pad_markers():
		if marker.socket_kind == MountPadMarker.SocketKind.WHEEL_PLUG:
			return marker.position
	return Vector3(size_cells) * GridMetric.CELL_SIZE_M * 0.5


## false when another pad already owns this (cell, face) — the caller decides
## whether a dropped pad is worth telling the author about.
func _insert_pad(
	pad: StructuralMountPad,
	by_key: Dictionary,
	ordered: Array[StructuralMountPad]
) -> bool:
	var key := "%d,%d,%d,%d" % [
		pad.local_cell.x,
		pad.local_cell.y,
		pad.local_cell.z,
		int(pad.local_face),
	]
	if by_key.has(key):
		return false
	by_key[key] = true
	ordered.append(pad)
	return true


func _ensure_dir(dir: String) -> void:
	var absolute := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(absolute):
		DirAccess.make_dir_recursive_absolute(absolute)


func _perform_bake() -> void:
	var result := bake()
	if not bool(result.get("ok", false)):
		push_warning(
			"Part bake incomplete: %s" % ", ".join(last_bake_diagnostics)
		)


func _queue_preview_update() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	call_deferred("_update_preview")


func _update_preview() -> void:
	_remove_preview()
	if not Engine.is_editor_hint():
		return

	var footprint_root := Node3D.new()
	footprint_root.name = FOOTPRINT_PREVIEW_NAME
	footprint_root.set_meta("_edit_lock_", true)
	add_child(footprint_root, false, Node.INTERNAL_MODE_BACK)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.7, 0.75, 0.12)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for cell: Vector3i in footprint_cells():
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE * GridMetric.CELL_SIZE_M
		box.mesh = mesh
		box.position = GridMetric.cell_center_meters(cell)
		box.material_override = mat
		footprint_root.add_child(box, false, Node.INTERNAL_MODE_BACK)

	if visual_scene != null:
		var instance := visual_scene.instantiate()
		var node3d := instance as Node3D
		if node3d != null:
			node3d.name = VISUAL_PREVIEW_NAME
			node3d.set_meta("_edit_lock_", true)
			add_child(node3d, false, Node.INTERNAL_MODE_BACK)
			node3d.position = model_offset
		else:
			instance.free()


func _remove_preview() -> void:
	for preview_name: String in [FOOTPRINT_PREVIEW_NAME, VISUAL_PREVIEW_NAME]:
		var preview := get_node_or_null(preview_name)
		if preview != null:
			remove_child(preview)
			preview.free()
