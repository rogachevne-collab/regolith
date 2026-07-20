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
## Held-pour rate: sweeping the aim while pouring lays a windrow, the way a
## moving tipper does, instead of stacking one symmetric cone.
const POUR_RATE_M3_PER_S := 0.7
const POUR_RADIUS_CELLS := 1.6
const TRUCK_RADIUS_CELLS := 3.4
## A tipper drops its load away from itself, so the lobe comes out elongated.
const TRUCK_ELONGATION := 1.9
## Visual-only surface grain, metres. Not part of the field.
const GRAIN_AMPLITUDE_M := 0.02
## World metres per albedo/normal tile on the spoil mesh.
const SURFACE_UV_METRES := 2.5
const MAX_CRATES := 12
const CRATE_SIZE_M := 0.6
## Cut disc must cover the whole square footprint plus half a cell: the
## heightfield interpolates up to the first uncut neighbour, and a disc that
## only circumscribes the box leaves a high collar under the faces — the crate
## sits on that slope at 0 cm in. Spoil still starts past HEAVE_GAP, so the
## margin is support flat, not a berm to perch on.
const CRATE_RADIUS_M := CRATE_SIZE_M * 0.7071 + CELL * 0.5
const LIGHT_CRATE_KG := 40.0
const HEAVY_CRATE_KG := 500.0
## Depth of the test bed laid by Y: deep enough for a heavy load to bed itself
## in, since nothing sinks further than the loose layer is thick.
const TEST_BED_M := 0.7
## Below this an impact just presses; above it, it also shakes the slope loose.
const IMPACT_SPEED_M_S := 1.5
const IMPACT_SHAKE_M_PER_SPEED := 0.35
const MAX_SHAKE_RADIUS_M := 3.0
## How far below a buried body the surface must drop before it is let go.
const UNBURY_CLEARANCE_M := 0.05
## Contact area never shrinks below a cell — the plastic-redistribution stand-in
## for a cube corner that would otherwise claim infinite pressure.
const MIN_CONTACT_AREA_M2 := CELL * CELL
## Dynamic pressure from a hard landing, clamped so a drop is spectacular but
## does not dig a shaft.
const DYN_PRESSURE_PER_MS := 800.0
const DYN_MAX_RATIO := 1.8
const MAX_CONTACT_PRESSURE_PA := 4500.0

const REPOSE_PRESETS: Array[Dictionary] = [
	{"name": "regolith", "deg": 33.0, "density": 1.0},
	{"name": "fines", "deg": 25.0, "density": 0.55},
	{"name": "blocky spoil", "deg": 45.0, "density": 2.5},
]

@onready var _surface: MeshInstance3D = $Surface
@onready var _collider: CollisionShape3D = $SurfaceBody/Shape
@onready var _marker: MeshInstance3D = $AimMarker
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _rig: Node3D = $CameraRig
@onready var _overlay: Label = $CanvasLayer/Overlay
@onready var _status: Label = $CanvasLayer/Status

var _patch: GranularPatch
var _preset := 0
var _settled := true
var _indices := PackedInt32Array()
var _crates: Array[RigidBody3D] = []
var _pouring := false
var _dump_seq := 0
var _display_heights := PackedFloat32Array()
var _shown_thickness := PackedFloat32Array()
var _aim := Vector3.ZERO
var _orbit_yaw := 0.6
var _orbit_pitch := -0.35
var _orbit_distance := 14.0
var _dragging := false
var _gravity := 1.62
var _heavy_crate_material: Material
var _light_crate_material: Material
var _debug_load := ""


