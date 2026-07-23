extends SceneTree
# Spike J: what happens when you hit a rope hard?
#
# Found by playing, not by testing: poking the hanging AVBD rope in
# demos/avbd_shootout.tscn blew it up. The gate did not catch it and could not
# have — all six tests are quasi-static (hang, settle, measure) and not one of
# them calls apply_impulse. So the whole impulse path is unverified, on both
# cores, and this is the first look at it.
#
# The demo's default poke is 5 N*s. On a 5 m rope at 5 segments per metre the
# interior particle masses 0.1 kg, so that is a 50 m/s kick to one particle of
# a rope whose neighbours are standing still — a violent thing to do, and
# exactly the sort of thing a player does.
#
# Reported after the hit: peak stretch during the transient, where it ends up,
# and whether it ever comes back. A rope that survives the hit but never
# returns to its rest length has ratcheted, which for this method means the
# multiplier took the energy and kept it.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_j_impulse.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const MASS_PER_M := 0.5
const ROPE_LEN := 5.0
const SEGMENTS := 25
const END_MASS := 250.0


func _initialize() -> void:
	for payload: float in [0.0, END_MASS]:
		print("\n=== %s, %.0f m, %d segments, hit at the midpoint ==="
				% ["free hanging" if payload == 0.0 else "%.0f kg payload" % payload,
					ROPE_LEN, SEGMENTS])
		print("particle mass %.3f kg, so the impulse column is also (dv / %.3f) m/s"
				% [MASS_PER_M * ROPE_LEN / SEGMENTS, MASS_PER_M * ROPE_LEN / SEGMENTS])
		print("%-8s %8s | %10s %10s %10s %10s"
				% ["solver", "N*s", "peak", "at +1s", "at +4s", "settled"])
		for impulse: float in [0.5, 2.0, 5.0, 20.0]:
			for which: String in ["XPBD", "AVBD"]:
				_hit(which, impulse, payload)
	_repeat()
	_threshold()
	quit(0)


## Repetition turned out to be a red herring: at a one-second gap AVBD is
## already dead 0.07 s in, before the second hit lands. So it is magnitude
## alone, and the only open question is where the cliff is. A SINGLE hit,
## swept.
func _threshold() -> void:
	print("\n=== single hit, magnitude swept: where is the cliff? ===")
	print("%-8s %8s | %s" % ["solver", "payload",
			"20  50  100  150  200  300  500 N*s"])
	for payload: float in [0.0, 20.0, 250.0, 1250.0]:
		for which: String in ["XPBD", "AVBD"]:
			var line := "%-8s %8.0f | " % [which, payload]
			for impulse: float in [20.0, 50.0, 100.0, 150.0, 200.0, 300.0, 500.0]:
				line += "%-5s" % ("die" if _dies(which, impulse, payload) else "ok")
			print(line)


func _dies(which: String, impulse: float, payload: float) -> bool:
	var sim := _settled(which, payload)
	sim.apply_impulse(SEGMENTS / 2, Vector3(impulse, 0.0, 0.0))
	for _f in int(3.0 / DT):
		sim.step(DT)
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now) or len_now > ROPE_LEN * 50.0:
			return true
	return false


## The failure as reported from play: 500 N*s several times in quick
## succession kills AVBD on every payload rope, while XPBD shrugs. The
## suspected mechanism is that AVBD's warm-started state is an accumulator —
## lambda and the penalty carry across frames and decay at gamma = 0.99, about
## a percent a step, so a second hit lands before the first has bled off. beta
## is derived FROM lambda, so a raised lambda steepens the ramp that raises
## lambda: positive feedback. XPBD resets lambda every substep by construction
## and has nothing to accumulate.
##
## If that is right, the spacing between hits decides everything and a single
## hit of the same size is survivable.
func _repeat() -> void:
	print("\n=== 500 N*s, repeated: does the GAP between hits decide it? ===")
	print("%-8s %8s %6s %6s | %10s %10s %9s"
			% ["solver", "payload", "hits", "gap", "peak", "at +4s", "verdict"])
	for payload: float in [20.0, 250.0, 1250.0]:
		for gap: int in [60, 15, 5, 2]:
			for which: String in ["XPBD", "AVBD"]:
				_burst(which, 500.0, payload, 4, gap)


func _burst(which: String, impulse: float, payload: float, hits: int,
		gap_frames: int) -> void:
	var sim := _settled(which, payload)
	var peak := 0.0
	var at_4s := 0.0
	var total := int(6.0 / DT)
	for f in total:
		if f % gap_frames == 0 and f / gap_frames < hits:
			sim.apply_impulse(SEGMENTS / 2, Vector3(impulse, 0.0, 0.0))
		sim.step(DT)
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now) or len_now > ROPE_LEN * 50.0:
			print("%-8s %8.0f %6d %6d | %10s  after %.2f s"
					% [which, payload, hits, gap_frames, "DIVERGED", f * DT])
			return
		peak = maxf(peak, len_now / ROPE_LEN - 1.0)
		at_4s = len_now / ROPE_LEN - 1.0
	print("%-8s %8.0f %6d %6d | %9.1f%% %9.2f%% %9s"
			% [which, payload, hits, gap_frames, peak * 100.0, at_4s * 100.0, "survived"])


func _settled(which: String, payload: float) -> RefCounted:
	var sim: RefCounted
	if which == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = 32
		sim.iterations = 1
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -ROPE_LEN, 0))
	sim.pin(0)
	if payload > 0.0:
		sim.add_point_mass(SEGMENTS, payload)
	for _f in int(4.0 / DT):
		sim.step(DT)
	return sim


func _hit(which: String, impulse: float, payload: float) -> void:
	var sim: RefCounted
	if which == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = 32
		sim.iterations = 1
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -ROPE_LEN, 0))
	sim.pin(0)
	if payload > 0.0:
		sim.add_point_mass(SEGMENTS, payload)

	# Let it settle first: hitting a rope that is still arriving measures the
	# arrival, not the hit.
	for _f in int(4.0 / DT):
		sim.step(DT)
	var rest_stretch: float = sim.total_polyline_length() / ROPE_LEN - 1.0

	sim.apply_impulse(SEGMENTS / 2, Vector3(impulse, 0.0, 0.0))

	var peak := 0.0
	var at_1s := 0.0
	var at_4s := 0.0
	for f in int(4.0 / DT):
		sim.step(DT)
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now):
			print("%-8s %8.1f | %10s" % [which, impulse, "-- NOT FINITE --"])
			return
		var s := len_now / ROPE_LEN - 1.0
		peak = maxf(peak, s)
		if f == int(1.0 / DT):
			at_1s = s
		at_4s = s
	print("%-8s %8.1f | %9.2f%% %9.2f%% %9.2f%% %10.4f"
			% [which, impulse, peak * 100.0, at_1s * 100.0, at_4s * 100.0,
				sim.max_speed()])
	if absf(at_4s) > absf(rest_stretch) * 5.0 + 0.01:
		print("%-8s %8s | did NOT return: rest was %.2f%%, four seconds later %.2f%%"
				% ["", "", rest_stretch * 100.0, at_4s * 100.0])
