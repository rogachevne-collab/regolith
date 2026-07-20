extends Node3D
## Visual stand for the volumetric granular field: pour it, watch it flow.
##
## This is the eye test for the replacement of the height-field patch. The
## material here is a *volume* of 0.25 m cells run by `GranularVoxelField`,
## written into a second, finer `VoxelTerrain` that meshes and collides it.
## Nothing is draped over anything: there is no second surface competing with
## the ground, which is what made the previous approach look like a plate.
##
## Debug stand: raw key events on purpose, no project input actions.

const CELL := 0.25
## 16 x 12 x 16 m of working volume.
const DIMS := Vector3i(64, 48, 64)
## Rock the material lands on, in field cells: a floor, and a ledge on one
## half so a pour cascades off an edge instead of only making a cone.
const FLOOR_CELLS := 3
const LEDGE_HEIGHT_CELLS := 18
const LEDGE_FROM_Z := 38

const POUR_RATE_M3_PER_S := 1.2
const DUMP_M3 := 2.5
const POUR_RADIUS_CELLS := 3
## How far above the aimed surface the stream starts. Enough to read as
## falling, not so much that it scatters on the way down.
const POUR_HEIGHT_M := 1.5
## Height of the column a single deposit may stack into. Kept low so a dump
## lands as a blob that then collapses, rather than as a pillar standing where
## it was written.
const POUR_STACK_CELLS := 10
## Settling runs on wall-clock, like the height-field patch did, so material
## slumps at lunar speed rather than at frame rate. Stepped often with a small
## fraction moved per step rather than rarely with a whole cell: the speed on
## screen is the product of the two, and the fine-grained version is what
## turns visible stepping into flow.
const SETTLE_HZ := 30.0
const CELL_BUDGET_PER_SWEEP := 128
const SCOOP_RADIUS_CELLS := 3
## Edge of the cube written to the terrain in one paste. Matches the plugin's
## own data block size, so a paste lands on one block instead of straddling
## several and dirtying all of them.
const FLUSH_CHUNK := 16

@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _rig: Node3D = $CameraRig
@onready var _overlay: Label = $CanvasLayer/Overlay
@onready var _status: Label = $CanvasLayer/Status

var _field: GranularVoxelField
var _terrain: VoxelTerrain
var _tool: VoxelTool
var _origin := Vector3.ZERO
var _sweep_debt := 0.0
var _pouring := false
var _aim := Vector3.ZERO
var _orbit_yaw := 0.7
var _orbit_pitch := -0.4
var _orbit_distance := 26.0
var _dragging := false
var _last_sweep_ms := 0.0
var _last_flush_ms := 0.0
var _last_flushed := 0
var _last_flush_chunks := 0
var _poured_m3 := 0.0


func _ready() -> void:
	# The field is centred on the origin, so its cell (0,0,0) sits at a corner
	# a whole number of cells away — the fine terrain then shares the grid and
	# a cell maps to a voxel by a plain integer offset.
	_origin = -Vector3(DIMS.x, 0.0, DIMS.z) * CELL * 0.5
	_field = GranularVoxelField.create(DIMS, CELL)
	_build_rock()
	_build_terrain()
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


## `run.sh res://scenes/granular_voxel_playground.tscn -- --shot <png>` pours a
## fixed set of loads onto the ledge, lets them run off it and writes one
## frame. Repeatable eye test: the same pile, the same sun, every run.
func _maybe_start_scripted_shot() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--shot")
	if index < 0 or index + 1 >= args.size():
		return
	_run_scripted_shot(args[index + 1])


func _run_scripted_shot(path: String) -> void:
	# The terrain was created this frame; its blocks are not loaded yet, and a
	# paste into a block that does not exist writes nothing at all. Wait for
	# streaming before touching it.
	for _i in 40:
		await get_tree().process_frame
	var ledge_top := float(LEDGE_HEIGHT_CELLS) * CELL
	# Right on the lip, so the heap has to run off the edge and fall — the
	# behaviour a height field could never show without being told to.
	var on_ledge := _origin.z + float(LEDGE_FROM_Z + 1) * CELL
	for point: Vector3 in [
		Vector3(-1.5, ledge_top + 1.0, on_ledge),
		Vector3(0.0, ledge_top + 1.0, on_ledge),
		Vector3(1.5, ledge_top + 1.0, on_ledge),
	]:
		_pour(point, DUMP_M3)
	# Let it run off the edge and come to rest before the shutter.
	# No per-sweep budget here: the cap exists to protect a live frame, and a
	# scripted shot has no frame to protect. Capped, the shutter caught the
	# load still in mid-air.
	var guard := 0
	while not _field.is_settled() and guard < 8000:
		_field.step()
		guard += 1
	_flush()
	_orbit_yaw = 0.55
	_orbit_pitch = -0.30
	_orbit_distance = 22.0
	_update_camera()
	print(
		"granular voxel shot: %.2f m3 held, settled after %d sweeps, %d chunks pasted"
		% [_field.total_volume_m3(), guard, _last_flush_chunks]
	)
	for _i in 60:
		await get_tree().process_frame
	# Prove the material is really in the terrain, not just in the field: drop
	# a ray onto the heap and report what physics says is there.
	var probe_from := Vector3(0.0, float(DIMS.y) * CELL, on_ledge)
	var probe_to := Vector3(0.0, 0.0, on_ledge)
	var query := PhysicsRayQueryParameters3D.create(probe_from, probe_to)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	print(
		"granular voxel shot: probe %s"
		% ("MISS" if hit.is_empty() else "hit %s" % str(hit["position"]))
	)
	_capture_after_frames(path, 30)