func _ready() -> void:
	_gravity = float(
		ProjectSettings.get_setting("physics/3d/default_gravity", 1.62)
	)
	_patch = _make_patch()
	_shown_thickness = _patch.thickness_data()
	_build_indices()
	_setup_collider()
	_rebuild_surface()
	_update_camera()
	_update_aim(get_viewport().get_visible_rect().size * 0.5)
	_maybe_start_scripted_shot()
	_overlay.text = "\n".join([
		"E — hold to pour (%.1f m3/s), sweep to lay a windrow" % POUR_RATE_M3_PER_S,
		"T — tip a truck load (%.1f m3) away from the camera" % TRUCK_M3,
		"Q — scoop   B — light crate (%.0f kg)   N — heavy crate (%.0f kg)"
		% [LIGHT_CRATE_KG, HEAVY_CRATE_KG],
		"Y — lay a %.1f m test bed   R — reset" % TEST_BED_M,
		"G — material (repose + density / bearing)",
		"right mouse — orbit   wheel — zoom",
	])


func _process(delta: float) -> void:
	if _pouring:
		_deposit_lobe(
			_aim,
			POUR_RATE_M3_PER_S * delta,
			POUR_RADIUS_CELLS,
			Vector2.RIGHT,
			1.0
		)
	if not _patch.is_settled():
		# Settling runs on wall-clock time under the project's gravity, so
		# lunar material slumps at lunar speed instead of at frame rate.
		_patch.advance(delta, _gravity)
	if _advance_shown(delta):
		_rebuild_surface()
	_settled = _patch.is_settled()
	_update_status()


## Bodies displace material where they press into it. Runs on the physics
## tick because it reads settled contact poses, not interpolated ones.
func _physics_process(delta: float) -> void:
	_patch.clear_ceilings()
	for crate: RigidBody3D in _crates:
		if not is_instance_valid(crate):
			continue
		var position := crate.global_position
		var surface := _patch.surface_height_at_m(position.x, position.z)
		if is_nan(surface):
			continue
		# Exact half-extent along Y for the box at its current orientation:
		# taking the corner-to-corner radius instead made every crate dig a
		# hole 22 cm deeper than itself while lying flat.
		var basis := crate.global_transform.basis
		var half_height := (
			absf(basis.x.y) + absf(basis.y.y) + absf(basis.z.y)
		) * CRATE_SIZE_M * 0.5
		var bottom := position.y - half_height
		var top := position.y + half_height
		if crate.freeze:
			# Freed only once the material is dug out from under it, not the
			# moment its lid is uncovered: waking a body that still overlaps
			# the height field makes the solver fling it clear.
			if surface <= bottom + UNBURY_CLEARANCE_M:
				crate.freeze = false
			continue
		if top <= surface:
			# Fully covered. A height field is a surface, not a volume: it has
			# no inside, so a body under it gets pushed in whatever direction
			# the solver picks and thrashes its way out. Buried things stay
			# buried — dig them out to get them back.
			_bury(crate)
			continue
		# Loose material carries only so much pressure. Static weight, a
		# clamped impact spike, and material density decide how far it beds
		# in; the column is lidded so spoil cannot slump back underneath.
		var pressure := _contact_pressure(crate)
		var floor_height := _patch.settle_load(
			position.x, position.z, CRATE_RADIUS_M, bottom, pressure, delta
		)
		_debug_load = "  [bottom %.3f surf %.3f floor %.3f gnd %.3f]" % [
			bottom,
			surface,
			floor_height,
			_patch.ground_level_around(position.x, position.z, CRATE_RADIUS_M),
		]
		if floor_height < bottom - GranularPatch.SETTLE_MAX_CELL_M:
			# Deforming a static collider does not wake the bodies resting on
			# it, so a load that has settled sleeps through its own bedding in
			# and never falls into the hollow the material yields under it.
			# Keep it awake for as long as it is still going down; writing its
			# position instead fought the solver and made it judder.
			crate.can_sleep = false
			crate.sleeping = false
		elif not crate.can_sleep:
			crate.can_sleep = true
		if crate.sleeping:
			continue
		# An impact shakes the slope around it loose: a metastable face that
		# was standing on its own can let go when something lands on it. The
		# radius scales with how hard the hit was.
		var speed := crate.linear_velocity.length()
		if speed > IMPACT_SPEED_M_S:
			_patch.mobilize(
				position.x,
				position.z,
				minf(
					CRATE_RADIUS_M + speed * IMPACT_SHAKE_M_PER_SPEED,
					MAX_SHAKE_RADIUS_M
				)
			)


