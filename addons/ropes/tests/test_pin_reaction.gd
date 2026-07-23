extends "res://addons/ropes/tests/rope_test.gd"
## Gate 4: pin reaction force matches segment tension on a loaded free end.

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const REST_LEN := 4.0
const SEGMENTS := 16
const PAYLOAD_KG := 50.0
const G := 9.8
const SUBSTEPS := 32
const DT := 1.0 / 60.0
const SETTLE_TICKS := 240


func run() -> void:
	title = "test_pin_reaction"
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, REST_LEN, 0.5)
	sim.gravity = Vector3(0.0, -G, 0.0)
	sim.substeps = SUBSTEPS
	sim.iterations = 2
	sim.lay_line(Vector3(0.0, 8.0, 0.0), Vector3(0.0, 4.0, 0.0))
	sim.pin(0)
	sim.add_point_mass(SEGMENTS, PAYLOAD_KG)
	for _i in SETTLE_TICKS:
		sim.step(DT)
	var expected := PAYLOAD_KG * G
	var reaction_y := sim.pin_reaction_force(0).y
	check("pin_reaction_y", reaction_y, expected, expected * 0.15)
	check(
		"endpoint_tension",
		sim.endpoint_tension_n(),
		expected,
		expected * 0.15
	)
	check("free_end_settled", sim.positions[SEGMENTS].y, 4.0, 0.5, true)
