extends Node3D

const WORLD_SPAWN_XZ := Vector2(0.0, 16.0)
## Generator surface lies between y=-8 and y=56; y=70 with a -45° pitch keeps
## the whole loaded patch in frame instead of hugging the horizon.
const CAMERA_Y := 70.0
const CAMERA_PITCH_DEG := -45.0
const BASE_VIEW_DISTANCE := 128
const DRILL_WORLD_RADIUS_M := 0.65
const DRILL_INTERVAL_S := 0.08
const DRILL_DURATION_S := 10.0
const DEFAULT_GEN_WAIT_S := 30.0
const STABLE_FRAMES_REQUIRED := 20

@onready var _terrain: VoxelTerrain = $VoxelTerrain
@onready var _camera: Camera3D = $Camera3D
@onready var _viewer: VoxelViewer = $Camera3D/VoxelViewer

var _terrain_scale := 1.0
var _enable_drill_phase := true
## Beckett's play_scene passes no user args: hold the loaded terrain on screen
## for visual inspection instead of running the timed bench and quitting.
var _hold_mode := false
var _gen_wait_limit_s := DEFAULT_GEN_WAIT_S
var _bench_start_ms := 0
var _initial_gen_timed_out := false


func _ready() -> void:
	_parse_cli()
	_bench_start_ms = Time.get_ticks_msec()
	_terrain.scale = Vector3.ONE * _terrain_scale
	_viewer.view_distance = maxi(16, int(round(BASE_VIEW_DISTANCE / _terrain_scale)))
	# VoxelTerrain clamps viewers to its own max_view_distance (default 128
	# voxels); without raising it, far blocks at small scales never load.
	_terrain.max_view_distance = _viewer.view_distance
	_camera.global_position = Vector3(WORLD_SPAWN_XZ.x, CAMERA_Y, WORLD_SPAWN_XZ.y)
	_camera.rotation = Vector3(deg_to_rad(CAMERA_PITCH_DEG), 0.0, 0.0)
	_camera.current = true
	await get_tree().process_frame
	if _hold_mode:
		await _run_hold_mode()
	else:
		await _run_benchmark()


func _parse_cli() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		_hold_mode = true
		return
	for arg: String in args:
		if arg.begins_with("--bench-scale="):
			_terrain_scale = float(arg.get_slice("=", 1))
		elif arg == "--bench-drill=false":
			_enable_drill_phase = false
		elif arg.begins_with("--bench-gen-limit="):
			_gen_wait_limit_s = float(arg.get_slice("=", 1))
		elif arg.begins_with("--bench-hold"):
			_hold_mode = true


func _run_hold_mode() -> void:
	print("BENCH_HOLD waiting for terrain around camera...")
	var meshed := await _wait_for_view_area()
	print("BENCH_HOLD terrain_meshed=%s camera=%s scale=%.3f view_distance=%d" % [
		str(meshed),
		str(_camera.global_position),
		_terrain_scale,
		_viewer.view_distance,
	])
	while true:
		await get_tree().create_timer(5.0).timeout
		print("BENCH_HOLD alive meshed=%s" % str(_is_view_area_ready()))


func _timed_out() -> bool:
	# Overall cap: generation budget plus drill phase with margin.
	var cap_ms := int((_gen_wait_limit_s + 30.0) * 1000.0)
	return Time.get_ticks_msec() - _bench_start_ms >= cap_ms


func _run_benchmark() -> void:
	var tool: VoxelTool = _terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF

	var gen_start_ms := Time.get_ticks_msec()
	var meshed := await _wait_for_view_area()
	var gen_time_s := (Time.get_ticks_msec() - gen_start_ms) / 1000.0
	if not meshed:
		_initial_gen_timed_out = true

	await _save_proof_screenshot("initial")

	var drill_result := {}
	if _enable_drill_phase and meshed and not _timed_out():
		drill_result = await _run_drill_sampling(tool)
		await _save_proof_screenshot("after_drill")

	var stats := _terrain.get_statistics()
	var memory_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
	_print_bench_result(gen_time_s, drill_result, stats, memory_mb)
	get_tree().quit()


## Waits (max _gen_wait_limit_s) until the surface patch the camera looks at
## is meshed and the mesh updates settle. Returns false on timeout. Logs
## progress every 5 s so a stalled load is distinguishable from a slow one.
func _wait_for_view_area() -> bool:
	var wait_start_ms := Time.get_ticks_msec()
	var stable_frames := 0
	var next_progress_ms := wait_start_ms + 5000
	while Time.get_ticks_msec() - wait_start_ms < int(_gen_wait_limit_s * 1000.0):
		if _is_view_area_ready():
			stable_frames += 1
			if stable_frames >= STABLE_FRAMES_REQUIRED:
				return true
		else:
			stable_frames = 0
		var now_ms := Time.get_ticks_msec()
		if now_ms >= next_progress_ms:
			next_progress_ms = now_ms + 5000
			print("BENCH_PROGRESS t=%.1fs meshed=%s" % [
				(now_ms - wait_start_ms) / 1000.0,
				str(_is_view_area_ready()),
			])
		await get_tree().process_frame
	return _is_view_area_ready()


func _is_view_area_ready() -> bool:
	return _terrain.is_area_meshed(_view_area_voxels())