## Hand a covered body over to the material: it stops being simulated rather
## than fighting a collider that cannot represent being inside it.
func _bury(crate: RigidBody3D) -> void:
	if crate.freeze:
		return
	crate.linear_velocity = Vector3.ZERO
	crate.angular_velocity = Vector3.ZERO
	crate.freeze = true


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
	if key == null or key.echo:
		return
	if key.keycode == KEY_E:
		_pouring = key.pressed
		return
	if not key.pressed:
		return
	match key.keycode:
		KEY_T:
			_dump_truck()
		KEY_B:
			_drop_crate(LIGHT_CRATE_KG)
		KEY_N:
			_drop_crate(HEAVY_CRATE_KG)
		KEY_Y:
			_lay_test_bed()
		KEY_Q:
			_scoop()
		KEY_R:
			_reset()
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


func _dump_truck() -> void:
	# Away from the camera, like a bed tipping backwards.
	var away := Vector2(_aim.x - _camera.global_position.x, _aim.z - _camera.global_position.z)
	if away.length_squared() < 1e-4:
		away = Vector2.RIGHT
	_deposit_lobe(
		_aim, TRUCK_M3, TRUCK_RADIUS_CELLS, away.normalized(), TRUCK_ELONGATION
	)


## Drop a rigid crate. It lands on the height field and presses into it: the
## footprint is cut down to the crate's lowest point and the spoil is piled in
## a rim around it, so a drop leaves a crater with a raised lip and dragging
## one leaves a rut with berms. The material still does not push back — that
## is the next stage.
func _drop_crate(mass_kg: float) -> void:
	var crate := RigidBody3D.new()
	crate.mass = mass_kg
	# Lunar gravity makes a crate dropped from head height tumble away before
	# it ever settles; damp it so it lands where it was aimed.
	crate.linear_damp = 0.6
	crate.angular_damp = 2.0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CRATE_SIZE_M, CRATE_SIZE_M, CRATE_SIZE_M)
	shape.shape = box
	crate.add_child(shape)
	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = box.size
	mesh.mesh = box_mesh
	mesh.material_override = (
		_heavy_material() if mass_kg >= HEAVY_CRATE_KG else _light_material()
	)
	crate.add_child(mesh)
	crate.position = Vector3(
		_aim.x, _sample_display_height(_aim.x, _aim.z) + 1.2, _aim.z
	)
	add_child(crate)
	_crates.append(crate)
	while _crates.size() > MAX_CRATES:
		var oldest: RigidBody3D = _crates.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()


## Spread a load over a lobe instead of a single cell. One cell makes a spike
## that always collapses into the same symmetric cone; a real bucket covers
## about a metre, and the per-load jitter keeps two identical dumps from
## producing identical piles.
func _deposit_lobe(
	center: Vector3,
	volume_m3: float,
	radius_cells: float,
	direction: Vector2,
	elongation: float
) -> void:
	if volume_m3 <= 0.0:
		return
	_dump_seq += 1
	var fx := center.x / CELL
	var fz := center.z / CELL
	var across := Vector2(-direction.y, direction.x)
	var reach := int(ceil(radius_cells * maxf(elongation, 1.0))) + 1
	var cells := PackedInt32Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := int(round(fx)) + dx
			var z := int(round(fz)) + dz
			if not _patch.in_bounds(x, z):
				continue
			var offset := Vector2(float(x) - fx, float(z) - fz)
			var along := offset.dot(direction) / elongation
			var side := offset.dot(across)
			var distance_sq := along * along + side * side
			var radius_sq := radius_cells * radius_cells
			if distance_sq > radius_sq:
				continue
			var weight := 1.0 - distance_sq / radius_sq
			weight *= 0.65 + _hash2(x * 7 + _dump_seq, z * 13 + _dump_seq) * 0.7
			if weight <= 0.0:
				continue
			cells.append(_patch.index(x, z))
			weights.append(weight)
			total += weight
	if total <= 0.0:
		_patch.deposit(int(round(fx)), int(round(fz)), volume_m3)
		return
	for k in cells.size():
		var i := cells[k]
		_patch.deposit(i % GRID, i / GRID, volume_m3 * weights[k] / total)


