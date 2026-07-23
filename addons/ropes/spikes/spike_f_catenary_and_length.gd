extends SceneTree
# Spike F: the independent arbiter, and the method's own stated weak spot.
#
# Part 1 — catenary. tests/test_catenary.gd checks both cores against the
# analytic hanging chain: a sinh(d/a) = L/2, sag = a(cosh(d/a) - 1), H = w a,
# T_support = w a cosh(d/a). It is the only check we have that knows the right
# answer for BOTH shape and tension, so it decides whether AVBD's numbers can
# be trusted at all. The "actual-length catenary" line below each solver is
# the explanation for ADR 0007's open sag question: AVBD is a soft
# constraint (max_stretch), so it settles genuinely longer than the nominal
# 12 m (+0.68% here), and a shallow catenary's sag is sensitive enough to
# length that solving the same formulas for the length it actually produced
# turns a nominal-length sag error of +2.3% into +0.05% against its own
# length — shape is right, the rope is just longer. test_catenary.gd now
# checks it that way.
#
# Part 2 — length. AVBD's primal step is Gauss-Seidel, so tension travels along
# the chain at one particle per sweep; the paper's own limitations section says
# propagation "can take multiple frames" for long chains. XPBD has the same
# problem through a different door. Both get the same ropes, 5 m to 100 m.
#
# Part 2 is now also the ACCEPTANCE table for the length guard: AVBD is given
# the iteration floor and left to raise itself through
# AVBDRope.required_iterations(), so what the table reports is what a rope
# actually gets. The rule was measured in spike_g_length_guard.gd; this is the
# independent check that it holds at the four lengths the addon promises.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_f_catenary_and_length.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const MASS_PER_M := 0.5


func _initialize() -> void:
	_catenary()
	_length_sweep()
	quit(0)


# --- Part 1 -----------------------------------------------------------------

func _catenary() -> void:
	const ROPE_LEN := 12.0
	const SPAN := 10.0
	const SEGMENTS := 60
	const SIM_S := 30.0

	var half_span := SPAN / 2.0
	var a := _solve_catenary_a(half_span, ROPE_LEN / 2.0)
	var w := MASS_PER_M * G
	var sag_ref := a * (cosh(half_span / a) - 1.0)
	var h_ref := w * a
	var t_sup_ref := w * a * cosh(half_span / a)

	print("=== catenary: %.0f m rope over a %.0f m span, %d segments, %.0f s ==="
			% [ROPE_LEN, SPAN, SEGMENTS, SIM_S])
	print("analytic (nominal L=%.1f): a=%.4f  sag=%.4f m  H=%.2f N  T_support=%.2f N"
			% [ROPE_LEN, a, sag_ref, h_ref, t_sup_ref])
	print("%-16s | %9s %8s | %8s %8s | %9s %9s | %9s %9s | %8s"
			% ["solver", "length", "stretch", "sag", "err(nom)", "H mid", "err(nom)",
				"T support", "err(nom)", "settled"])

	for which: String in ["XPBD", "AVBD"]:
		var sim := _make(which, SEGMENTS, ROPE_LEN)
		# Both dampings vanish at equilibrium, so neither can shift the static
		# answer — they only decide how fast we get there (as in the test).
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
		var sag: float = -lowest
		var h_mid: float = sim.tensions[SEGMENTS / 2]
		var t_sup: float = sim.tensions[0]
		var settled_len: float = sim.total_polyline_length()
		print("%-16s | %9.4f %7.3f%% | %8.4f %7.1f%% | %9.2f %8.1f%% | %9.2f %8.1f%% | %7.4f"
				% [which, settled_len, (settled_len / ROPE_LEN - 1.0) * 100.0,
					sag, (sag / sag_ref - 1.0) * 100.0,
					h_mid, (h_mid / h_ref - 1.0) * 100.0,
					t_sup, (t_sup / t_sup_ref - 1.0) * 100.0, sim.max_speed()])

		# Cross-check: is the sag error explained by the settled LENGTH being
		# different from the nominal 12 m, rather than by shape error? Solve the
		# same catenary for the length this core actually settled at and compare
		# sag against THAT reference instead.
		var a_actual := _solve_catenary_a(half_span, settled_len / 2.0)
		var sag_actual_ref := a_actual * (cosh(half_span / a_actual) - 1.0)
		var h_actual_ref := w * a_actual
		var t_actual_ref := w * a_actual * cosh(half_span / a_actual)
		print("%-16s | actual-length catenary: a=%.4f sag=%.4f (measured err %+.2f%%) H=%.3f (err %+.2f%%) T_sup=%.3f (err %+.2f%%)"
				% [which, a_actual, sag_actual_ref, (sag / sag_actual_ref - 1.0) * 100.0,
					h_actual_ref, (h_mid / h_actual_ref - 1.0) * 100.0,
					t_actual_ref, (t_sup / t_actual_ref - 1.0) * 100.0])


