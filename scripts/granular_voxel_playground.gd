extends Node3D
## Visual stand for the volumetric granular field: pour it, watch it flow.
##
## The material here is a *volume* of 0.25 m cells run by `GranularVoxelField`,
## placed by a `GranularVoxelRegion` and drawn by a `GranularVoxelRegionView`.
## Nothing is draped over anything: there is no second surface competing with
## the ground, which is what made the earlier height-field approach read as a
## plate laid on the landscape.
##
## The stand owns none of that logic — it only builds some rock, points at it
## and pours. If something looks wrong here it is wrong in the region or the
## field, not in the demo.
##
## Debug stand: raw key events on purpose, no project input actions.

const CELL := 0.25
## 16 m cube of working volume.
const CELLS := 64
## Rock the material lands on, in field cells: a floor, and a ledge on one half
## so a pour can run off an edge instead of only making a cone.
const FLOOR_CELLS := 3
const LEDGE_HEIGHT_CELLS := 18
const LEDGE_FROM_Z := 38

const POUR_RATE_M3_PER_S := 1.2
const DUMP_M3 := 2.5
const POUR_RADIUS_CELLS := 3
## How far above the aimed surface the stream starts. Enough to read as
## falling, not so much that it scatters on the way down.
const POUR_HEIGHT_M := 1.5
const SCOOP_RADIUS_M := 0.8
## Settling runs on wall-clock here, which is fine for a stand. In the world it
## has to hang off the simulation's fixed tick instead, or the number of sweeps
## depends on the frame rate and two peers diverge.
const SETTLE_HZ := 30.0
const CELL_BUDGET_PER_SWEEP := 128

@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _rig: Node3D = $CameraRig
@onready var _overlay: Label = $CanvasLayer/Overlay
@onready var _status: Label = $CanvasLayer/Status

var _region: GranularVoxelRegion
var _view: GranularVoxelRegionView
var _sweep_debt := 0.0
var _pouring := false
var _aim := Vector3.ZERO
var _orbit_yaw := 0.7
var _orbit_pitch := -0.4
var _orbit_distance := 26.0
var _dragging := false
var _last_sweep_ms := 0.0
var _poured_m3 := 0.0


func _ready() -> void:
	# Centred on the origin with plain +Y up: the stand is flat ground on
	# purpose, because the radial case is checked headless in the CA bench
	# where it can be measured rather than eyeballed.
	var half := float(CELLS) * CELL * 0.5
	_region = GranularVoxelRegion.create(
		Vector3(0.0, half, 0.0), Vector3.UP, null, null, CELLS, CELL
	)
	_build_rock()
	_view = GranularVoxelRegionView.new()
	add_child(_view)
	_view.setup(_region)
	_update_camera()
	_update_aim(get_viewport().get_visible_rect().size * 0.5)
	_overlay.text = "\n".join([
		"E — hold to pour (%.1f m3/s)   T — dump %.1f m3" % [
			POUR_RATE_M3_PER_S, DUMP_M3
		],
		"Q — scoop   R — reset",
		"right mouse — orbit   wheel — zoom",
	])
	_maybe_start_scripted_shot()


## Rock is marked in the field, so material rests on it, and drawn as plain
## boxes. The fine terrain carries only loose material — mixing the world's
## rock into it is exactly the confusion this design avoids.
func _build_rock() -> void:
	var field := _region.field
	for z in CELLS:
		for x in CELLS:
			for y in FLOOR_CELLS:
				field.set_solid(x, y, z, true)
			if z >= LEDGE_FROM_Z:
				for y in range(FLOOR_CELLS, LEDGE_HEIGHT_CELLS):
					field.set_solid(x, y, z, true)
	_add_rock_box(
		Vector3i(0, 0, 0), Vector3i(CELLS, FLOOR_CELLS, CELLS)
	)
	_add_rock_box(
		Vector3i(0, FLOOR_CELLS, LEDGE_FROM_Z),
		Vector3i(CELLS, LEDGE_HEIGHT_CELLS - FLOOR_CELLS, CELLS - LEDGE_FROM_Z)
	)


## Draw a box of rock cells, placed *and oriented* by the region's own frame.
## The frame's tangent axes are derived from local up, and for plain +Y that is
## still a rotation rather than the identity — so a box positioned with world
## axes ends up somewhere else entirely from the cells the field believes are
## solid, and material lands on rock that is not drawn where it appears to be.
func _add_rock_box(from_cell: Vector3i, size_cells: Vector3i) -> void:
	var dimensions := Vector3(size_cells) * CELL
	var frame := _region.world_transform()
	var local_centre := (Vector3(from_cell) + Vector3(size_cells) * 0.5) * CELL
	var body := StaticBody3D.new()
	body.transform = Transform3D(frame.basis, frame * local_centre)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = dimensions
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = dimensions
	mesh.mesh = box_mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.30, 0.30, 0.31)
	material.roughness = 1.0
	mesh.material_override = material
	body.add_child(mesh)
	add_child(body)


