extends Node3D
## Granular v0 look-and-feel playground: dump, scoop, watch it slump.
##
## Deliberately standalone — no voxel terrain, no simulation session — so the
## only question it answers is the one that matters first: does loose material
## read as loose material? Core logic and its invariants live in
## `GranularPatch` / `test_granular_patch`; this scene is the eye test.
##
## Debug playground: raw key events on purpose, no project input actions.

const GRID := 64
const CELL := 0.25
const BUCKET_M3 := 0.3
const TRUCK_M3 := 2.0
const SCOOP_RADIUS_CELLS := 3
## Relax steps per frame: material visibly flows instead of teleporting.
const RELAX_PER_FRAME := 2
const ROCK_MIN_THICKNESS := 0.015
## Above this the surface is deep spoil; rocks belong on the thin fringe and
## the toe, where the silhouette actually needs breaking up.
const ROCK_PEAK_THICKNESS := 0.12
const MAX_ROCKS := 4000
## Visual-only surface grain, metres. Not part of the field.
const GRAIN_AMPLITUDE_M := 0.02

const REPOSE_PRESETS: Array[Dictionary] = [
	{"name": "regolith", "deg": 33.0},
	{"name": "fines", "deg": 25.0},
	{"name": "blocky spoil", "deg": 45.0},
]

@onready var _surface: MeshInstance3D = $Surface
@onready var _collider: CollisionShape3D = $SurfaceBody/Shape
@onready var _rocks: MultiMeshInstance3D = $Rocks
@onready var _marker: MeshInstance3D = $AimMarker
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _rig: Node3D = $CameraRig
@onready var _overlay: Label = $CanvasLayer/Overlay
@onready var _status: Label = $CanvasLayer/Status

var _patch: GranularPatch
var _preset := 0
var _settled := true
var _rocks_visible := true
var _indices := PackedInt32Array()
var _display_heights := PackedFloat32Array()
var _aim := Vector3.ZERO
var _orbit_yaw := 0.6
var _orbit_pitch := -0.35
var _orbit_distance := 14.0
var _dragging := false
var _last_relax_iterations := 0


func _ready() -> void:
	_patch = GranularPatch.create(GRID, GRID, CELL, REPOSE_PRESETS[0]["deg"])
	_build_indices()
	_setup_collider()
	_setup_rocks()
	_rebuild_surface()
	_update_camera()
	_update_aim(get_viewport().get_visible_rect().size * 0.5)
	_maybe_start_scripted_shot()
	_overlay.text = "\n".join([
		"E — bucket (%.1f m3)   T — truck load (%.1f m3)" % [BUCKET_M3, TRUCK_M3],
		"Q — scoop   R — reset   F — detail rocks   G — material",
		"right mouse — orbit   wheel — zoom",
	])


func _process(_delta: float) -> void:
	if not _settled:
		_last_relax_iterations = _patch.relax(RELAX_PER_FRAME)
		_settled = _last_relax_iterations < RELAX_PER_FRAME
		_rebuild_surface()
		# Rocks follow the surface every frame: rebuilding only once settled
		# leaves them hanging where the slope used to be.
		_rebuild_rocks()
	_update_status()


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_distance = maxf(_orbit_distance - 1.0, 3.0)
			_update_camera()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_distance = minf(_orbit_distance + 1.0, 40.0)
			_update_camera()
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		if _dragging:
			_orbit_yaw -= motion.relative.x * 0.006
			_orbit_pitch = clampf(_orbit_pitch - motion.relative.y * 0.006, -1.4, -0.05)
			_update_camera()
		else:
			_update_aim(motion.position)
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_E:
			_dump(BUCKET_M3)
		KEY_T:
			_dump(TRUCK_M3)
		KEY_Q:
			_scoop()
		KEY_R:
			_reset()
		KEY_F:
			_rocks_visible = not _rocks_visible
			_rocks.visible = _rocks_visible
		KEY_G:
			_cycle_material()


## Aim ray onto the patch base plane, so dumping goes where you look.
func _update_aim(screen_position: Vector2) -> void:
	var plane := Plane(Vector3.UP, 0.0)
	var from := _camera.project_ray_origin(screen_position)
	var dir := _camera.project_ray_normal(screen_position)
	var hit: Variant = plane.intersects_ray(from, dir)
	if hit == null:
		return
	_aim = hit as Vector3
	_marker.position = Vector3(_aim.x, _surface_height_at(_aim) + 0.05, _aim.z)


func _surface_height_at(world_position: Vector3) -> float:
	var cell := _cell_at(world_position)
	var height := _patch.surface_height(cell.x, cell.y)
	return 0.0 if is_nan(height) else height


func _cell_at(world_position: Vector3) -> Vector2i:
	return Vector2i(
		clampi(int(round(world_position.x / CELL)), 0, GRID - 1),
		clampi(int(round(world_position.z / CELL)), 0, GRID - 1)
	)


