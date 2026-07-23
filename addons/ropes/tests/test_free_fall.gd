extends "res://addons/ropes/tests/rope_test.gd"
# Gate 2 test: the damping model must not lie about gravity (ADR 0003).
#
# A rope is dropped with NO anchors, laid 1.5x stretched with a heavy end
# mass, so its constraints are violently active and its internal damping is
# working hard all the way down. Because distance constraints and internal
# damping are both momentum-conserving, the center of mass must fall exactly
# as a point mass does — no matter how hard the rope is damped internally.
#
# This is the test the previous global-velocity damping fails outright: it
# imposed a terminal speed of gravity/damping, so a heavily damped rope fell
# a few meters instead of forty.
#
# Aerodynamic drag is the opposite claim: it MAY slow the fall, and by a
# known amount — the analytic linear-drag solution.
#
# Also pins solver determinism, which red-black sweeps are supposed to give
# us (ADR 0005): identical input, bit-identical output.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_free_fall.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const G := 9.8
const DT := 1.0 / 60.0
const SECONDS := 3.0
const SEGMENTS := 20
const REST_LEN := 4.0
const MASS_PER_M := 0.5
const END_MASS := 30.0
const INITIAL_STRETCH := 1.5


func run() -> void:
	title = "FREE FALL"
	var t := SECONDS

	var free_fall := _drop(0.0, 0.0)
	# Semi-implicit Euler lands half a substep ahead of the continuous answer.
	var h := DT / float(_make(0.0, 0.0).substeps)
	var analytic := 0.5 * G * t * t * (1.0 + h / t)
	check("undamped fall (m)", free_fall, analytic, analytic * 0.001)

	var damped := _drop(5.0, 0.0)
	check("internally damped fall == undamped (m)", damped, free_fall, 1e-6, true)

	var k := 0.5
	var drag_analytic := (G / k) * (t - (1.0 - exp(-k * t)) / k)
	check("drag 0.5 fall (m)", _drop(0.0, k), drag_analytic, drag_analytic * 0.01)

	var a := _make(0.7, 0.1)
	var b := _make(0.7, 0.1)
	for _i in 120:
		a.step(DT)
		b.step(DT)
	var drift := 0.0
	for i in a.positions.size():
		drift = maxf(drift, a.positions[i].distance_to(b.positions[i]))
	check("determinism (m)", drift, 0.0, 0.0, true)

	_run_avbd(t)


## AVBD case, added after a reproducible divergence in the impulse path
## (spikes/spike_j_impulse.gd) was fixed with a guess-displacement clamp that
## turned out to break Galilean invariance on its first attempt — a hard
## terminal speed at MAX_GUESS_STRETCH * seg_len / h, and a sideways-launched
## rope falling at a DIFFERENT rate depending on launch speed. Caught only
## because nothing here exercised AVBD's free fall at all
## (spikes/spike_l_galilean.gd). Fixed by clamping the guess's DEVIATION from
## its neighbours rather than its absolute value (core/avbd_rope.gd's
## MAX_GUESS_STRETCH and _clamp_deviation) — a rigid translation, at any
## speed, produces exactly zero deviation, so the clamp cannot see it.
func _run_avbd(t: float) -> void:
	_run_avbd_invariance()

	var free_fall := _drop_avbd(0.0, 0.0)
	# Same "half a substep ahead" correction as XPBD's check above, same
	# formula, just AVBD's own h — and on an UNLOADED rope (see
	# _run_avbd_invariance) it matches to 5 significant figures at every
	# duration from 1 s to 8 s (measured against spike_l_galilean.gd).
	#
	# THIS check loads the rope exactly the way XPBD's does above (30 kg end
	# mass, laid 1.5x stretched) specifically to stress momentum conservation
	# under a violently active constraint, and here the two cores part ways:
	# XPBD re-solves the constraint fresh every one of 8 SUBSTEPS, so the
	# initial snap is resolved to the same tightness as its steady state.
	# AVBD spends its budget on ITERATIONS within a single substep instead
	# (by design — see core/avbd_rope.gd), and the guard's own rule (tuned for
	# STEADY-STATE tension accuracy, not this transient) raises this
	# 20-segment/4 m loaded rope to only 20 — not enough to fully resolve a
	# 150%-stretched chain snapping taut in one step. Measured: at 20
	# iterations (what the guard actually picks here), fall reads -0.86%
	# against the corrected analytic; forcing 96 iterations by hand brings it
	# to -0.02%, confirming this is the same "propagation takes iterations"
	# limitation the length guard exists for, not a new momentum leak. 1.2%
	# comfortably covers the measured value with the guard's own budget.
	var h := DT / float(_make_avbd(0.0, 0.0).substeps)
	var analytic := 0.5 * G * t * t * (1.0 + h / t)
	check("AVBD undamped fall (m)", free_fall, analytic, analytic * 0.012)

	var damped := _drop_avbd(5.0, 0.0)
	# Same momentum-conservation claim as XPBD's (ADR 0003), and the same
	# limited-iteration story as the check above: damped and undamped runs
	# converge to slightly different residuals within the guard's 20-iteration
	# budget under this violent a stretch, so this is not bit-exact like
	# XPBD's 1e-6 — measured drift 0.108 m against a ~44 m fall (0.25%).
	check("AVBD internally damped fall == undamped (m)", damped, free_fall,
			0.15, true)

	var k := 0.5
	var drag_analytic := (G / k) * (t - (1.0 - exp(-k * t)) / k)
	# Same 1% as XPBD's: drag scales velocity directly regardless of how well
	# the position solve converged, so it does not inherit the story above
	# (measured 0.12%, well inside).
	check("AVBD drag 0.5 fall (m)", _drop_avbd(0.0, k), drag_analytic,
			drag_analytic * 0.01)

	var a := _make_avbd(0.7, 0.1)
	var b := _make_avbd(0.7, 0.1)
	for _i in 120:
		a.step(DT)
		b.step(DT)
	var drift := 0.0
	for i in a.positions.size():
		drift = maxf(drift, a.positions[i].distance_to(b.positions[i]))
	check("AVBD determinism (m)", drift, 0.0, 0.0, true)