func _process(delta: float) -> void:
	if _pouring:
		_poured_m3 += _region.deposit_at(
			_aim, POUR_RATE_M3_PER_S * delta, POUR_RADIUS_CELLS
		)
	_sweep_debt += delta * SETTLE_HZ
	var sweeps := mini(int(_sweep_debt), 3)
	if sweeps > 0:
		_sweep_debt -= float(sweeps)
		var started := Time.get_ticks_usec()
		for _i in sweeps:
			_region.field.step(CELL_BUDGET_PER_SWEEP)
		_last_sweep_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_view.flush()
	_update_status()


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_distance = maxf(_orbit_distance - 1.5, 5.0)
			_update_camera()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_distance = minf(_orbit_distance + 1.5, 60.0)
			_update_camera()
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		if _dragging:
			_orbit_yaw -= motion.relative.x * 0.006
			_orbit_pitch = clampf(
				_orbit_pitch - motion.relative.y * 0.006, -1.4, -0.05
			)
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
			_poured_m3 += _region.deposit_at(_aim, DUMP_M3, POUR_RADIUS_CELLS)
		KEY_Q:
			_region.dig_at(_aim, SCOOP_RADIUS_M)
		KEY_R:
			_reset()


func _reset() -> void:
	var field := _region.field
	for y in field.size.y:
		for z in field.size.z:
			for x in field.size.x:
				field.take(x, y, z)
	_poured_m3 = 0.0


## Aim at whatever surface you are looking at — rock or an existing heap — and
## pour from just above it. A fixed horizontal plane meant the stream always
## started at one height regardless of what was underneath.
func _update_aim(screen_position: Vector2) -> void:
	var from := _camera.project_ray_origin(screen_position)
	var direction := _camera.project_ray_normal(screen_position)
	var query := PhysicsRayQueryParameters3D.create(
		from, from + direction * 200.0
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		_aim = (hit["position"] as Vector3) + Vector3.UP * POUR_HEIGHT_M
		return
	var plane := Plane(Vector3.UP, float(LEDGE_HEIGHT_CELLS) * CELL)
	var fallback: Variant = plane.intersects_ray(from, direction)
	if fallback != null:
		_aim = (fallback as Vector3) + Vector3.UP * POUR_HEIGHT_M


func _update_camera() -> void:
	_rig.position = Vector3(0.0, float(LEDGE_HEIGHT_CELLS) * CELL * 0.5, 0.0)
	var direction := Vector3(
		cos(_orbit_pitch) * sin(_orbit_yaw),
		-sin(_orbit_pitch),
		cos(_orbit_pitch) * cos(_orbit_yaw)
	)
	_camera.position = direction * _orbit_distance
	_camera.look_at(_rig.global_position, Vector3.UP)


func _update_status() -> void:
	_status.text = (
		"%.2f m3 poured / %.2f m3 held   active %d   sweep %.2f ms   flush %s   %s"
		% [
			_poured_m3,
			_region.field.total_volume_m3(),
			_region.field.active_count(),
			_last_sweep_ms,
			_view.flush_report(),
			"settled" if _region.field.is_settled() else "flowing",
		]
	)


## `run.sh res://scenes/granular_voxel_playground.tscn -- --shot <png>` pours a
## fixed set of loads on the lip of the ledge, lets them run off it and writes
## one frame. Repeatable eye test: the same pile, the same sun, every run.
func _maybe_start_scripted_shot() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--shot")
	if index < 0 or index + 1 >= args.size():
		return
	_run_scripted_shot(args[index + 1])


func _run_scripted_shot(path: String) -> void:
	# The view holds its first writes back until the terrain has streamed, so
	# give it those frames before pouring anything.
	for _i in 45:
		await get_tree().process_frame
	# Pour points named in cells and converted through the region, never in
	# world axes: the frame is rotated, so a world-space guess lands somewhere
	# other than the lip it was meant for.
	for offset: int in [-6, 0, 6]:
		_poured_m3 += _region.deposit_at(
			_region.cell_to_world(
				Vector3i(
					CELLS / 2 + offset,
					LEDGE_HEIGHT_CELLS + 4,
					LEDGE_FROM_Z + 1
				)
			),
			DUMP_M3,
			POUR_RADIUS_CELLS
		)
	# No per-sweep budget: the cap protects a live frame and a shot has none.
	var guard := 0
	while not _region.field.is_settled() and guard < 8000:
		_region.field.step()
		guard += 1
	_view.flush()
	_orbit_yaw = 0.55
	_orbit_pitch = -0.30
	_orbit_distance = 22.0
	_update_camera()
	print(
		"granular voxel shot: %.2f m3 held, settled after %d sweeps, flush %s"
		% [_region.field.total_volume_m3(), guard, _view.flush_report()]
	)
	for _i in 45:
		await get_tree().process_frame
	var probe_top := _region.cell_to_world(
		Vector3i(CELLS / 2, CELLS - 1, LEDGE_FROM_Z + 1)
	)
	var probe := PhysicsRayQueryParameters3D.create(
		probe_top, probe_top - _region.up() * float(CELLS) * CELL
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(probe)
	print(
		"granular voxel shot: probe %s"
		% ("MISS" if hit.is_empty() else "hit %s" % str(hit["position"]))
	)
	await _capture(path)


func _capture(path: String) -> void:
	for _i in 30:
		await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("granular voxel shot failed: %d" % error)
	print("granular voxel shot: %s" % path)
	get_tree().quit(0 if error == OK else 1)