func _dump(volume_m3: float) -> void:
	var cell := _cell_at(_aim)
	_patch.deposit(cell.x, cell.y, volume_m3)
	_settled = false


func _scoop() -> void:
	var cell := _cell_at(_aim)
	_patch.take(cell.x, cell.y, SCOOP_RADIUS_CELLS, BUCKET_M3)
	_settled = false


func _reset() -> void:
	_patch = GranularPatch.create(
		GRID, GRID, CELL, REPOSE_PRESETS[_preset]["deg"]
	)
	_settled = true
	_rebuild_surface()
	_rebuild_rocks()


func _cycle_material() -> void:
	_preset = (_preset + 1) % REPOSE_PRESETS.size()
	# Keep the material already on the ground and let it re-settle to the new
	# angle: the difference between 25 and 45 degrees is the whole point.
	var thickness := _patch.thickness_data()
	var next := GranularPatch.create(
		GRID, GRID, CELL, REPOSE_PRESETS[_preset]["deg"]
	)
	for z in GRID:
		for x in GRID:
			var value := thickness[z * GRID + x]
			if value > 0.0:
				next.deposit(x, z, value * next.cell_area_m2())
	_patch = next
	_settled = false


func _build_indices() -> void:
	_indices = PackedInt32Array()
	for z in GRID - 1:
		for x in GRID - 1:
			# Godot treats clockwise winding as front-facing; the other order
			# renders the whole patch inside-out.
			var i := z * GRID + x
			_indices.append(i)
			_indices.append(i + 1)
			_indices.append(i + GRID)
			_indices.append(i + 1)
			_indices.append(i + GRID + 1)
			_indices.append(i + GRID)


func _rebuild_surface() -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var count := GRID * GRID
	vertices.resize(count)
	normals.resize(count)
	colors.resize(count)
	_display_heights.resize(count)
	for z in GRID:
		for x in GRID:
			var i := z * GRID + x
			var thickness := _patch.thickness_at(x, z)
			# Presentation-only grain: a mathematically clean surface reads as
			# dough. The jitter never touches the field, so volume, repose and
			# determinism of the simulation stay exact.
			var grain := (_hash2(x + 2027, z + 911) - 0.5) * 2.0 * minf(
				thickness * 0.4, GRAIN_AMPLITUDE_M
			)
			_display_heights[i] = thickness + grain
			var tint := clampf(thickness / 0.08, 0.0, 1.0)
			# Fresh spoil is only slightly lighter than undisturbed ground; the
			# contrast comes from the low sun, not from albedo. Vertex colours
			# are linear while `albedo_color` is sRGB, so convert here or the
			# surface blows out white next to sRGB-authored materials.
			colors[i] = (
				Color(0.40, 0.39, 0.37)
				.lerp(Color(0.55, 0.53, 0.50), tint)
				.srgb_to_linear()
			)
			colors[i].a = tint
	for z in GRID:
		for x in GRID:
			var i := z * GRID + x
			vertices[i] = Vector3(
				float(x) * CELL, _display_heights[i], float(z) * CELL
			)
			var left := _display_heights[maxi(x - 1, 0) + z * GRID]
			var right := _display_heights[mini(x + 1, GRID - 1) + z * GRID]
			var back := _display_heights[x + maxi(z - 1, 0) * GRID]
			var front := _display_heights[x + mini(z + 1, GRID - 1) * GRID]
			normals[i] = Vector3(
				left - right, 2.0 * CELL, back - front
			).normalized()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = _indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_surface.mesh = mesh
	_update_collider()


func _setup_collider() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = GRID
	shape.map_depth = GRID
	_collider.shape = shape
	# HeightMapShape3D samples are one unit apart and centred on the shape, so
	# scale uniformly (Jolt rejects non-uniform height fields) and store
	# heights in cell units.
	_collider.scale = Vector3(CELL, CELL, CELL)
	var half := float(GRID - 1) * CELL * 0.5
	$SurfaceBody.position = Vector3(half, 0.0, half)


func _update_collider() -> void:
	var shape := _collider.shape as HeightMapShape3D
	if shape == null:
		return
	var source := _patch.height_map_data()
	# `map_data` is PackedFloat32Array in stock Godot and PackedFloat64Array in
	# the double-precision build, so take the array from the property itself
	# instead of naming a type here.
	var data := shape.map_data
	if data.size() != source.size():
		data.resize(source.size())
	for i in source.size():
		# NAN survives the divide and stays a hole in the collider.
		data[i] = source[i] / CELL
	shape.map_data = data


func _setup_rocks() -> void:
	# Boxes at random angles read as broken clasts; spheres read as beads.
	# Their own material: the surface one turns vertex colours into albedo and
	# a MultiMesh has none, so rocks came out white.
	var rock := BoxMesh.new()
	rock.size = Vector3.ONE
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = rock
	multimesh.instance_count = MAX_ROCKS
	multimesh.visible_instance_count = 0
	_rocks.multimesh = multimesh


