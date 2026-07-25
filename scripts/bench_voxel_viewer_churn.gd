extends Node3D

## Headless bench for COOP-PERF-PLAYBOOK H1/H2: cost of a VoxelViewer moving at
## rover speed across a VoxelLodTerrain (Clipbox), isolated from coop
## networking / GDScript physics-projection cost (PERF-H03 already measured
## separately in docs/_verify/PERF-REST-PASS2.md §7).
##
## Mirrors bootstrap.gd's real terrain config (Clipbox, mesh_block_size=16,
## lod_distance=secondary_lod_distance=48, collision_lod_count=3,
## collision_update_delay) on a small sphere (fast to generate) instead of
## the Ø19 km planetoid, and drives ONE VoxelViewer back and forth exactly
## like player_controller.gd does every frame while riding a vehicle
## (`_voxel_viewer.global_position = global_position`).
##
## Run: godot --headless --path Y:\regolith res://scenes/bench_voxel_viewer_churn.tscn
## Scenario matrix is fixed (see _run_all_scenarios); no CLI args needed.

const RADIUS_M := 2500.0
const LOD_COUNT := 8
const MESH_BLOCK_SIZE := 16
const LOD_DISTANCE := 48.0
const SECONDARY_LOD_DISTANCE_WIDE := 48.0
const SECONDARY_LOD_DISTANCE_NARROW := 16.0
const COLLISION_LOD_COUNT := 3
const COLLISION_UPDATE_DELAY_MS := 100
const VIEW_DISTANCE_VOXELS := 512

const WARMUP_S := 8.0
const PHASE_S := 6.0
const ROVER_SPEED_MPS := 10.0
const ROVER_SPEED_FAST_MPS := 20.0
const TRACK_HALF_LENGTH_M := 60.0

@onready var _terrain: VoxelLodTerrain = $VoxelLodTerrain
@onready var _viewer: VoxelViewer = $VoxelLodTerrain/VoxelViewer

var _spawn_pos: Vector3
var _results: Array[String] = []


func _ready() -> void:
	_configure_terrain()
	_spawn_pos = Vector3(0.0, 0.0, -RADIUS_M - 4.0)
	_viewer.global_position = _spawn_pos
	_viewer.view_distance = VIEW_DISTANCE_VOXELS
	_viewer.requires_visuals = true
	_viewer.requires_collisions = true
	await get_tree().process_frame
	await _run_all_scenarios()
	for line: String in _results:
		print(line)
	get_tree().quit()


func _configure_terrain() -> void:
	_terrain.generator = _make_sphere_generator()
	_terrain.streaming_system = VoxelLodTerrain.STREAMING_SYSTEM_CLIPBOX
	_terrain.mesh_block_size = MESH_BLOCK_SIZE
	_terrain.lod_count = LOD_COUNT
	var half := RADIUS_M * 1.3
	_terrain.voxel_bounds = AABB(
		Vector3(-half, -half, -half), Vector3(half, half, half) * 2.0
	)
	_terrain.generate_collisions = true
	_terrain.collision_lod_count = COLLISION_LOD_COUNT
	_terrain.lod_distance = LOD_DISTANCE
	_terrain.secondary_lod_distance = SECONDARY_LOD_DISTANCE_WIDE
	_terrain.collision_update_delay = COLLISION_UPDATE_DELAY_MS
	_terrain.threaded_update_enabled = true
	_terrain.cache_generated_blocks = false


func _make_sphere_generator() -> VoxelGenerator:
	var generator := VoxelGeneratorGraph.new()
	var graph: VoxelGraphFunction = generator.get_main_function()
	graph.clear()
	var in_x := graph.create_node(VoxelGraphFunction.NODE_INPUT_X, Vector2(0, 0))
	var in_y := graph.create_node(VoxelGraphFunction.NODE_INPUT_Y, Vector2(0, 40))
	var in_z := graph.create_node(VoxelGraphFunction.NODE_INPUT_Z, Vector2(0, 80))
	var radius_c := graph.create_node(VoxelGraphFunction.NODE_CONSTANT, Vector2(0, 140))
	graph.set_node_param(radius_c, 0, RADIUS_M)
	var sphere := graph.create_node(VoxelGraphFunction.NODE_SDF_SPHERE, Vector2(220, 40))
	graph.add_connection(in_x, 0, sphere, 0)
	graph.add_connection(in_y, 0, sphere, 1)
	graph.add_connection(in_z, 0, sphere, 2)
	graph.add_connection(radius_c, 0, sphere, 3)
	var out_sdf := graph.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2(440, 40))
	graph.add_connection(sphere, 0, out_sdf, 0)
	var compile_result: Dictionary = generator.compile()
	if not bool(compile_result.get("success", false)):
		push_error("bench_voxel_viewer_churn: sphere graph compile failed: %s" % str(compile_result))
	generator.use_subdivision = true
	generator.subdivision_size = 8
	generator.use_optimized_execution_map = true
	return generator


