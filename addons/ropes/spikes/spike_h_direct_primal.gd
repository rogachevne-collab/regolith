extends SceneTree
# Spike H: does an EXACT primal solve make the length guard unnecessary?
#
# Spike G measured the guard and found the tax is fineness, M = segments /
# segment_length, not segment count: `iterations >= 0.85 * M^0.5` free and
# `1.15 * M^0.6` loaded. Two explanations fit that, and they point opposite
# ways:
#
#   (a) the block coordinate descent needs more sweeps as the rope gets finer,
#       so an exact solve of the same system removes the tax entirely;
#   (b) the tax is in the derived beta, whose ramp goes as 1/(n_dual^2 e^2 L^2)
#       and is therefore already calibrated against the sweep count — in which
#       case an exact solve changes nothing and the guard is load-bearing.
#
# spikes/avbd_direct_rope.gd is (a): AVBD with _primal_sweep replaced by a
# block-tridiagonal Thomas solve and NOTHING else touched. This spike puts the
# two side by side on identical ropes and asks where each one's tension error
# first falls inside 10%. If the direct column collapses to the floor of 8, the
# guard becomes a floor and the cost table in avbd_rope.gd can be deleted. If
# it does not, we have learned the guard is real and beta is the next target.
#
# Protocol is spike G's exactly — 12 s settle, mean over the last 3 s, tension
# of the top segment against (payload + mass_per_m * length) * g — so the two
# spikes' numbers are directly comparable.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_h_direct_primal.gd