## Detail rocks are decoration driven by the field, not simulated bodies:
## dense on the thin fringe and the toe where they break the silhouette,
## sparse on deep spoil where nothing shows anyway.
func _rebuild_rocks() -> void:
	var multimesh := _rocks.multimesh
	var placed := 0
	for z in GRID:
		for x in GRID:
			if placed >= MAX_ROCKS:
				break
			var thickness := _patch.thickness_at(x, z)
			if thickness < ROCK_MIN_THICKNESS:
				continue
			var hash_value := _hash2(x, z)
			var density := 1.0 - clampf(thickness / ROCK_PEAK_THICKNESS, 0.0, 0.85)
			if hash_value > density:
				continue
			var jitter_x := (_hash2(x + 977, z) - 0.5) * CELL
			var jitter_z := (_hash2(x, z + 613) - 0.5) * CELL
			var size := 0.07 + _hash2(x + 31, z + 17) * 0.16
			var world_x := float(x) * CELL + jitter_x
			var world_z := float(z) * CELL + jitter_z
			var origin := Vector3(
				world_x,
				# Sample where the rock actually stands, not at the cell
				# centre: half a cell downslope is 16 cm lower at repose, and
				# that is what left them hanging in the air. Bury over half so
				# they sit in the material instead of on it.
				_sample_display_height(world_x, world_z) - size * 0.3,
				world_z
			)
			var basis := Basis.from_euler(
				Vector3(
					_hash2(x + 5, z + 91) * TAU,
					_hash2(x + 71, z + 3) * TAU,
					_hash2(x + 13, z + 47) * TAU
				)
			).scaled(
				Vector3(size, size * 0.55, size * 0.8)
			)
			multimesh.set_instance_transform(placed, Transform3D(basis, origin))
			placed += 1
	multimesh.visible_instance_count = placed


## `run.sh res://scenes/granular_playground.tscn -- --shot <png>` pours a fixed
## set of loads, lets them settle and writes one frame. Repeatable eye test:
## the same piles, the same sun, every run.
func _maybe_start_scripted_shot() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--shot")
	if index < 0 or index + 1 >= args.size():
		return
	_run_scripted_shot(args[index + 1])


func _run_scripted_shot(path: String) -> void:
	var loads: Array[Vector3] = [
		Vector3(4.0, 0.0, 6.0),
		Vector3(4.6, 0.0, 6.4),
		Vector3(9.5, 0.0, 5.0),
		Vector3(11.0, 0.0, 9.0),
		Vector3(11.4, 0.0, 9.6),
		Vector3(11.8, 0.0, 10.2),
	]
	for point: Vector3 in loads:
		var cell := _cell_at(point)
		_patch.deposit(cell.x, cell.y, TRUCK_M3)
	_patch.relax(400)
	_rebuild_surface()
	_rebuild_rocks()
	_settled = true
	_orbit_pitch = -0.28
	_orbit_distance = 17.0
	_update_camera()
	_capture_after_frames(path, 4)


func _capture_after_frames(path: String, frames: int) -> void:
	for _i in frames:
		await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("granular shot failed: %d" % error)
	print("granular shot: %s" % path)
	get_tree().quit(0 if error == OK else 1)


## Bilinear surface height at an arbitrary point of the patch, using the
## displayed (grained) heights so decoration sits on what is drawn.
func _sample_display_height(world_x: float, world_z: float) -> float:
	var fx := clampf(world_x / CELL, 0.0, float(GRID - 1))
	var fz := clampf(world_z / CELL, 0.0, float(GRID - 1))
	var x0 := int(fx)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, GRID - 1)
	var z1 := mini(z0 + 1, GRID - 1)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var top: float = lerpf(
		_display_heights[z0 * GRID + x0], _display_heights[z0 * GRID + x1], tx
	)
	var bottom: float = lerpf(
		_display_heights[z1 * GRID + x0], _display_heights[z1 * GRID + x1], tx
	)
	return lerpf(top, bottom, tz)


## Deterministic per-cell hash in 0..1 — same layout every run and for every
## peer, no RNG state to replicate.
func _hash2(x: int, z: int) -> float:
	var h := (x * 73856093) ^ (z * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	return float(absi(h) % 100000) / 100000.0


func _update_camera() -> void:
	var half := float(GRID - 1) * CELL * 0.5
	_rig.position = Vector3(half, 0.0, half)
	var direction := Vector3(
		cos(_orbit_pitch) * sin(_orbit_yaw),
		-sin(_orbit_pitch),
		cos(_orbit_pitch) * cos(_orbit_yaw)
	)
	_camera.position = direction * _orbit_distance
	_camera.look_at(_rig.global_position, Vector3.UP)


func _update_status() -> void:
	_status.text = "%s (%.0f deg)   %.2f m3   %s   rocks %d" % [
		REPOSE_PRESETS[_preset]["name"],
		REPOSE_PRESETS[_preset]["deg"],
		_patch.total_volume_m3(),
		"settled" if _settled else "flowing",
		_rocks.multimesh.visible_instance_count,
	]