# --- Part 2 -----------------------------------------------------------------

func _length_sweep() -> void:
	const SEG_PER_M := 4.0
	const SIM_S := 12.0
	const WINDOW_S := 3.0
	const PAYLOAD := 250.0

	for payload: float in [0.0, PAYLOAD]:
		print("\n=== length sweep, %s, %.0f segments per metre ==="
				% ["free hanging" if payload == 0.0 else "%.0f kg payload" % payload,
					SEG_PER_M])
		print("%-10s %5s | %-32s | %-38s"
				% ["length", "segs", "XPBD sub=32", "AVBD, guard picks iterations"])
		print("%-10s %5s | %10s %8s %10s | %10s %8s %10s %5s"
				% ["", "", "stretch", "jitter", "T err", "stretch", "jitter",
					"T err", "iter"])
		for length: float in [5.0, 20.0, 50.0, 100.0]:
			var segs := int(length * SEG_PER_M)
			var line := "%8.0f m %5d |" % [length, segs]
			for which: String in ["XPBD", "AVBD"]:
				line += _hang(which, segs, length, payload, SIM_S, WINDOW_S)
			print(line)


func _hang(which: String, segs: int, length: float, payload: float,
		sim_s: float, window_s: float) -> String:
	var sim := _make(which, segs, length)
	sim.damping = 0.5
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -length, 0))
	sim.pin(0)
	if payload > 0.0:
		sim.add_point_mass(segs, payload)

	var total := int(sim_s / DT)
	var from := total - int(window_s / DT)
	var stretch := 0.0
	var motion := 0.0
	var tension := 0.0
	var samples := 0
	var prev: PackedVector3Array = sim.positions.duplicate()
	for f in total:
		sim.step(DT)
		var curr: PackedVector3Array = sim.positions
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now) or len_now > length * 20.0:
			return "%32s" % "  -- DIVERGED --"
		if f >= from:
			stretch += len_now / length - 1.0
			var m := 0.0
			for i in curr.size():
				m += (curr[i] - prev[i]).length()
			motion += m / float(curr.size())
			tension += sim.tensions[0]
			samples += 1
		prev = curr.duplicate()

	var exact := (payload + MASS_PER_M * length) * G
	var line := " %9.3f%% %6.2fmm %+9.1f%%" % [stretch / samples * 100.0,
			motion / samples * 1000.0, (tension / samples / exact - 1.0) * 100.0]
	if which == "AVBD":
		line += " %5d" % sim.effective_iterations()
	return line + " |"


func _make(which: String, segs: int, length: float) -> RefCounted:
	var sim: RefCounted
	if which == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = 32
		sim.iterations = 1
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		# The floor, not a budget: whatever this rope's size demands on top of
		# it is the guard's business, and reporting anything else here would be
		# testing a configuration nobody can actually author.
		sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(segs, length, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	return sim


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
