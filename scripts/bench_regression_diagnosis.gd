extends Node3D
## PERF-COOP-REGRESS diagnosis bench (real terrain, real planetoid).
##
## Boots the real game scene (main.tscn / bootstrap.gd) like
## bench_terrain_regression_oracle.gd does, but measures with
## SimulationPhysicsProjection.get_last_tick_breakdown_us() instead of
## Performance.TIME_PHYSICS_PROCESS.
##
## Why not reuse Performance.TIME_PHYSICS_PROCESS (as the oracle bench does):
## confirmed in engine source (main/main.cpp Main::iteration) that monitor is
## set ONCE PER REAL-WORLD SECOND to that second's WORST single physics tick
## and holds the value for the rest of the second — averaging repeated reads
## of it just averages copies of the last spike, not a real per-tick cost.
## get_last_tick_breakdown_us() times our own GDScript with
## Time.get_ticks_usec() directly, and derives the native (Jolt step + nav +
## sync/flush_queries) cost from the wall-clock gap between the end of our
## script this tick and the start of our script next tick — see the doc
## comment on SimulationPhysicsProjection._prev_tick_end_us for the exact
## physics-loop ordering this relies on (main.cpp).
##
## Adds a G) actually-driving phase on top of the oracle's parked/unparked:
## the acceptance bar is the MOVING rover, not just the awake-but-idle one.
##
## Usage: godot --headless res://scenes/bench_regression_diagnosis.tscn
## Prints BENCH_DIAG lines and exits 0.

const MainScene := preload("res://scenes/main.tscn")
const SETTLE_TICKS := 90
const SAMPLE_TICKS := 180
const READY_TIMEOUT_MS := 120000

var _bootstrap: Node3D
var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _session: Node
var _assembly_id := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_bootstrap = MainScene.instantiate()
	add_child(_bootstrap)

	var deadline := Time.get_ticks_msec() + READY_TIMEOUT_MS
	while not bool(_bootstrap.call("is_world_ready")):
		await get_tree().process_frame
		if Time.get_ticks_msec() > deadline:
			print("BENCH_DIAG: FAIL world never became ready")
			get_tree().quit(2)
			return

	_session = _bootstrap.get_node("SimulationSession")
	_world = _session.world
	_projection = _session.projection

	if not _find_demo_rover():
		print("BENCH_DIAG: FAIL no demo rover assembly found")
		get_tree().quit(2)
		return
	print("BENCH_DIAG_START assembly_id=%d" % _assembly_id)
	_report_node_counts()

	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame

	var locomotion := _world.get_locomotion_controller(_assembly_id)

	locomotion.set_parking_brake(true)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	await _sample("A_parked")

	locomotion.activate()
	locomotion.set_parking_brake(false)
	_projection.wake_assembly_bodies(_assembly_id)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	await _sample("B_unparked_idle")

	locomotion.set_drive_command(1.0)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	await _sample("C_driving")

	# A/B test: SceneTree.set_physics_interpolation_enabled() lets us flip
	# Godot's native per-frame Transform interpolation (project setting
	# physics/common/physics_interpolation=true) at runtime without an
	# engine rebuild. That interpolation runs OUTSIDE _physics_process,
	# during the render portion of Main::iteration, over every interpolated
	# Node3D descendant of a moving body — invisible to both
	# Performance.TIME_PHYSICS_PROCESS and our script/native_gap split above,
	# so if THIS is the regression, it would explain why parked/unparked/
	# driving all measured near-identical physics-tick cost above while FPS
	# still cratered.
	get_tree().set_physics_interpolation_enabled(false)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	await _sample("D_driving_interp_off")

	locomotion.set_drive_command(0.0)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	await _sample("E_unparked_idle_interp_off")
	get_tree().set_physics_interpolation_enabled(true)

	locomotion.set_parking_brake(true)
	for _i: int in range(SETTLE_TICKS):
		await get_tree().physics_frame
	await _sample("F_reparked")

	print("BENCH_DIAG_DONE")
	get_tree().quit(0)


