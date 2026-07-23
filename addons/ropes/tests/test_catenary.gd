extends "res://addons/ropes/tests/rope_test.gd"
# Gate 2 test: static catenary, run against BOTH solver cores (ADR 0007). A
# 12 m rope pinned at two points 10 m apart settles; compared against the
# analytic catenary:
#   shape:   a * sinh(d/a) = L/2 solved for a;  sag = a * (cosh(d/a) - 1)
#   tension: H = w * a at the lowest point;  T(support) = w * a * cosh(d/a)
# This validates both the equilibrium geometry and the Lagrange-multiplier
# tension readback in one scenario, for XPBD (compliance 0 — the shipping
# core, designed to hold length near-exactly) and AVBD (ADR 0007's
# load-bearing candidate).
#
# AVBD is a SOFT constraint by construction: core/avbd_rope.gd's max_stretch
# is "the stretch it is DESIGNED to settle at", derived into a penalty ramp,
# not an incidental error. So its rope really is longer at rest than 12 m —
# measured 12.081 m here, +0.68% stretch — and a shallow catenary's sag is
# strongly length-sensitive: solving the SAME analytic formulas for the
# length AVBD actually produced (instead of the nominal 12 m) turns its
# +2.3%-against-nominal sag reading into +0.05% against its own length. That
# is what "the sag is explained, not excused" means here, and it is why each
# core below is checked against the catenary for the length IT settled at,
# with the length itself checked separately against what that core's own
# design permits. A real shape bug in either core still fails the sag check;
# a real regression in AVBD's stretch behavior still fails the length check.
# Measured 2026-07-23; see spike_f_catenary_and_length.gd and
# docs/research/mass-ratio-state-of-the-art.md for the numbers and ADR 0007
# for the decision this closes out.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_catenary.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const ROPE_LEN := 12.0
const SPAN := 10.0
const MASS_PER_M := 0.5
const G := 9.8
const SEGMENTS := 60
const SIM_SECONDS := 30.0
const DT := 1.0 / 60.0


func run() -> void:
	title = "CATENARY"
	var half_span := SPAN / 2.0
	var w := MASS_PER_M * G

	for which: String in ["XPBD", "AVBD"]:
		var sim := _make(which)
		sim.lay_line(Vector3(-half_span, 0, 0), Vector3(half_span, 0, 0))
		sim.pin(0)
		sim.pin(SEGMENTS)
		for _i in int(SIM_SECONDS / DT):
			sim.step(DT)

		var lowest := 0.0
		for i in sim.positions.size():
			lowest = minf(lowest, sim.positions[i].y)
		var settled_len: float = sim.total_polyline_length()

		# Solve the catenary for the length THIS core actually settled at, not
		# the nominal 12 m (see header). XPBD settles within 0.04% of nominal,
		# so this barely moves its reference; for AVBD it is the whole point.
		var a := _solve_catenary_a(half_span, settled_len / 2.0)
		var sag_ref := a * (cosh(half_span / a) - 1.0)
		var h_ref := w * a
		var t_support_ref := w * a * cosh(half_span / a)
		print("  [%s] catenary parameter a = %.3f (settled length %.4f m)"
				% [which, a, settled_len])

		check("%s settled (max speed m/s)" % which, sim.max_speed(), 0.0, 0.005, true)
		# Per-core tolerance, not one band for both: XPBD at compliance 0 is
		# designed to hold length almost exactly; AVBD's settled stretch is
		# governed by its own max_stretch knob (core/avbd_rope.gd) and this
		# scenario's tension is well under the derivation's calibration point,
		# so it settles under that knob (0.68% measured, knob is 1%). See
		# _length_tolerance.
		check("%s length (m)" % which, settled_len, ROPE_LEN,
				ROPE_LEN * _length_tolerance(which, sim), true)
		# 1%: with the reference solved for the length actually produced, this
		# is pure shape error, and measured shape error is two orders of
		# magnitude inside it (XPBD +0.01%, AVBD +0.05%) — tight enough to
		# still catch a real equilibrium-geometry bug in either core.
		check("%s sag (m)" % which, -lowest, sag_ref, sag_ref * 0.01)
		# 5%, unchanged from before this fix: both cores already read inside
		# it against the nominal-length reference (XPBD -1.1%, AVBD -1.4% at
		# support), and switching to the actual-length reference only pulls
		# them closer (AVBD support -1.15%, mid -0.77%), so nothing here needed
		# widening — only the sag band did.
		check("%s mid tension H (N)" % which, sim.tensions[SEGMENTS / 2], h_ref,
				h_ref * 0.05)
		check("%s support tension (N)" % which, sim.tensions[0], t_support_ref,
				t_support_ref * 0.05)


func _make(which: String) -> RefCounted:
	var sim: RefCounted
	if which == "XPBD":
		sim = XPBDRope.new()
		sim.stretch_compliance = 0.0
		sim.substeps = 16
		sim.iterations = 2
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		# Let the length guard pick the iteration count the way production
		# code (Rope3D) does rather than hand-tuning a number for this one
		# scenario: 60 segments over 12 m free-hanging needs 16 by the
		# guard's own rule, and it gets there on its own from the floor.
		sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	# Both dampings vanish at equilibrium (zero relative velocity, zero
	# absolute velocity), so neither can shift the static answer we compare
	# against — they only decide how fast we get there. Internal damping
	# alone barely touches the long-wavelength swing mode, hence the drag.
	sim.damping = 2.0
	sim.drag = 2.0
	return sim


## How far the "length (m)" check lets settled length drift from nominal, as
## a fraction of ROPE_LEN. Not one band for both cores: XPBD at compliance 0
## is near-rigid by design (0.5%, its historical band); AVBD is a soft
## constraint whose settle point is its own max_stretch knob, so the bound is
## derived from that knob (1.5x it) rather than copied from XPBD's. That
## catches the penalty ramp overshooting its own design point while tolerating
## anywhere the knob itself permits — measured settle is 0.68%, comfortably
## under both max_stretch (1%) and this 1.5% bound.
func _length_tolerance(which: String, sim: RefCounted) -> float:
	if which == "XPBD":
		return 0.005
	return sim.max_stretch * 1.5


func _solve_catenary_a(half_span: float, half_len: float) -> float:
	# a * sinh(half_span / a) is monotonically decreasing in a toward half_span.
	var lo := 0.5
	var hi := 500.0
	for _i in 200:
		var mid := (lo + hi) * 0.5
		if mid * sinh(half_span / mid) > half_len:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5