func _scoop() -> void:
	var cell := _cell_at(_aim)
	_patch.take(cell.x, cell.y, SCOOP_RADIUS_CELLS, BUCKET_M3)


func _reset() -> void:
	_patch = _make_patch()
	_settled = true
	_shown_thickness = _patch.thickness_data()
	for crate: RigidBody3D in _crates:
		if is_instance_valid(crate):
			crate.queue_free()
	_crates.clear()
	_rebuild_surface()


func _make_patch() -> GranularPatch:
	var patch := GranularPatch.create(
		GRID, GRID, CELL, REPOSE_PRESETS[_preset]["deg"]
	)
	patch.density_scale = float(REPOSE_PRESETS[_preset]["density"])
	return patch


## Ground pressure under a crate: mg over a clamped contact area, plus a
## capped spike from downward speed so a hard drop digs more than a soft set.
func _contact_pressure(crate: RigidBody3D) -> float:
	var upright := absf(crate.global_transform.basis.y.y)
	var area := CRATE_SIZE_M * CRATE_SIZE_M * clampf(upright, 0.25, 1.0)
	area = maxf(area, MIN_CONTACT_AREA_M2)
	var p_static := crate.mass * _gravity / area
	var v_down := maxf(-crate.linear_velocity.y, 0.0)
	var p_dyn := minf(v_down * DYN_PRESSURE_PER_MS, p_static * DYN_MAX_RATIO)
	return minf(p_static + p_dyn, MAX_CONTACT_PRESSURE_PA)


func _cycle_material() -> void:
	_preset = (_preset + 1) % REPOSE_PRESETS.size()
	# Keep the material already on the ground and let it re-settle to the new
	# angle and density: fines slump and bog, blocky spoil stands and carries.
	var thickness := _patch.thickness_data()
	var next := _make_patch()
	for z in GRID:
		for x in GRID:
			var value := thickness[z * GRID + x]
			if value > 0.0:
				next.deposit(x, z, value * next.cell_area_m2())
	_patch = next
	_shown_thickness = _patch.thickness_data()


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
	var uvs := PackedVector2Array()
	var count := GRID * GRID
	vertices.resize(count)
	normals.resize(count)
	colors.resize(count)
	uvs.resize(count)
	_display_heights.resize(count)
	for z in GRID:
		for x in GRID:
			var i := z * GRID + x
			var thickness := _shown_thickness[i]
			# Presentation-only grain: a mathematically clean surface reads as
			# dough. The jitter never touches the field, so volume, repose and
			# determinism of the simulation stay exact.
			var grain := (_hash2(x + 2027, z + 911) - 0.5) * 2.0 * minf(
				thickness * 0.4, GRAIN_AMPLITUDE_M
			)
			_display_heights[i] = thickness + grain
			uvs[i] = Vector2(
				float(x) * CELL / SURFACE_UV_METRES,
				float(z) * CELL / SURFACE_UV_METRES
			)
			# Texture carries the look; vertex colour only fades empty cells and
			# slightly lifts thick fresh spoil. Keep values in sRGB — the
			# albedo texture path expects that when multiplied.
			var cover := clampf(thickness / 0.035, 0.0, 1.0)
			var fresh := clampf(thickness / 0.14, 0.0, 1.0)
			colors[i] = Color(0.9, 0.88, 0.84).lerp(Color(1.0, 0.98, 0.94), fresh)
			colors[i].a = cover
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
	arrays[Mesh.ARRAY_TEX_UV] = uvs
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
		# Collide against the field itself, not the smoothed surface drawn
		# from it. The drawn one lags by a sweep, and a body resting on that
		# lag never falls into the hollow it has just yielded — it hangs there
		# while the material keeps yielding under it.
		# NAN survives the divide and stays a hole in the collider.
		data[i] = source[i] / CELL
	shape.map_data = data


