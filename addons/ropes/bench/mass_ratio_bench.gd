extends SceneTree
# Baseline for the mass-ratio question (docs/research/mass-ratio-state-of-
# the-art.md): how far can plain XPBD be pushed by spending substeps, and
# what does it cost?
#
# A 4 m / 2 kg rope hangs from one pin with a payload on its end. We let it
# settle, then measure steady-state stretch against rest length and the cost
# of one step. Any candidate replacement must be compared against this table
# at equal cost, not at equal iteration count.
#
# Run: godot --headless --path . -s addons/ropes/bench/mass_ratio_bench.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const REST_LEN := 4.0
const SEGMENTS := 20
const MASS_PER_M := 0.5   # -> 2 kg of rope
const G := 9.8
const DT := 1.0 / 60.0
const SETTLE_SECONDS := 3.0
const TIMED_STEPS := 60

const PAYLOADS := [2.0, 20.0, 200.0, 2000.0]
const SUBSTEPS := [8, 16, 32, 64]


func _initialize() -> void:
	var rope_mass := MASS_PER_M * REST_LEN
	print("Baseline: %.1f m rope, %.1f kg, %d segments, g=%.2f, %d Hz" %
			[REST_LEN, rope_mass, SEGMENTS, G, int(1.0 / DT)])
	print("Stretch % of rest length at steady state (cost = usec/step)")
	print("")
	var header := "payload    ratio  "
	for s in SUBSTEPS:
		header += "  sub=%-14s" % s
	print(header)

	for payload: float in PAYLOADS:
		var line := "%7.0f kg %6.0f:1 " % [payload, payload / rope_mass]
		for substeps: int in SUBSTEPS:
			var r := _measure(payload, substeps)
			line += "  %6.2f%% %7.1fus" % [r.stretch * 100.0, r.usec]
		print(line)

	print("")
	print("Reference: a real steel cable at these loads stretches well under 1%.")
	quit(0)


func _measure(payload: float, substeps: int) -> Dictionary:
	var sim := _make(payload, substeps)
	for _i in int(SETTLE_SECONDS / DT):
		sim.step(DT)
	var stretch: float = sim.total_polyline_length() / REST_LEN - 1.0

	# Cost on a settled rope: the steady state is what a game pays for.
	var t0 := Time.get_ticks_usec()
	for _i in TIMED_STEPS:
		sim.step(DT)
	var usec := float(Time.get_ticks_usec() - t0) / TIMED_STEPS
	return {stretch = stretch, usec = usec}


func _make(payload: float, substeps: int) -> XPBDRope:
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.stretch_compliance = 0.0
	sim.damping = 2.0
	sim.drag = 2.0
	sim.substeps = substeps
	sim.iterations = 1
	sim.add_point_mass(SEGMENTS, payload)
	sim.lay_line(Vector3.ZERO, Vector3(0, -REST_LEN, 0))
	sim.pin(0)
	return sim
