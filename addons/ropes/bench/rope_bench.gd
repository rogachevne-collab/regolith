class_name RopeBench
extends Node3D
## Measuring stick for rope solvers. Implementation-agnostic on purpose: it
## knows scenarios and numbers, never a particular solver, and talks to one
## through a small adapter. The point is that the table it prints is comparable
## row-for-row between today's solver and whatever replaces it — "the new one
## is better" has to be a number, not an impression.
##
## Written because the opposite happened: a full suite of green tests sat
## alongside a rope reporting a metre and a half of stretch that did not exist,
## because nothing measured the quantities that actually matter. These are
## those quantities.
##
## An adapter is any object with:
##   create(a: Vector3, b: Vector3, rest_m: float, space: PhysicsDirectSpaceState3D) -> Variant
##   step(handle, a: Vector3, b: Vector3, rest_m: float, gravity: Vector3, delta: float) -> void
##   points(handle) -> PackedVector3Array     — the rope as it is drawn
##   reported_length(handle) -> float         — length the solver claims, the
##                                              number a tension model would act on
##   is_asleep(handle) -> bool
##
## Every scenario is driven at a fixed 1/60 s, one physics frame per step, so
## shape queries see a settled world.

const STEP_S := 1.0 / 60.0
const GRAVITY := Vector3(0.0, -1.62, 0.0)
## Lunar gravity, so settling is genuinely slow — anything that looks settled
## here is settled anywhere.

## What a rope has to manage to be worth shipping. Not what ours does today.
const TARGET_PHANTOM_FRACTION := 0.005
const TARGET_SETTLE_S := 5.0
const TARGET_STEADY_MOTION_M := 0.002
const TARGET_PENETRATION_M := 0.02
const TARGET_STEP_MS := 0.5

## Motion below which a rope counts as having stopped moving, per tick.
const SETTLED_MOTION_M := 0.002
## How long a scenario is allowed to run before its settle time is reported as
## "never".
const MAX_SETTLE_TICKS := 1800
## Steady-state window measured after settling has been given its chance.
const STEADY_TICKS := 180


var _adapter: Object
var _results: Array[Dictionary] = []


func run_all(adapter: Object) -> Array[Dictionary]:
	_adapter = adapter
	_results = []
	await _bench_hang()
	await _bench_ground()
	await _bench_drape_over_block()
	await _bench_chord_through_block()
	await _bench_thin_beam()
	await _bench_throughput()
	_print_table()
	return _results


## A rope hanging in clear air between two fixed points. The easiest thing a
## rope solver can be asked to do: if the numbers are not clean here, nothing
## downstream can be.
func _bench_hang() -> void:
	var world := _new_world()
	await get_tree().physics_frame
	var anchor_a := Vector3(-3.0, 4.0, 0.0)
	var anchor_b := Vector3(3.0, 4.0, 0.0)
	var rest := anchor_a.distance_to(anchor_b) * 1.25
	await _measure("hang", world, anchor_a, anchor_b, rest, Callable())
	world.queue_free()