## Quantifies the physics_interpolation A/B result: count how many Node3D
## descendants sit under the rover's own physics bodies (chassis + wheels) —
## by default every one of them inherits physics_interpolation=ON from the
## project setting and gets individually registered for per-frame transform
## interpolation while its body is awake, even though most are rigidly fixed
## to their parent and contribute nothing but registration overhead.
func _report_node_counts() -> void:
	var roots: Array[Node] = []
	var root := _projection.get_physics_body(_assembly_id)
	if root != null:
		roots.append(root)
	for record: Dictionary in _projection.list_wheel_constraint_records(_assembly_id):
		var wheel_body: Node = record.get("wheel_body")
		var strut_body: Node = record.get("strut_body")
		if wheel_body != null and not roots.has(wheel_body):
			roots.append(wheel_body)
		if strut_body != null and not roots.has(strut_body):
			roots.append(strut_body)
	var total := 0
	var interp_on := 0
	var stack: Array[Node] = roots.duplicate()
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for child in n.get_children():
			stack.append(child)
		if n is Node3D:
			total += 1
			var mode: int = (n as Node3D).physics_interpolation_mode
			if mode != Node3D.PHYSICS_INTERPOLATION_MODE_OFF:
				interp_on += 1
	print(
		"BENCH_DIAG_NODES assembly_id=%d bodies=%d node3d_total=%d not_explicitly_off=%d"
		% [_assembly_id, roots.size(), total, interp_on]
	)


func _find_demo_rover() -> bool:
	for assembly: SimulationAssembly in _world.list_assemblies():
		if assembly.tombstoned:
			continue
		var locomotion := _world.get_locomotion_controller(assembly.assembly_id)
		if locomotion != null:
			_assembly_id = assembly.assembly_id
			return true
	return false


func _sample(label: String) -> void:
	var root := _projection.get_physics_body(_assembly_id) as RigidBody3D
	var script_us_sum := 0
	var native_gap_us_sum := 0
	var native_gap_us_max := 0
	var wheel_us_sum := 0
	var motion_sync_us_sum := 0
	var industry_us_sum := 0
	var n := 0
	var last_seq := -1
	for _i: int in range(SAMPLE_TICKS):
		await get_tree().physics_frame
		var proj_us: Dictionary = _projection.get_last_tick_breakdown_us()
		var sess_us: Dictionary = _session.get_last_tick_breakdown_us()
		var seq: int = int(proj_us.get("tick_seq", -1))
		if seq == last_seq:
			continue
		last_seq = seq
		script_us_sum += int(proj_us.get("total", 0)) + int(sess_us.get("total", 0))
		wheel_us_sum += int(proj_us.get("wheel_bodies_per_wheel", 0))
		motion_sync_us_sum += int(proj_us.get("motion_sync", 0))
		industry_us_sum += int(sess_us.get("industry_tick", 0))
		var gap: int = int(proj_us.get("native_gap_since_prev_tick", -1))
		if gap >= 0:
			native_gap_us_sum += gap
			native_gap_us_max = maxi(native_gap_us_max, gap)
		n += 1
	var script_ms := (float(script_us_sum) / maxi(n, 1)) / 1000.0
	var native_gap_ms := (float(native_gap_us_sum) / maxi(n, 1)) / 1000.0
	print(
		(
			"BENCH_DIAG %s n_ticks=%d fps_now=%.0f script_ms=%.3f "
			+ "native_gap_ms=%.3f native_gap_max_ms=%.3f tick_total≈%.3f "
			+ "[wheel_ms=%.3f motion_sync_ms=%.3f industry_ms=%.3f] frozen=%s"
		) % [
			label,
			n,
			Performance.get_monitor(Performance.TIME_FPS),
			script_ms,
			native_gap_ms,
			float(native_gap_us_max) / 1000.0,
			script_ms + native_gap_ms,
			float(wheel_us_sum) / maxi(n, 1) / 1000.0,
			float(motion_sync_us_sum) / maxi(n, 1) / 1000.0,
			float(industry_us_sum) / maxi(n, 1) / 1000.0,
			str(root.freeze if root != null else "?"),
		]
	)