## Flood the patch with an even bed of loose material. A load can never sink
## deeper than the loose layer is thick, so bearing capacity is invisible on a
## thin scatter over bedrock.
func _lay_test_bed() -> void:
	for z in GRID:
		for x in GRID:
			var missing := TEST_BED_M - _patch.thickness_at(x, z)
			if missing > 0.0:
				_patch.deposit(x, z, missing * _patch.cell_area_m2())


func _heavy_material() -> Material:
	if _heavy_crate_material == null:
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.52, 0.44, 0.30)
		material.roughness = 0.8
		_heavy_crate_material = material
	return _heavy_crate_material


func _light_material() -> Material:
	if _light_crate_material == null:
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.33, 0.32, 0.30)
		material.roughness = 1.0
		_light_crate_material = material
	return _light_crate_material


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
		_deposit_lobe(
			point, TRUCK_M3, TRUCK_RADIUS_CELLS, Vector2.RIGHT, TRUCK_ELONGATION
		)
	_patch.relax(400)
	_rebuild_surface()
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


## The field steps at the settle rate — about 10 Hz under lunar gravity —
## while the screen runs at 60, so drawing the raw field looks like 10 fps of
## material inside a 60 fps game. Chase it with a critically damped filter
## whose time constant is one sweep: the simulation stays authoritative and
## the presentation is continuous, the same split the engine makes for
## physics interpolation. Returns true when anything moved.
func _advance_shown(delta: float) -> bool:
	var target := _patch.thickness_data()
	if _shown_thickness.size() != target.size():
		_shown_thickness = target
		return true
	var tau := 1.0 / maxf(_patch.settle_rate_hz(_gravity), 0.01)
	var blend := 1.0 - exp(-delta / tau)
	var moved := false
	for i in target.size():
		var difference := target[i] - _shown_thickness[i]
		if absf(difference) < 1e-5:
			if _shown_thickness[i] != target[i]:
				_shown_thickness[i] = target[i]
				moved = true
			continue
		_shown_thickness[i] += difference * blend
		moved = true
	return moved


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
	_status.text = "%s (rests %.0f, dens %.2f)   %.2f m3   %s%s" % [
		REPOSE_PRESETS[_preset]["name"],
		REPOSE_PRESETS[_preset]["deg"],
		REPOSE_PRESETS[_preset]["density"],
		_patch.total_volume_m3(),
		(
			"settled"
			if _settled
			else "sliding %.2f m3" % _patch.flowing_volume_m3()
		),
		_crate_report() + _collider_report() + _debug_load,
	]


## Where the collider actually is under the aim, against where the field says
## the surface is. Bodies rest on the collider, so if these two disagree
## nothing a load does to the material can affect it.
func _collider_report() -> String:
	var field := _patch.surface_height_at_m(_aim.x, _aim.z)
	if is_nan(field):
		return ""
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(_aim.x, field + 5.0, _aim.z), Vector3(_aim.x, field - 5.0, _aim.z)
	)
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return "   collider MISSING (field %.2f)" % field
	return "   collider %.2f / field %.2f" % [(hit["position"] as Vector3).y, field]


## Embedment of the newest crate, so the difference between a light and a
## heavy load is a number and not a matter of opinion.
func _crate_report() -> String:
	if _crates.is_empty():
		return ""
	var crate: RigidBody3D = _crates[-1]
	if not is_instance_valid(crate):
		return ""
	var ground := _patch.ground_level_around(
		crate.global_position.x, crate.global_position.z, CRATE_RADIUS_M
	)
	if is_nan(ground):
		return ""
	var basis := crate.global_transform.basis
	var half_height := (
		absf(basis.x.y) + absf(basis.y.y) + absf(basis.z.y)
	) * CRATE_SIZE_M * 0.5
	var pressure := _contact_pressure(crate)
	return "   crate %.0f kg: %.0f Pa, %.2f m in (limit %.2f)" % [
		crate.mass,
		pressure,
		maxf(ground - (crate.global_position.y - half_height), 0.0),
		_patch.penetration_depth_m(pressure),
	]