## Checked area is a slab over the surface patch the camera looks at: 32 m
## horizontal radius around the aim point, vertically only the generator's
## surface band (world y -12..60). A full cube would push its corners past
## the viewer's load sphere at small scales and never finish meshing.
func _view_area_voxels() -> AABB:
	var world_min := Vector3(
		WORLD_SPAWN_XZ.x - 32.0,
		-12.0,
		WORLD_SPAWN_XZ.y - 56.0
	)
	var world_max := Vector3(
		WORLD_SPAWN_XZ.x + 32.0,
		60.0,
		WORLD_SPAWN_XZ.y + 8.0
	)
	var inverse := _terrain.global_transform.affine_inverse()
	var local_min := inverse * world_min
	var local_max := inverse * world_max
	return AABB(local_min, local_max - local_min)


func _save_proof_screenshot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "/tmp/bench_scale_%.2f_%s.png" % [_terrain_scale, tag]
	var err := image.save_png(path)
	print("BENCH_SCREENSHOT %s err=%d" % [path, err])


func _run_drill_sampling(tool: VoxelTool) -> Dictionary:
	tool.mode = VoxelTool.MODE_REMOVE
	tool.sdf_strength = 1.0

	var fps_samples: Array[float] = []
	var process_samples: Array[float] = []
	var physics_samples: Array[float] = []
	var mesh_time_samples: Array[float] = []
	var updated_blocks_samples: Array[int] = []

	var drill_start_ms := Time.get_ticks_msec()
	var next_drill_ms := drill_start_ms
	var drill_end_ms := drill_start_ms + int(DRILL_DURATION_S * 1000.0)
	# TIME_FPS averages over the last second, so samples taken right after the
	# quick startup read artificially low; skip the first second of sampling.
	var sample_from_ms := drill_start_ms + 1000

	while Time.get_ticks_msec() < drill_end_ms and not _timed_out():
		var now_ms := Time.get_ticks_msec()
		if now_ms >= next_drill_ms:
			_apply_drill_sphere(tool)
			next_drill_ms = now_ms + int(DRILL_INTERVAL_S * 1000.0)

		if now_ms < sample_from_ms:
			await get_tree().process_frame
			continue

		fps_samples.append(Performance.get_monitor(Performance.TIME_FPS))
		process_samples.append(
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		)
		physics_samples.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)

		var stats := _terrain.get_statistics()
		var updated_blocks := int(stats.get("updated_blocks", 0))
		updated_blocks_samples.append(updated_blocks)
		var mesh_us := (
			int(stats.get("time_request_blocks_to_update", 0))
			+ int(stats.get("time_process_update_responses", 0))
		)
		if mesh_us > 0:
			if updated_blocks > 0:
				mesh_time_samples.append(float(mesh_us) / float(updated_blocks))
			else:
				mesh_time_samples.append(float(mesh_us))

		await get_tree().process_frame

	return {
		"fps_avg": _average(fps_samples),
		"fps_min": _minimum(fps_samples),
		"process_ms_avg": _average(process_samples),
		"physics_ms_avg": _average(physics_samples),
		"mesh_us_per_block_avg": _average(mesh_time_samples),
		"updated_blocks_avg": _average(updated_blocks_samples.map(func(v: int) -> float: return float(v))),
	}


## Raycasts from the camera to the terrain surface and carves there, matching
## how the hand drill digs at the aim point (VoxelTool.raycast: world space).
func _apply_drill_sphere(tool: VoxelTool) -> void:
	var forward := -_camera.global_transform.basis.z.normalized()
	var world_origin := _camera.global_position
	var hit: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		_terrain,
		world_origin,
		forward,
		220.0
	)
	if hit == null:
		return
	var local_center := VoxelSpaceUtil.world_to_local(
		_terrain,
		VoxelSpaceUtil.raycast_hit_world_point(
			_terrain,
			world_origin,
			forward,
			hit
		)
	)
	var local_radius := DRILL_WORLD_RADIUS_M / _terrain_scale
	tool.do_sphere(local_center, local_radius)


func _average(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value: float in values:
		total += value
	return total / float(values.size())


func _minimum(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var min_value: float = values[0]
	for value: float in values:
		min_value = minf(min_value, value)
	return min_value


func _print_bench_result(
	gen_time_s: float,
	drill_result: Dictionary,
	stats: Dictionary,
	memory_mb: float
) -> void:
	var lines: PackedStringArray = []
	lines.append("BENCH_RESULT scale=%.4f view_distance=%d drill=%s" % [
		_terrain_scale,
		_viewer.view_distance,
		str(_enable_drill_phase),
	])
	lines.append("BENCH_RESULT initial_generation_s=%.3f timed_out=%s" % [
		gen_time_s,
		str(_initial_gen_timed_out),
	])
	if not drill_result.is_empty():
		lines.append(
			"BENCH_RESULT drill_fps_avg=%.2f drill_fps_min=%.2f"
			% [drill_result.get("fps_avg", 0.0), drill_result.get("fps_min", 0.0)]
		)
		lines.append(
			"BENCH_RESULT drill_process_ms_avg=%.3f drill_physics_ms_avg=%.3f"
			% [
				drill_result.get("process_ms_avg", 0.0),
				drill_result.get("physics_ms_avg", 0.0),
			]
		)
		lines.append(
			"BENCH_RESULT drill_mesh_us_per_block_avg=%.2f updated_blocks_avg=%.2f"
			% [
				drill_result.get("mesh_us_per_block_avg", 0.0),
				drill_result.get("updated_blocks_avg", 0.0),
			]
		)
	lines.append(
		"BENCH_RESULT final_stats=%s"
		% JSON.stringify(stats)
	)
	lines.append("BENCH_RESULT memory_static_mb=%.2f" % memory_mb)
	print("\n".join(lines))