func _capture_after_frames(path: String, frames: int) -> void:
	for _i in frames:
		await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("granular voxel shot failed: %d" % error)
	print("granular voxel shot: %s" % path)
	get_tree().quit(0 if error == OK else 1)


## Rock is marked in the field (so material rests on it) and drawn as plain
## boxes. The fine terrain carries only loose material — mixing the two into
## one field is exactly the confusion this design avoids.
func _build_rock() -> void:
	for z in DIMS.z:
		for x in DIMS.x:
			for y in FLOOR_CELLS:
				_field.set_solid(x, y, z, true)
			if z >= LEDGE_FROM_Z:
				for y in range(FLOOR_CELLS, LEDGE_HEIGHT_CELLS):
					_field.set_solid(x, y, z, true)
	_add_rock_box(
		Vector3(0.0, float(FLOOR_CELLS) * CELL * 0.5, 0.0),
		Vector3(float(DIMS.x) * CELL, float(FLOOR_CELLS) * CELL, float(DIMS.z) * CELL)
	)
	var ledge_depth := float(DIMS.z - LEDGE_FROM_Z) * CELL
	var ledge_height := float(LEDGE_HEIGHT_CELLS - FLOOR_CELLS) * CELL
	_add_rock_box(
		Vector3(
			0.0,
			float(FLOOR_CELLS) * CELL + ledge_height * 0.5,
			_origin.z + float(LEDGE_FROM_Z) * CELL + ledge_depth * 0.5
		),
		Vector3(float(DIMS.x) * CELL, ledge_height, ledge_depth)
	)


func _add_rock_box(centre: Vector3, dimensions: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = centre
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


func _build_terrain() -> void:
	_terrain = VoxelTerrain.new()
	_terrain.scale = Vector3.ONE * CELL
	_terrain.mesher = VoxelMesherTransvoxel.new()
	# Everything starts as air: this field holds only what we write into it.
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = -100000.0
	_terrain.generator = generator
	_terrain.generate_collisions = true
	var margin := 8
	_terrain.set_bounds(
		AABB(
			Vector3(-margin, -margin, -margin),
			Vector3(DIMS.x + margin * 2, DIMS.y + margin * 2, DIMS.z + margin * 2)
		)
	)
	_terrain.position = _origin
	_terrain.material_override = _spoil_material()
	add_child(_terrain)
	var viewer := VoxelViewer.new()
	viewer.view_distance = maxi(DIMS.x, DIMS.z) + margin * 2
	_terrain.add_child(viewer)
	_tool = _terrain.get_voxel_tool()
	_tool.channel = VoxelBuffer.CHANNEL_SDF


## Regolith on a marching-cubes surface. Triplanar is not a preference here:
## the mesher emits no UVs at all, so a plain textured material would come out
## as flat colour — which is exactly what made the first pass read as
## modelling clay rather than as dirt.
func _spoil_material() -> Material:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.80, 0.75, 0.67)
	material.albedo_texture = load(
		"res://resources/moon_regolith_albedo.jpg"
	) as Texture2D
	material.normal_enabled = true
	material.normal_texture = load(
		"res://resources/moon_regolith_normal.jpg"
	) as Texture2D
	material.normal_scale = 1.6
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.uv1_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.45
	material.uv1_triplanar_sharpness = 2.0
	return material


func _process(delta: float) -> void:
	if _pouring:
		_pour(_aim, POUR_RATE_M3_PER_S * delta)
	_sweep_debt += delta * SETTLE_HZ
	var sweeps := mini(int(_sweep_debt), 3)
	if sweeps > 0:
		_sweep_debt -= float(sweeps)
		var started := Time.get_ticks_usec()
		for _i in sweeps:
			_field.step(CELL_BUDGET_PER_SWEEP)
		_last_sweep_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_flush()
	_update_status()


