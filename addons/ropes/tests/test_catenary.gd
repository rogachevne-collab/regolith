extends "res://addons/ropes/tests/rope_test.gd"
# Gate 2 test: static catenary. A 12 m rope pinned at two points 10 m apart
# settles; we compare against the analytic catenary:
#   shape:   a * sinh(d/a) = L/2 solved for a;  sag = a * (cosh(d/a) - 1)
#   tension: H = w * a at the lowest point;  T(support) = w * a * cosh(d/a)
# This validates both the equilibrium geometry and the Lagrange-multiplier
# tension readback in one scenario.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_catenary.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const ROPE_LEN := 12.0
const SPAN := 10.0
const MASS_PER_M := 0.5
const G := 9.8
const SEGMENTS := 60
const SIM_SECONDS := 30.0
const DT := 1.0 / 60.0


func run() -> void:
	title = "CATENARY"
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.stretch_compliance = 0.0
	# Both dampings vanish at equilibrium (zero relative velocity, zero
	# absolute velocity), so neither can shift the static answer we compare
	# against — they only decide how fast we get there. Internal damping
	# alone barely touches the long-wavelength swing mode, hence the drag.
	sim.damping = 2.0
	sim.drag = 2.0
	sim.substeps = 16
	sim.iterations = 2
	sim.lay_line(Vector3(-SPAN / 2.0, 0, 0), Vector3(SPAN / 2.0, 0, 0))
	sim.pin(0)
	sim.pin(SEGMENTS)
	for _i in int(SIM_SECONDS / DT):
		sim.step(DT)

	var half_span := SPAN / 2.0
	var a := _solve_catenary_a(half_span, ROPE_LEN / 2.0)
	var w := MASS_PER_M * G
	var sag_ref := a * (cosh(half_span / a) - 1.0)
	var h_ref := w * a
	var t_support_ref := w * a * cosh(half_span / a)
	print("  catenary parameter a = %.3f" % a)

	var lowest := 0.0
	for i in sim.positions.size():
		lowest = minf(lowest, sim.positions[i].y)

	check("settled (max speed m/s)", sim.max_speed(), 0.0, 0.005, true)
	check("length conservation (m)", sim.total_polyline_length(), ROPE_LEN,
			ROPE_LEN * 0.005, true)
	check("sag (m)", -lowest, sag_ref, sag_ref * 0.02)
	check("mid tension H (N)", sim.tensions[SEGMENTS / 2], h_ref, h_ref * 0.05)
	check("support tension (N)", sim.tensions[0], t_support_ref, t_support_ref * 0.05)


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
