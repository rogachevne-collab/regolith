extends "res://addons/ropes/tests/rope_test.gd"
# Gate 2 test: the AVBD length guard.
#
# AVBD's tension readout has a size envelope and its stretch column does not.
# A 200-segment rope run at the iteration floor reports a tension 172768% high
# while holding its length to 0.5%, so the rope looks perfect and the number
# the addon exists to deliver is nonsense. The guard raises iterations to a
# measured rule (spikes/spike_g_length_guard.gd) and warns when the rule runs
# past the ceiling.
#
# This test pins three things:
#   1. the rule returns the numbers the core documents, so it cannot drift
#      away from the measurement without someone noticing;
#   2. the clamp is inside the core, so the core cannot be driven outside its
#      envelope by a caller who never read the docs;
#   3. the guard actually buys the accuracy it charges for — and the failure
#      it prevents is still there when it is switched off, which is what keeps
#      this test honest if the solver is ever fixed properly.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_length_guard.gd

const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const MASS_PER_M := 0.5
const G := 9.8
const DT := 1.0 / 60.0
const SETTLE_S := 12.0
const WINDOW_S := 3.0
const PAYLOAD := 250.0


func run() -> void:
	title = "LENGTH GUARD"
	_rule()
	_clamp()
	_behavior()


# --- 1. the measured rule ----------------------------------------------------

func _rule() -> void:
	# The four lengths the addon promises, at the node's default 4 segments per
	# metre. These are the numbers in AVBDRope.required_iterations' own cost
	# table; if the constants move, both move together or this fails.
	_exact("5 m free", AVBDRope.required_iterations(20, 5.0, false), 8)
	_exact("20 m free", AVBDRope.required_iterations(80, 20.0, false), 16)
	_exact("50 m free", AVBDRope.required_iterations(200, 50.0, false), 26)
	_exact("100 m free", AVBDRope.required_iterations(400, 100.0, false), 36)
	_exact("5 m loaded", AVBDRope.required_iterations(20, 5.0, true), 16)
	_exact("20 m loaded", AVBDRope.required_iterations(80, 20.0, true), 38)
	_exact("50 m loaded", AVBDRope.required_iterations(200, 50.0, true), 64)
	_exact("100 m loaded", AVBDRope.required_iterations(400, 100.0, true), 98)

	# Fineness, not segment count, is what the rule is about — the whole reason
	# the obvious "iterations >= segments / K" guess had to be thrown away. Two
	# ropes of 200 segments, eight times apart in segment length, must not come
	# out anywhere near equal. (Measured at 16 iterations, the 25 m one reads
	# +10154% and the 200 m one +9.7%.)
	var coarse := AVBDRope.required_iterations(200, 200.0, false)
	var fine := AVBDRope.required_iterations(200, 25.0, false)
	_ok("fineness drives the rule, not segment count (free)",
			fine > coarse * 1.5, "200 segs over 25 m wants %d, over 200 m wants %d"
					% [fine, coarse])
	var coarse_l := AVBDRope.required_iterations(200, 200.0, true)
	var fine_l := AVBDRope.required_iterations(200, 25.0, true)
	_ok("fineness drives the rule, not segment count (loaded)",
			fine_l > coarse_l * 3, "200 segs over 25 m wants %d, over 200 m wants %d"
					% [fine_l, coarse_l])

	# A payload never asks for less.
	var worse := true
	for segs: int in [20, 80, 200, 400]:
		if AVBDRope.required_iterations(segs, float(segs) / 4.0, true) \
				< AVBDRope.required_iterations(segs, float(segs) / 4.0, false):
			worse = false
	_ok("a payload never lowers the requirement", worse, "")

	# Degenerate input must return the floor rather than a NaN budget.
	_exact("floor on a 1-segment rope",
			AVBDRope.required_iterations(1, 100.0, false), AVBDRope.ITERATIONS_MIN)
	_exact("floor on a zero-length rope",
			AVBDRope.required_iterations(0, 0.0, true), AVBDRope.ITERATIONS_MIN)

	# The configuration that has to warn instead of iterate: 20 m at the node's
	# maximum 16 segments per metre, carrying something.
	var past := AVBDRope.required_iterations(320, 20.0, true)
	_ok("a rope past the ceiling is recognized as such",
			past > AVBDRope.ITERATIONS_MAX,
			"wants %d, ceiling is %d" % [past, AVBDRope.ITERATIONS_MAX])
	_ok("and says so", not AVBDRope.guard_warning(320, 20.0, true,
			AVBDRope.ITERATIONS_MAX).is_empty(), "")
	_ok("while a rope inside the envelope stays quiet",
			AVBDRope.guard_warning(200, 50.0, false, 26).is_empty(), "")


# --- 2. the clamp lives in the core -----------------------------------------

func _clamp() -> void:
	var sim := AVBDRope.new()
	sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(200, 50.0, MASS_PER_M)
	_exact("the core raises a 50 m rope on its own", sim.effective_iterations(), 26)

	sim.add_point_mass(200, PAYLOAD)
	_exact("and switches law when something is hung on it",
			sim.effective_iterations(), 64)

	sim.iterations = 80
	_exact("an authored budget above the rule survives",
			sim.effective_iterations(), 80)

	sim.iterations = 2
	sim.length_guard = false
	_exact("the floor of 8 is not negotiable, guard or no guard",
			sim.effective_iterations(), AVBDRope.ITERATIONS_MIN)


# --- 3. it buys what it charges for -----------------------------------------

func _behavior() -> void:
	# 50 m free hanging, 200 segments: the case that reads +172768% at the
	# floor. Both runs are here on purpose — a guard that stopped working and a
	# solver that stopped needing one look identical from the guarded run alone.
	var unguarded := _tension_error(200, 50.0, 0.0, false)
	_ok("unguarded, a 50 m rope still fails the way it always did",
			absf(unguarded) > 100.0, "tension error %+.1f%%" % unguarded)
	var guarded := _tension_error(200, 50.0, 0.0, true)
	check("50 m free hanging, guarded (tension error %)", guarded, 0.0, 10.0, true)

	var loaded := _tension_error(80, 20.0, PAYLOAD, true)
	check("20 m under 250 kg, guarded (tension error %)", loaded, 0.0, 10.0, true)


## Mean tension error of the top segment against the analytic static answer,
## over the last WINDOW_S of a settled hang. Same protocol as spike_f, so the
## numbers here and the numbers in the research note are the same numbers.
func _tension_error(segs: int, length: float, payload: float,
		guard: bool) -> float:
	var sim := AVBDRope.new()
	sim.length_guard = guard
	sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.substeps = 1
	sim.setup(segs, length, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -length, 0))
	sim.pin(0)
	if payload > 0.0:
		sim.add_point_mass(segs, payload)

	var total := int(SETTLE_S / DT)
	var from := total - int(WINDOW_S / DT)
	var tension := 0.0
	var samples := 0
	for f in total:
		sim.step(DT)
		if f >= from:
			tension += sim.tensions[0]
			samples += 1
	var exact := (payload + MASS_PER_M * length) * G
	return (tension / float(samples) / exact - 1.0) * 100.0


func _exact(what: String, measured: int, expected: int) -> void:
	_ok(what, measured == expected, "%d (expected %d)" % [measured, expected])


func _ok(what: String, condition: bool, detail: String) -> void:
	print("  %s %s%s" % ["PASS" if condition else "FAIL", what,
			": " + detail if not detail.is_empty() else ""])
	if not condition:
		failures += 1
