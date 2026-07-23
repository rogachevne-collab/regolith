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
