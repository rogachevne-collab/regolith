extends "res://addons/ropes/tests/rope_test.gd"
# Gate 2 test: a rope pulls, it never pushes.
#
# Same setup twice in zero gravity, one number apart — the distance between
# the two pinned ends:
#
#   A) pins at 50% of rest length. Every segment is compressed. A rope must
#      report exactly zero tension and must not move: no spring, no shove.
#   B) pins at 110% of rest length. Every segment is stretched by a known
#      amount, so with a known compliance the tension is analytic:
#      tension = stretch / compliance. The geometry is forced by the pins,
#      which makes this a pure test of the tension readback.
#
# Together they falsify both ways a solver can be wrong here. Deleting the
# unilateral clamp turns the rope into a spring and fails A. Disabling the
# constraint entirely passes A and fails B.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_unilateral.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const REST_LEN := 4.0
const SEGMENTS := 20
const MASS_PER_M := 0.5
const COMPLIANCE := 0.0002
const DT := 1.0 / 60.0
const SETTLE_SECONDS := 4.0


func run() -> void:
	title = "UNILATERAL"

	print("  A) compressed to 50% of rest, zero gravity")
	# 50% of rest is 10 cm per segment, far above the 2*radius = 4 cm floor
	# where the rope's own thickness starts pushing back — so this still
	# isolates the unilateral claim, not self-contact.
	var squashed := _pinned_span(0.5)
	var start := squashed.positions.duplicate()
	for _i in int(SETTLE_SECONDS / DT):
		squashed.step(DT)
	var max_tension := 0.0
	for j in SEGMENTS:
		max_tension = maxf(max_tension, squashed.tensions[j])
	var moved := 0.0
	for i in start.size():
		moved = maxf(moved, start[i].distance_to(squashed.positions[i]))
	check("max tension while compressed (N)", max_tension, 0.0, 0.0, true)
	check("particle motion while compressed (m)", moved, 0.0, 1e-9, true)

	print("  B) stretched to 110% of rest, zero gravity")
	var pulled := _pinned_span(1.1)
	for _i in int(SETTLE_SECONDS / DT):
		pulled.step(DT)
	var seg_rest := REST_LEN / SEGMENTS
	var analytic := (seg_rest * 1.1 - seg_rest) / COMPLIANCE
	var mid: float = pulled.tensions[SEGMENTS / 2]
	check("tension while stretched (N)", mid, analytic, analytic * 0.02)

	var straightness := 0.0
	var a: Vector3 = pulled.positions[0]
	var b: Vector3 = pulled.positions[SEGMENTS]
	for i in SEGMENTS + 1:
		var on_line := a.lerp(b, float(i) / SEGMENTS)
		straightness = maxf(straightness, on_line.distance_to(pulled.positions[i]))
	check("deviation from a straight line (m)", straightness, 0.0, 1e-6, true)


func _pinned_span(span_fraction: float) -> XPBDRope:
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3.ZERO
	sim.stretch_compliance = COMPLIANCE
	sim.damping = 2.0
	sim.drag = 2.0
	sim.substeps = 32
	sim.iterations = 2
	var half := REST_LEN * span_fraction * 0.5
	sim.lay_line(Vector3(-half, 0, 0), Vector3(half, 0, 0))
	sim.pin(0)
	sim.pin(SEGMENTS)
	return sim