const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")
const AVBDDirect := preload("res://addons/ropes/spikes/avbd_direct_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const MASS_PER_M := 0.5
const SIM_S := 12.0
const WINDOW_S := 3.0

const LADDER := [8, 12, 16, 24, 32, 48, 64, 96, 128]

## (length m, segments per metre, payload kg). Chosen to span fineness at a
## particle count the ladder can afford twice over: M = 80, 320, 800, 1280.
const CONFIGS := [
	[5.0, 4.0, 0.0],
	[5.0, 4.0, 250.0],
	[20.0, 4.0, 250.0],
	[5.0, 16.0, 0.0],
	[5.0, 16.0, 250.0],
	[50.0, 4.0, 250.0],
]


func _initialize() -> void:
	# One part per run when iterating: the ladder is minutes, the two risk
	# checks are seconds, and this project hangs on two headless instances.
	var parts := "123"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("part="):
			parts = a.substr(5)
	if parts.contains("1"):
		_ladder()
	if parts.contains("2"):
		_catenary()
	if parts.contains("3"):
		_slack()
	if parts.contains("4"):
		_jitter_curve()
	if parts.contains("5"):
		_relax_curve()
	quit(0)


## Part 4 found the direct solve's jitter plateauing near 3.4 mm on the 50 m
## rope while the sweep's keeps falling to 1.53 mm — the exact step nails the
## tension in 12 iterations and then stops making the rope quieter, which is
## the opposite of how a converging method should behave. The suspect is the
## step itself: one exact Newton step moves the whole rope at once with a
## frozen active set and no line search, where N small block solves damp each
## other by construction. If that is it, a scaled step should buy the floor
## back; if it is not, the noise is inherent and the sweep keeps an advantage
## that has nothing to do with iteration count.
func _relax_curve() -> void:
	const LENGTH := 50.0
	const SEGS := 200
	const PAYLOAD := 250.0
	const ITERS := 24
	print("\n=== direct step scaling, %.0f m / %d segs / %.0f kg, %d iterations ==="
			% [LENGTH, SEGS, PAYLOAD, ITERS])
	print("sweep at this budget for reference: +86.1%% tension, 3.32 mm jitter")
	print("%7s | %9s %9s %9s" % ["relax", "T err", "jitter", "us"])
	for relax: float in [1.0, 0.8, 0.6, 0.4]:
		var r := _probe(SEGS, LENGTH, PAYLOAD, ITERS, true, relax)
		print("%7.1f | %+8.1f%% %7.2fmm %9.0f" % [relax, r.err, r.jitter, r.usec])


## Part 1 reports each core at its OWN tension crossing, which is not a fair
## jitter comparison: on the 50 m loaded rope the direct solve crosses at 12
## iterations and reads 7.41 mm against the sweep's 1.53 mm at 48. Two readings
## of that: either the exact step is inherently noisier there, or 12 iterations
## simply is not enough for the rope to stop ringing even once its tension is
## right — and those have opposite consequences. So: same rope, same budget,
## both cores, iterations swept.
func _jitter_curve() -> void:
	const LENGTH := 50.0
	const SEGS := 200
	const PAYLOAD := 250.0
	print("\n=== jitter vs budget, %.0f m / %d segs / %.0f kg, same rope both cores ==="
			% [LENGTH, SEGS, PAYLOAD])
	print("%6s | %8s %8s %8s | %8s %8s %8s"
			% ["iter", "sweep T", "jitter", "us", "direct T", "jitter", "us"])
	for iters: int in [12, 24, 48]:
		var line := "%6d |" % iters
		for direct: bool in [false, true]:
			var r := _probe(SEGS, LENGTH, PAYLOAD, iters, direct)
			line += " %+7.1f%% %6.2fmm %8.0f |" % [r.err, r.jitter, r.usec]
		print(line)


func _ladder() -> void:
	print("=== primal step: Gauss-Seidel sweep vs exact block-tridiagonal solve ===")
	print("iterations at which the tension error first falls inside 10%%,")
	print("and what the step costs there. Floor is %d." % AVBDRope.ITERATIONS_MIN)
	# Tension is what the crossing is defined on, but jitter and stretch are why
	# AVBD was adopted at all (ADR 0007: 13x quieter on a settled rope), so a
	# primal step that bought tension by giving those up would be a bad trade
	# that a tension-only table would hide.
	print("%7s %6s %6s %7s %6s | %-41s | %-41s"
			% ["length", "seg/m", "segs", "M", "load", "sweep", "direct"])
	print("%7s %6s %6s %7s %6s | %5s %7s %7s %7s %6s | %5s %7s %7s %7s %6s"
			% ["", "", "", "", "", "iter", "T err", "jitter", "stretch", "us",
				"iter", "T err", "jitter", "stretch", "us"])
	for cfg: Array in CONFIGS:
		var length: float = cfg[0]
		var spm: float = cfg[1]
		var payload: float = cfg[2]
		var segs := int(round(length * spm))
		var m_metric := float(segs) / (length / float(segs))
		var line := "%6.0fm %6.0f %6d %7.0f %6s |" % [length, spm, segs, m_metric,
				"%.0fkg" % payload if payload > 0.0 else "free"]
		for direct: bool in [false, true]:
			line += _crossing(segs, length, payload, direct)
		print(line)


# --- the two places a frozen active set should break -------------------------

## Two pins, which the hang cases above never exercise: the system now has a
## Dirichlet row at BOTH ends, and the shape has an analytic answer that knows
## nothing about either solver.
func _catenary() -> void:
	const ROPE_LEN := 12.0
	const SPAN := 10.0
	const SEGMENTS := 60
	const SIM_S := 30.0

	var half_span := SPAN / 2.0
	var a := _solve_catenary_a(half_span, ROPE_LEN / 2.0)
	var w := MASS_PER_M * G
	var sag_ref := a * (cosh(half_span / a) - 1.0)
	var t_sup_ref := w * a * cosh(half_span / a)
	print("\n=== catenary, %.0f m over %.0f m, %d segments, both at 8 iterations ==="
			% [ROPE_LEN, SPAN, SEGMENTS])
	print("analytic: sag %.4f m, T_support %.2f N" % [sag_ref, t_sup_ref])
	for direct: bool in [false, true]:
		var sim: RefCounted = AVBDDirect.new() if direct else AVBDRope.new()
		sim.length_guard = false
		sim.substeps = 1
		sim.iterations = AVBDRope.ITERATIONS_MIN
		sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
		sim.gravity = Vector3(0, -G, 0)
		sim.damping = 2.0
		sim.drag = 2.0
		sim.lay_line(Vector3(-half_span, 0, 0), Vector3(half_span, 0, 0))
		sim.pin(0)
		sim.pin(SEGMENTS)
		for _f in int(SIM_S / DT):
			sim.step(DT)
		var lowest := 0.0
		for i in sim.positions.size():
			lowest = minf(lowest, sim.positions[i].y)
		var t_sup: float = sim.tensions[0]
		print("%-8s sag %.4f (%+.1f%%)  T_support %.2f (%+.1f%%)  settled %.4f"
				% ["direct" if direct else "sweep", -lowest,
					(-lowest / sag_ref - 1.0) * 100.0, t_sup,
					(t_sup / t_sup_ref - 1.0) * 100.0, sim.max_speed()])


## Every segment slack, in zero gravity. This is the case the direct solve is
## most likely to get wrong: it freezes which constraints are active when it
## assembles the blocks, where the sweep re-decides at every particle. A rope
## squashed to half its rest length must manufacture no tension and must not
## move at all — the same check tests/test_unilateral.gd makes of XPBD.
func _slack() -> void:
	const SEGMENTS := 40
	const ROPE_LEN := 4.0
	print("\n=== slack: rope compressed to 50%% of rest, zero gravity ===")
	for direct: bool in [false, true]:
		var sim: RefCounted = AVBDDirect.new() if direct else AVBDRope.new()
		sim.length_guard = false
		sim.substeps = 1
		sim.iterations = AVBDRope.ITERATIONS_MIN
		sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
		sim.gravity = Vector3.ZERO
		sim.damping = 0.0
		sim.drag = 0.0
		sim.lay_line(Vector3.ZERO, Vector3(ROPE_LEN * 0.5, 0, 0))
		var start: PackedVector3Array = sim.positions.duplicate()
		var worst_t := 0.0
		var worst_move := 0.0
		for _f in 600:
			sim.step(DT)
			for j in SEGMENTS:
				worst_t = maxf(worst_t, sim.tensions[j])
			for i in sim.positions.size():
				worst_move = maxf(worst_move, (sim.positions[i] - start[i]).length())
		# GDScript's % has no %e conversion, and these numbers are either zero
		# or catastrophic, so plain fixed point with room to be alarming.
		print("%-8s peak tension %.9f N, peak drift %.9f m"
				% ["direct" if direct else "sweep", worst_t, worst_move])


func _solve_catenary_a(half_span: float, half_len: float) -> float:
	var lo := 0.5
	var hi := 500.0
	for _i in 200:
		var mid := (lo + hi) * 0.5
		if mid * sinh(half_span / mid) > half_len:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## Walk the ladder, stop at the first rung inside 10%, report it.
func _crossing(segs: int, length: float, payload: float, direct: bool) -> String:
	for iters: int in LADDER:
		var r := _probe(segs, length, payload, iters, direct)
		if absf(r.err) <= 10.0:
			return " %5d %+6.1f%% %5.2fmm %6.3f%% %6.0f |" % [iters, r.err,
					r.jitter, r.stretch, r.usec]
	return " %5s %7s %7s %7s %6s |" % ["--", "--", "--", "--", "--"]


func _probe(segs: int, length: float, payload: float, iters: int,
		direct: bool, relax := 1.0) -> Dictionary:
	var sim: RefCounted = AVBDDirect.new() if direct else AVBDRope.new()
	if direct:
		sim.relax = relax
	# Both sides run the budget they are given; measuring the guard against
	# itself would tell us nothing.
	sim.length_guard = false
	sim.substeps = 1
	sim.iterations = iters
	sim.setup(segs, length, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -length, 0))
	sim.pin(0)
	if payload > 0.0:
		sim.add_point_mass(segs, payload)

	var total := int(SIM_S / DT)
	var from := total - int(WINDOW_S / DT)
	var tension := 0.0
	var usec := 0.0
	var motion := 0.0
	var stretch := 0.0
	var samples := 0
	var prev: PackedVector3Array = sim.positions.duplicate()
	for f in total:
		var t0 := Time.get_ticks_usec()
		sim.step(DT)
		var used := float(Time.get_ticks_usec() - t0)
		var curr: PackedVector3Array = sim.positions
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now) or len_now > length * 20.0:
			return {"err": INF, "usec": 0.0, "jitter": INF, "stretch": INF}
		if f >= from:
			tension += sim.tensions[0]
			usec += used
			stretch += len_now / length - 1.0
			# Mean particle motion per tick on a rope that has visually stopped —
			# the column spike B identified as the disease and the one no paper
			# in this area reports.
			var m := 0.0
			for i in curr.size():
				m += (curr[i] - prev[i]).length()
			motion += m / float(curr.size())
			samples += 1
		prev = curr.duplicate()
	if direct and sim.fallbacks > 0:
		print("  note: %d singular blocks fell back to the sweep (%d segs, %d it)"
				% [sim.fallbacks, segs, iters])
	var exact := (payload + MASS_PER_M * length) * G
	return {
		"err": (tension / samples / exact - 1.0) * 100.0,
		"usec": usec / samples,
		"jitter": motion / samples * 1000.0,
		"stretch": stretch / samples * 100.0,
	}