## Slack rope dropped on flat ground: the commonest thing in a world, and the
## case that has to sleep or every rope costs frame time forever.
func _bench_ground() -> void:
	var world := _new_world()
	_add_box(world, Vector3(0.0, -0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	await get_tree().physics_frame
	var anchor_a := Vector3(-2.0, 1.4, 0.0)
	var anchor_b := Vector3(2.0, 1.4, 0.0)
	var rest := anchor_a.distance_to(anchor_b) * 1.9
	await _measure(
		"ground", world, anchor_a, anchor_b, rest,
		func(point: Vector3) -> float: return -point.y
	)
	world.queue_free()


## Draped over a block, with ground under it. The screenshot case: a cable
## lying across the edge of a machine block. Contact along part of the rope,
## free hang either side.
func _bench_drape_over_block() -> void:
	var world := _new_world()
	_add_box(world, Vector3(0.0, -0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	_add_box(world, Vector3(0.0, 1.25, 0.0), Vector3(2.5, 2.5, 2.5))
	await get_tree().physics_frame
	var anchor_a := Vector3(-3.0, 3.2, 0.0)
	var anchor_b := Vector3(3.0, 0.4, 0.0)
	var rest := anchor_a.distance_to(anchor_b) * 1.3
	await _measure(
		"drape", world, anchor_a, anchor_b, rest,
		_box_depth_probe(Vector3(0.0, 1.25, 0.0), Vector3(2.5, 2.5, 2.5))
	)
	world.queue_free()


## Anchors on opposite faces, so the straight line between them runs through
## solid matter. A rope must never be born inside the world, and must not
## resolve that by squeezing out of the far side.
func _bench_chord_through_block() -> void:
	var world := _new_world()
	_add_box(world, Vector3(0.0, 1.25, 0.0), Vector3(2.5, 2.5, 2.5))
	await get_tree().physics_frame
	var anchor_a := Vector3(-2.2, 1.25, 0.0)
	var anchor_b := Vector3(2.2, 1.25, 0.0)
	var rest := anchor_a.distance_to(anchor_b) * 1.2
	await _measure(
		"through-block", world, anchor_a, anchor_b, rest,
		_box_depth_probe(Vector3(0.0, 1.25, 0.0), Vector3(2.5, 2.5, 2.5))
	)
	world.queue_free()


## A beam far thinner than the particle spacing: the case point collision
## cannot see at all and the rope saws straight through.
func _bench_thin_beam() -> void:
	var world := _new_world()
	_add_box(world, Vector3(0.0, 1.0, 0.0), Vector3(6.0, 0.18, 0.18))
	await get_tree().physics_frame
	var anchor_a := Vector3(0.0, 2.0, -2.5)
	var anchor_b := Vector3(0.0, 2.0, 2.5)
	var rest := anchor_a.distance_to(anchor_b) * 1.5
	await _measure(
		"thin-beam", world, anchor_a, anchor_b, rest,
		_box_depth_probe(Vector3(0.0, 1.0, 0.0), Vector3(6.0, 0.18, 0.18))
	)
	world.queue_free()


## Many ropes at once, all still in contact with the world. Reported as time
## per rope per tick, so the number is independent of how many were run.
func _bench_throughput() -> void:
	var world := _new_world()
	_add_box(world, Vector3(0.0, -0.5, 0.0), Vector3(80.0, 1.0, 80.0))
	await get_tree().physics_frame
	var space := get_viewport().get_world_3d().direct_space_state
	var count := 16
	var handles: Array = []
	var anchors: Array[Vector3] = []
	for index: int in range(count):
		var z := float(index) * 1.5 - float(count) * 0.75
		var a := Vector3(-4.0, 2.0, z)
		var b := Vector3(4.0, 2.0, z)
		handles.append(_adapter.create(a, b, a.distance_to(b) * 1.4, space))
		anchors.append(a)
		anchors.append(b)
	# Settle first: the interesting cost is the steady state a world sits in,
	# not the first second of everything falling.
	for _warm: int in range(600):
		for index: int in range(count):
			_adapter.step(
				handles[index], anchors[index * 2], anchors[index * 2 + 1],
				anchors[index * 2].distance_to(anchors[index * 2 + 1]) * 1.4,
				GRAVITY, STEP_S
			)
		await get_tree().physics_frame
	var elapsed_us := 0
	var ticks := 120
	var awake := 0
	for _tick: int in range(ticks):
		var started := Time.get_ticks_usec()
		for index: int in range(count):
			_adapter.step(
				handles[index], anchors[index * 2], anchors[index * 2 + 1],
				anchors[index * 2].distance_to(anchors[index * 2 + 1]) * 1.4,
				GRAVITY, STEP_S
			)
		elapsed_us += Time.get_ticks_usec() - started
		await get_tree().physics_frame
	for index: int in range(count):
		if not _adapter.is_asleep(handles[index]):
			awake += 1
	var per_rope_ms := (
		float(elapsed_us) / float(ticks) / float(count) / 1000.0
	)
	_results.append({
		"scenario": "throughput x%d" % count,
		"step_ms": per_rope_ms,
		"awake": awake,
		"count": count,
	})
	world.queue_free()


## Drives one rope to rest and reports the numbers that decide whether a solver
## is usable. `depth_probe` returns how far a point is inside solid matter
## (negative or zero when clear); an empty callable means nothing to collide
## with in this scenario.
func _measure(
	label: String,
	world: Node3D,
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_m: float,
	depth_probe: Callable
) -> void:
	var space := get_viewport().get_world_3d().direct_space_state
	var handle: Variant = _adapter.create(anchor_a, anchor_b, rest_m, space)
	var born_inside := _deepest(_adapter.points(handle), depth_probe)
	var previous: PackedVector3Array = _adapter.points(handle).duplicate()
	var settle_ticks := -1
	var quiet_run := 0
	var elapsed_us := 0
	for tick: int in range(MAX_SETTLE_TICKS):
		var started := Time.get_ticks_usec()
		_adapter.step(handle, anchor_a, anchor_b, rest_m, GRAVITY, STEP_S)
		elapsed_us += Time.get_ticks_usec() - started
		await get_tree().physics_frame
		var now: PackedVector3Array = _adapter.points(handle)
		var moved := _worst_shift(previous, now)
		previous = now.duplicate()
		# Settled means it STAYED still, not that one lucky tick was quiet.
		quiet_run = quiet_run + 1 if moved < SETTLED_MOTION_M else 0
		if quiet_run >= 30 and settle_ticks < 0:
			settle_ticks = tick + 1
			break
	var steady_motion := 0.0
	var phantom := 0.0
	var deepest := born_inside
	previous = _adapter.points(handle).duplicate()
	for _tick: int in range(STEADY_TICKS):
		_adapter.step(handle, anchor_a, anchor_b, rest_m, GRAVITY, STEP_S)
		await get_tree().physics_frame
		var now: PackedVector3Array = _adapter.points(handle)
		steady_motion = maxf(steady_motion, _worst_shift(previous, now))
		previous = now.duplicate()
		phantom = maxf(
			phantom, float(_adapter.reported_length(handle)) - rest_m
		)
		deepest = maxf(deepest, _deepest(now, depth_probe))
	var row := {
		"scenario": label,
		"rest_m": rest_m,
		"phantom_m": phantom,
		"phantom_fraction": phantom / maxf(rest_m, 0.000001),
		"settle_s": (
			-1.0 if settle_ticks < 0 else float(settle_ticks) * STEP_S
		),
		"asleep": _adapter.is_asleep(handle),
		"steady_motion_m": steady_motion,
		"born_inside_m": born_inside,
		"penetration_m": deepest,
		"step_ms": float(elapsed_us) / float(maxi(settle_ticks, 1)) / 1000.0,
	}
	_results.append(row)
	# Printed as it lands, not only in the summary: a scenario that never
	# settles runs the full budget, and a bench with no progress output is
	# indistinguishable from a hung one.
	print(
		"[bench] %-14s phantom %6.1f mm  settle %6s  sleep %-3s  steady %5.2f mm  penetr %4.0f mm"
		% [
			label,
			phantom * 1000.0,
			"never" if settle_ticks < 0 else "%.1fs" % (float(settle_ticks) * STEP_S),
			"yes" if row["asleep"] else "NO",
			steady_motion * 1000.0,
			deepest * 1000.0,
		]
	)


func _worst_shift(
	before: PackedVector3Array,
	after: PackedVector3Array
) -> float:
	var worst := 0.0
	for index: int in range(mini(before.size(), after.size())):
		worst = maxf(worst, before[index].distance_to(after[index]))
	return worst


func _deepest(points: PackedVector3Array, depth_probe: Callable) -> float:
	if not depth_probe.is_valid():
		return 0.0
	var deepest := 0.0
	for point: Vector3 in points:
		deepest = maxf(deepest, float(depth_probe.call(point)))
	return deepest


## How far inside an axis-aligned box a point is — the smallest distance to any
## face, so a point dead centre reports the half extent and a point outside
## reports zero.
func _box_depth_probe(centre: Vector3, size: Vector3) -> Callable:
	var half := size * 0.5
	return func(point: Vector3) -> float:
		var local := point - centre
		var inside := minf(
			minf(half.x - absf(local.x), half.y - absf(local.y)),
			half.z - absf(local.z)
		)
		return maxf(inside, 0.0)


func _new_world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	return root


func _add_box(parent: Node3D, centre: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)
	body.global_position = centre
	return body


func _print_table() -> void:
	print("")
	# get_class() reports the native engine class (RefCounted) for any
	# GDScript adapter, not its class_name — useless the moment there is more
	# than one adapter to tell apart. get_global_name() is what a class_name
	# declaration actually registers.
	var script: Script = _adapter.get_script()
	var label := script.get_global_name() if script else _adapter.get_class()
	print("ROPE BENCH — %s" % (label if not label.is_empty() else _adapter.get_class()))
	print(
		"scenario        phantom      settle   sleep  steady    penetr   ms/rope"
	)
	print(
		"--------------------------------------------------------------------"
	)
	for row: Dictionary in _results:
		if row.has("awake"):
			print(
				"%-15s %-12s %-8s %-6s %-9s %-8s %.3f"
				% [
					row["scenario"], "-", "-",
					"%d/%d awake" % [row["awake"], row["count"]],
					"-", "-", row["step_ms"]
				]
			)
			continue
		print(
			"%-15s %6.1f mm%s %6s %6s %6.2f mm%s %5.0f mm%s %.3f"
			% [
				row["scenario"],
				float(row["phantom_m"]) * 1000.0,
				"!" if (
					float(row["phantom_fraction"]) > TARGET_PHANTOM_FRACTION
				) else " ",
				(
					"never" if float(row["settle_s"]) < 0.0
					else "%.1fs" % row["settle_s"]
				),
				"yes" if row["asleep"] else "NO",
				float(row["steady_motion_m"]) * 1000.0,
				"!" if (
					float(row["steady_motion_m"]) > TARGET_STEADY_MOTION_M
				) else " ",
				float(row["penetration_m"]) * 1000.0,
				"!" if (
					float(row["penetration_m"]) > TARGET_PENETRATION_M
				) else " ",
				row["step_ms"],
			]
		)
	print("")
	print("! marks a number past what a shippable rope should manage:")
	print(
		"  phantom stretch <= %.1f%% of rest, steady motion <= %.0f mm/tick, penetration <= %.0f mm"
		% [
			TARGET_PHANTOM_FRACTION * 100.0,
			TARGET_STEADY_MOTION_M * 1000.0,
			TARGET_PENETRATION_M * 1000.0,
		]
	)