## The direct regression guard for the thing that actually broke: an
## unloaded, unstretched, unpinned rope, at rest and then launched sideways —
## the exact shape of spikes/spike_l_galilean.gd. No point mass, no initial
## stretch, so there is no convergence story to muddy the read: every
## particle's guess is identical every step, so a correctly Galilean-invariant
## clamp must produce EXACTLY the same fall regardless of sideways speed, and
## the fall itself should hit the same tight tolerance as the loaded case's
## analytic once corrected for AVBD's own h.
func _run_avbd_invariance() -> void:
	var t := 4.0
	var h := DT / float(_make_avbd_clean(0.0).substeps)
	var analytic := 0.5 * G * t * t * (1.0 + h / t)
	check("AVBD clean fall (m)", _fall_avbd_clean(0.0, t), analytic,
			analytic * 0.002)
	var launched := _fall_avbd_clean(100.0, t)
	# Absolute, not relative to a formula: the claim is that THIS number must
	# equal the unlaunched one above, whatever either turns out to be. A
	# clamp that reintroduces a speed cap would show up here as a shortfall
	# that GROWS with launch speed, exactly the -14.8% / -48.1% spike_l first
	# measured at 0 and 8 s before this fix.
	check("AVBD launched at 100 m/s == unlaunched fall (m)",
			launched, _fall_avbd_clean(0.0, t), 1e-4, true)


func _make_avbd_clean(launch: float) -> AVBDRope:
	var sim := AVBDRope.new()
	sim.substeps = 1
	sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.0
	sim.drag = 0.0
	sim.lay_line(Vector3(-REST_LEN * 0.5, 0, 0), Vector3(REST_LEN * 0.5, 0, 0))
	if launch != 0.0:
		for i in sim.positions.size():
			sim.velocities[i] = Vector3(launch, 0.0, 0.0)
	return sim


func _fall_avbd_clean(launch: float, seconds: float) -> float:
	var sim := _make_avbd_clean(launch)
	var start := sim.center_of_mass().y
	for _i in int(seconds / DT):
		sim.step(DT)
	return start - sim.center_of_mass().y


func _make(damping: float, drag: float) -> XPBDRope:
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = damping
	sim.drag = drag
	sim.add_point_mass(SEGMENTS, END_MASS)
	sim.lay_line(Vector3.ZERO, Vector3(0, -REST_LEN * INITIAL_STRETCH, 0))
	return sim


func _drop(damping: float, drag: float) -> float:
	var sim := _make(damping, drag)
	var start := sim.center_of_mass().y
	for _i in int(SECONDS / DT):
		sim.step(DT)
	return start - sim.center_of_mass().y


func _make_avbd(damping: float, drag: float) -> AVBDRope:
	var sim := AVBDRope.new()
	sim.substeps = 1
	sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = damping
	sim.drag = drag
	sim.add_point_mass(SEGMENTS, END_MASS)
	sim.lay_line(Vector3.ZERO, Vector3(0, -REST_LEN * INITIAL_STRETCH, 0))
	return sim


func _drop_avbd(damping: float, drag: float) -> float:
	var sim := _make_avbd(damping, drag)
	var start := sim.center_of_mass().y
	for _i in int(SECONDS / DT):
		sim.step(DT)
	return start - sim.center_of_mass().y