func _run_all_scenarios() -> void:
	print("BENCH_START radius=%.0f lod_count=%d mesh_block_size=%d lod_distance=%.0f collision_lod_count=%d speed=%.1f/%.1f" % [
		RADIUS_M, LOD_COUNT, MESH_BLOCK_SIZE, LOD_DISTANCE, COLLISION_LOD_COUNT,
		ROVER_SPEED_MPS, ROVER_SPEED_FAST_MPS,
	])

	# A. Parked baseline.
	_viewer.requires_collisions = true
	_terrain.secondary_lod_distance = SECONDARY_LOD_DISTANCE_WIDE
	await _wait_stable()
	await _run_phase("A_parked", 0.0, true)

	# B. Driving at 10 m/s, full config (matches production: collisions on,
	# secondary_lod_distance == lod_distance == 48).
	await _run_phase("B_driving_10ms_coll_on_sec48", ROVER_SPEED_MPS, true)

	# C. Driving at 10 m/s, requires_collisions=false (isolate mesh-only churn
	# from H1's collider-build cost).
	_viewer.requires_collisions = false
	await _run_phase("C_driving_10ms_coll_off_sec48", ROVER_SPEED_MPS, true)
	_viewer.requires_collisions = true

	# D. Driving at 10 m/s, secondary_lod_distance narrowed to 16 (O3 from the
	# playbook: LOD0 reach unchanged, LOD>0 shell shrunk).
	_terrain.secondary_lod_distance = SECONDARY_LOD_DISTANCE_NARROW
	await _wait_stable()
	await _run_phase("D_driving_10ms_coll_on_sec16", ROVER_SPEED_MPS, true)
	_terrain.secondary_lod_distance = SECONDARY_LOD_DISTANCE_WIDE

	# E. Driving at 20 m/s (stress), full config, to see scaling.
	await _wait_stable()
	await _run_phase("E_driving_20ms_coll_on_sec48", ROVER_SPEED_FAST_MPS, true)


## Let remaining_main_thread_blocks settle back near 0 and the viewer return
## to the parked spawn before starting the next timed phase, so phases don't
## bleed backlog into each other.
func _wait_stable() -> void:
	_viewer.global_position = _spawn_pos
	var deadline_ms := Time.get_ticks_msec() + int(WARMUP_S * 1000.0)
	while Time.get_ticks_msec() < deadline_ms:
		var stats := _terrain.get_statistics()
		if int(stats.get("remaining_main_thread_blocks", 0)) <= 0:
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _run_phase(label: String, speed_mps: float, move: bool) -> void:
	var fps: Array[float] = []
	var process_ms: Array[float] = []
	var physics_ms: Array[float] = []
	var remaining_blocks: Array[int] = []
	var updated_blocks: Array[int] = []
	var mesh_us: Array[int] = []

	var start_ms := Time.get_ticks_msec()
	var end_ms := start_ms + int(PHASE_S * 1000.0)
	var t0 := start_ms / 1000.0
	while Time.get_ticks_msec() < end_ms:
		if move:
			var t := Time.get_ticks_msec() / 1000.0 - t0
			var offset := sin(t * speed_mps / TRACK_HALF_LENGTH_M) * TRACK_HALF_LENGTH_M
			_viewer.global_position = _spawn_pos + Vector3(offset, 0.0, 0.0)
		var stats := _terrain.get_statistics()
		fps.append(Performance.get_monitor(Performance.TIME_FPS))
		process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		remaining_blocks.append(int(stats.get("remaining_main_thread_blocks", 0)))
		updated_blocks.append(int(stats.get("updated_blocks", 0)))
		mesh_us.append(
			int(stats.get("time_request_blocks_to_update", 0))
			+ int(stats.get("time_process_update_responses", 0))
		)
		await get_tree().process_frame

	var final_stats := _terrain.get_statistics()
	_results.append(
		(
			"BENCH_RESULT %s fps_avg=%.1f fps_min=%.1f process_ms_avg=%.3f "
			+ "physics_ms_avg=%.3f remaining_blk_avg=%.2f remaining_blk_max=%d "
			+ "updated_blk_avg=%.2f mesh_us_avg=%.1f final_stats=%s"
		) % [
			label,
			_avg(fps), _min(fps),
			_avg(process_ms),
			_avg(physics_ms),
			_avgi(remaining_blocks), _maxi(remaining_blocks),
			_avgi(updated_blocks),
			_avgi(mesh_us),
			JSON.stringify(final_stats),
		]
	)


func _avg(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


func _min(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var m: float = values[0]
	for v in values:
		m = minf(m, v)
	return m


func _avgi(values: Array[int]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0
	for v in values:
		total += v
	return float(total) / float(values.size())


func _maxi(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var m: int = values[0]
	for v in values:
		m = maxi(m, v)
	return m
