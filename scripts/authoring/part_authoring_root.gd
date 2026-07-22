@tool
class_name PartAuthoringRoot
extends Node3D

## One-node authoring for a single building part. Everything lives here: the
## model, a few plain fields, and MountPadMarker children for "attaches here".
## Bake writes a COMPLETE, valid ElementArchetype .tres — footprint, colliders,
## mass, mount pads, wheel/suspension tuning and drive axis are all derived for
## you. No separate .tres editing, no sub-resources, no orientation math.

enum PartKind {
	PLAIN,       ## a structural block / frame; bolts on its faces
	WHEEL,       ## a driven wheel (one attach point = the hub)
	SUSPENSION,  ## a wheel mount (bolts to frame + one wheel socket)
}

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
		notify_property_list_changed()
		_queue_preview_update()

## The part's mesh/scene, shown so markers land on real geometry.
@export var visual_scene: PackedScene:
	set(value):
		visual_scene = value
		_queue_preview_update()

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

# --- Suspension fields (shown only when part_kind == SUSPENSION) ---
@export var suspension_travel_m: float = 0.6
@export var suspension_stiffness_n_per_m: float = 1600.0

@export var bake_now: bool = false:
	set(value):
		bake_now = value
		if value and Engine.is_editor_hint():
			_perform_bake()
			bake_now = false

@export var last_bake_diagnostics: PackedStringArray = PackedStringArray()

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
	if is_wheel and part_kind != PartKind.WHEEL:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if is_susp and part_kind != PartKind.SUSPENSION:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Footprint cells (a box from size_cells), in part-local grid space.
func footprint_cells() -> Array[Vector3i]:
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
		return {
			"ok": errors.is_empty(),
			"errors": errors,
			"archetype": archetype,
			"path": path,
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

	var socket_face_holder: Array = [OrientationUtil.Face.NEG_Y]
	var pads := _build_pads(errors, socket_face_holder)

	if part_kind == PartKind.PLAIN and pads.is_empty():
		# A plain block with no markers = a frame: whole surface bolts on.
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
		PartKind.PLAIN:
			pass
	return archetype


## Turn the markers into pads, applying roles by part kind. socket_face_holder[0]
## receives the wheel_socket face for suspension tuning.
func _build_pads(
	errors: Array[String],
	socket_face_holder: Array
) -> Array[StructuralMountPad]:
	var markers := collect_pad_markers()
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
			for marker: MountPadMarker in markers:
				var pad := marker.to_pad()
				if pad == null:
					continue
				if marker.socket_kind == MountPadMarker.SocketKind.WHEEL_SOCKET:
					pad.socket_tag = "wheel_socket"
					socket_face_holder[0] = pad.local_face
					sockets += 1
				else:
					pad.socket_tag = ""
					structurals += 1
				_insert_pad(pad, by_key, pads)
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


func _build_wheel_definition(
	pads: Array[StructuralMountPad]
) -> WheelDefinition:
	var definition := WheelDefinition.new()
	definition.radius_m = wheel_radius_m
	definition.width_m = maxf(wheel_radius_m * 0.75, 0.05)
	definition.drive_torque_n_m = wheel_drive_torque_n_m
	definition.steerable_default = wheel_steerable
	var plug_face := OrientationUtil.Face.POS_Y
	for pad: StructuralMountPad in pads:
		if pad.socket_tag == "wheel_plug":
			plug_face = pad.local_face
			break
	definition.forward_axis_face = _perpendicular_face(plug_face)
	return definition


func _build_suspension_definition(
	socket_face: OrientationUtil.Face
) -> SuspensionDefinition:
	var definition := SuspensionDefinition.new()
	definition.wheel_socket_face = socket_face
	definition.suspension_travel_m = clampf(
		suspension_travel_m, definition.min_travel_m, definition.max_travel_m
	)
	definition.spring_stiffness_n_per_m = suspension_stiffness_n_per_m
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


func _roles_for_kind() -> PackedStringArray:
	match part_kind:
		PartKind.WHEEL:
			return PackedStringArray(["Support", "Actuator"])
		PartKind.SUSPENSION:
			return PackedStringArray(["Support"])
		_:
			return PackedStringArray(["Frame"])


func _auto_colliders(cells: Array[Vector3i]) -> Array[ColliderDefinition]:
	var colliders: Array[ColliderDefinition] = []
	for cell: Vector3i in cells:
		var collider := ColliderDefinition.new()
		collider.local_cell = cell  # defaults cover the cell centre
		colliders.append(collider)
	return colliders


func _insert_pad(
	pad: StructuralMountPad,
	by_key: Dictionary,
	ordered: Array[StructuralMountPad]
) -> void:
	var key := "%d,%d,%d,%d" % [
		pad.local_cell.x,
		pad.local_cell.y,
		pad.local_cell.z,
		int(pad.local_face),
	]
	if by_key.has(key):
		return
	by_key[key] = true
	ordered.append(pad)


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
		else:
			instance.free()


func _remove_preview() -> void:
	for preview_name: String in [FOOTPRINT_PREVIEW_NAME, VISUAL_PREVIEW_NAME]:
		var preview := get_node_or_null(preview_name)
		if preview != null:
			remove_child(preview)
			preview.free()