## Push the cells that changed into the fine terrain. Mass maps straight onto
## the SDF the mesher reads: `sdf = 0.5 - mass` is the exact inverse of the
## occupancy the excavation service already measures dug volume with, so the
## two representations agree on what "full" means.
##
## Written a chunk at a time, never voxel by voxel. Each `set_voxel_f` on a
## terrain has to find the block and flag it for remeshing, so poking cells
## individually cost about a millisecond each — a single settling step took ten
## seconds and nothing ever appeared. Pasting a whole buffer pays that once per
## chunk instead of once per cell.
func _flush() -> void:
	var dirty := _field.take_dirty()
	if dirty.is_empty():
		_last_flushed = 0
		return
	var started := Time.get_ticks_usec()
	var plane := DIMS.x * DIMS.z
	var chunks := {}
	for i: int in dirty:
		var x := i % DIMS.x
		var z := (i / DIMS.x) % DIMS.z
		var y := i / plane
		chunks[
			Vector3i(x / FLUSH_CHUNK, y / FLUSH_CHUNK, z / FLUSH_CHUNK)
		] = true
	for chunk: Vector3i in chunks:
		_flush_chunk(chunk)
	_last_flush_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_last_flushed = dirty.size()
	_last_flush_chunks = chunks.size()


func _flush_chunk(chunk: Vector3i) -> void:
	var base := chunk * FLUSH_CHUNK
	var buffer := VoxelBuffer.new()
	buffer.create(FLUSH_CHUNK, FLUSH_CHUNK, FLUSH_CHUNK)
	# Air by default, so cells the field has emptied are cleared rather than
	# left holding whatever was written last time.
	buffer.fill_f(0.5, VoxelBuffer.CHANNEL_SDF)
	for z in FLUSH_CHUNK:
		for y in FLUSH_CHUNK:
			for x in FLUSH_CHUNK:
				var mass := _field.mass_at(base.x + x, base.y + y, base.z + z)
				if mass <= 0.0:
					continue
				buffer.set_voxel_f(
					0.5 - mass, x, y, z, VoxelBuffer.CHANNEL_SDF
				)
	_tool.paste(base, buffer, 1 << VoxelBuffer.CHANNEL_SDF)


func _pour(world_point: Vector3, volume_m3: float) -> void:
	if volume_m3 <= 0.0:
		return
	var centre := _cell_of(world_point)
	# Spread the pour over a small disc and start it above the surface, so it
	# falls in rather than appearing inside whatever is already there.
	var placed := 0.0
	var remaining := volume_m3
	for dy in range(0, POUR_STACK_CELLS):
		for dz in range(-POUR_RADIUS_CELLS, POUR_RADIUS_CELLS + 1):
			for dx in range(-POUR_RADIUS_CELLS, POUR_RADIUS_CELLS + 1):
				if remaining <= 0.0:
					break
				if dx * dx + dz * dz > POUR_RADIUS_CELLS * POUR_RADIUS_CELLS:
					continue
				var accepted := _field.deposit(
					centre.x + dx, centre.y + dy, centre.z + dz, remaining
				)
				placed += accepted
				remaining -= accepted
	_poured_m3 += placed


func _scoop() -> void:
	var centre := _cell_of(_aim)
	for dy in range(-SCOOP_RADIUS_CELLS, SCOOP_RADIUS_CELLS + 1):
		for dz in range(-SCOOP_RADIUS_CELLS, SCOOP_RADIUS_CELLS + 1):
			for dx in range(-SCOOP_RADIUS_CELLS, SCOOP_RADIUS_CELLS + 1):
				if dx * dx + dy * dy + dz * dz > SCOOP_RADIUS_CELLS * SCOOP_RADIUS_CELLS:
					continue
				_field.take(centre.x + dx, centre.y + dy, centre.z + dz)


func _cell_of(world_point: Vector3) -> Vector3i:
	var local := world_point - _origin
	return Vector3i(
		clampi(int(round(local.x / CELL)), 0, DIMS.x - 1),
		clampi(int(round(local.y / CELL)), 0, DIMS.y - 1),
		clampi(int(round(local.z / CELL)), 0, DIMS.z - 1)
	)


func _reset() -> void:
	var dirty := PackedInt32Array()
	for z in DIMS.z:
		for y in DIMS.y:
			for x in DIMS.x:
				if _field.mass_at(x, y, z) > 0.0:
					_field.take(x, y, z)
					dirty.append(_field.index(x, y, z))
	_poured_m3 = 0.0
	_flush()


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
			_pour(_aim, DUMP_M3)
		KEY_Q:
			_scoop()
		KEY_R:
			_reset()


## Aim at whatever surface you are looking at — rock or an existing heap — and
## pour from just above it. A fixed horizontal plane meant the stream always
## started at one height regardless of what was underneath, so pouring onto the
## low floor dropped material from several metres up while pouring onto the
## ledge barely cleared it.
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
		"%.2f m3 poured / %.2f m3 held   active %d   sweep %.2f ms   flush %d cells / %d chunks %.2f ms   %s"
		% [
			_poured_m3,
			_field.total_volume_m3(),
			_field.active_count(),
			_last_sweep_ms,
			_last_flushed,
			_last_flush_chunks,
			_last_flush_ms,
			"settled" if _field.is_settled() else "flowing",
		]
	)
