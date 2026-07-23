extends "res://addons/ropes/tests/rope_test.gd"
# Gate 2 test: compliance is a physical quantity in m/N.
#
# XPBD's defining relation is that at equilibrium the constraint violation
# equals compliance times the constraint force:
#
#     measured_length - rest_length  ==  compliance * tension
#
# We hang a weight on a compliant rope and check that identity for EVERY
# segment at once. Because tension varies along a hanging rope (each segment
# carries what hangs below it), one run samples the relation across a range
# of forces.
#
# This is the test the suite was missing: with compliance = 0 the alpha term
# in the solver is never executed, so nothing pinned it, and nothing proved
# that the number in the inspector means meters per Newton.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_compliance.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const REST_LEN := 4.0
const SEGMENTS := 20
const MASS_PER_M := 0.5
const END_MASS := 10.0
const COMPLIANCE := 0.0002
const G := 9.8
const DT := 1.0 / 60.0
const SETTLE_SECONDS := 8.0


func run() -> void:
	title = "COMPLIANCE"

	var sim := _hang(COMPLIANCE)
	var seg_rest := REST_LEN / SEGMENTS
	var worst_rel := 0.0
	var worst_seg := -1
	for j in SEGMENTS:
		var measured: float = sim.positions[j].distance_to(sim.positions[j + 1])
		var predicted: float = seg_rest + COMPLIANCE * sim.tensions[j]
		var rel: float = absf(measured - predicted) / maxf(absf(measured - seg_rest), 1e-9)
		if rel > worst_rel:
			worst_rel = rel
			worst_seg = j
	print("  worst segment #%d, tension range %.1f..%.1f N" %
			[worst_seg, sim.tensions[SEGMENTS - 1], sim.tensions[0]])
	check("stretch == compliance * tension, worst rel. error",
			worst_rel, 0.0, 0.01, true)

	# The relation must hold in the aggregate too, not only per segment.
	var total := sim.total_polyline_length()
	var predicted_total := REST_LEN
	for j in SEGMENTS:
		predicted_total += COMPLIANCE * sim.tensions[j]
	check("total length (m)", total, predicted_total, predicted_total * 0.002)

	# Control: the knob must actually do something. A rigid rope of the same
	# setup may not stretch anywhere near as much.
	var rigid := _hang(0.0)
	var rigid_stretch: float = rigid.total_polyline_length() - REST_LEN
	var soft_stretch: float = total - REST_LEN
	print("  stretch: compliant %.4f m vs rigid %.4f m" % [soft_stretch, rigid_stretch])
	if soft_stretch < rigid_stretch * 10.0:
		print("  FAIL compliance had no effect")
		failures += 1
	else:
		print("  PASS compliance changes the answer (%.0fx)" %
				(soft_stretch / maxf(rigid_stretch, 1e-9)))


func _hang(compliance: float) -> XPBDRope:
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.stretch_compliance = compliance
	sim.damping = 2.0
	sim.drag = 2.0
	sim.substeps = 32
	sim.iterations = 2
	sim.add_point_mass(SEGMENTS, END_MASS)
	sim.lay_line(Vector3.ZERO, Vector3(0, -REST_LEN, 0))
	sim.pin(0)
	for _i in int(SETTLE_SECONDS / DT):
		sim.step(DT)
	return sim
