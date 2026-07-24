extends "res://addons/ropes/tests/rope_test.gd"
# The three regimes a universal rope has to survive, each asserting the thing
# that regime — and only that regime — is about. Running one scenario three
# times with the SAME assertion would prove nothing three times; the point is
# that air, vacuum and free-fall fail differently, so each is checked for its
# own failure.
#
#   1) 9.8 + air  — a disturbed rope SETTLES. Drag is what a rope in atmosphere
#      has and what most users expect; the swing must decay to rest.
#   2) 9.8 vacuum — energy is CONSERVED: the same swing keeps swinging and does
#      NOT blow up. No drag to hide instability, so this is the honest stability
#      check — if the solver is going to add or lose energy, it shows here.
#   3) 0 g vacuum — no gravity means no sag and no drift: a straight rope stays
#      straight and stationary, and nothing NaNs on the degenerate
#      up = -gravity direction.
#
# Catenary, free-fall and drape are physically specific and are NOT swept
# through all three — a catenary at 0 g is a straight line, not a curve. This
# file owns the cross-regime behaviour; those own their own physics.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_regimes.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const REST_LEN := 4.0
const SEGMENTS := 20
const MASS_PER_M := 0.5
const G := 9.8
const DT := 1.0 / 60.0


func run() -> void:
	title = "REGIMES"
	_earth_atmosphere()
	_earth_vacuum()
	_zero_g_vacuum()


# 1) 9.8 + air: a nudged hanging rope must settle back to rest.
func _earth_atmosphere() -> void:
	print("  1) 9.8 + atmosphere: a disturbed rope settles")
	var sim := _nudged_hang(G, 2.0)  # drag = 2.0 (air)
	var early_ke := _run_and_peak_ke(sim, 0.0, 1.0)
	var late_ke := _run_and_peak_ke(sim, 6.0, 8.0)
	print("  peak KE early=%.4f late=%.4f J" % [early_ke, late_ke])
	# Settled: the swing's kinetic energy has bled away under air.
	var settled := late_ke < early_ke * 0.1
	print("  %s settled under air (late KE %.4f < %.4f = 10%% of early)" %
			["PASS" if settled else "FAIL", late_ke, early_ke * 0.1])
	if not settled:
		failures += 1


# 2) 9.8 vacuum: the same nudge keeps its energy and does not blow up.
func _earth_vacuum() -> void:
	print("  2) 9.8 vacuum: energy conserved — keeps moving, bounded")
	var sim := _nudged_hang(G, 0.0)  # drag = 0 (vacuum)
	var early_ke := _run_and_peak_ke(sim, 0.0, 1.0)
	var late_ke := _run_and_peak_ke(sim, 6.0, 8.0)
	print("  peak KE early=%.4f late=%.4f J" % [early_ke, late_ke])
	# Still moving: without air the swing must NOT have decayed to rest.
	var still_moving := late_ke > early_ke * 0.3
	print("  %s still moving in vacuum (late KE %.4f > %.4f = 30%% of early)" %
			["PASS" if still_moving else "FAIL", late_ke, early_ke * 0.3])
	if not still_moving:
		failures += 1
	# Bounded: peak kinetic energy must not exceed the energy put in — no
	# creation from nothing. (A conservative pendulum's peak KE per cycle is its
	# total mechanical energy above the low point, so it cannot rise above the
	# early peak.)
	var bounded := late_ke < early_ke * 1.2
	print("  %s bounded, not gaining energy (late KE %.4f < %.4f)" %
			["PASS" if bounded else "FAIL", late_ke, early_ke * 1.2])
	if not bounded:
		failures += 1


# 3) 0 g vacuum: a straight free rope stays straight and stationary.
func _zero_g_vacuum() -> void:
	print("  3) 0 g vacuum: straight stays straight, no drift, no NaN")
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3.ZERO
	sim.drag = 0.0
	sim.damping = 0.5
	sim.substeps = 8
	sim.iterations = 2
	# Exactly straight (no manufacturing jitter): the axis it must keep.
	sim.lay_line(Vector3.ZERO, Vector3(REST_LEN, 0, 0), 0.0)
	var com0 := sim.center_of_mass()
	for _i in int(3.0 / DT):
		sim.step(DT)
	# No sag / coil: the polyline is still its rest length end to end.
	check("straight (polyline length m)", sim.total_polyline_length(), REST_LEN, 0.001)
	# No lateral wander and no NaN: every particle stayed on the X axis.
	var off_axis := 0.0
	var finite := true
	for i in sim.positions.size():
		var p: Vector3 = sim.positions[i]
		off_axis = maxf(off_axis, absf(p.y) + absf(p.z))
		finite = finite and is_finite(p.x) and is_finite(p.y) and is_finite(p.z)
	check("stayed on axis (max |y|+|z| m)", off_axis, 0.0, 0.001, true)
	check("centre of mass drift (m)", sim.center_of_mass().distance_to(com0), 0.0, 0.001, true)
	print("  %s all positions finite at 0 g" % ["PASS" if finite else "FAIL"])
	if not finite:
		failures += 1


# A rope hanging straight DOWN from a pinned top, then nudged sideways at the
# bottom — a small perturbation off equilibrium, not a horizontal whip. The
# response is near-linear, so it decays cleanly under air and rings cleanly in
# vacuum, and "did it settle" is a clean question. This whole-body swing is
# what internal damping barely touches (it is Galilean), so damping = 0: the
# only thing that can remove it is the regime under test, not fibre friction.
func _nudged_hang(g: float, drag: float) -> XPBDRope:
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -g, 0)
	sim.stretch_compliance = 0.0
	sim.damping = 0.0
	sim.drag = drag
	sim.substeps = 16
	sim.iterations = 2
	sim.lay_line(Vector3.ZERO, Vector3(0, -REST_LEN, 0), 0.0001)
	sim.pin(0)
	# Let it hang, then a gust: a small uniform sideways velocity on every free
	# particle, so the whole rope swings as one rather than whipping a single
	# light end particle to tens of m/s.
	for _i in int(0.5 / DT):
		sim.step(DT)
	for i in range(1, sim.positions.size()):
		sim.velocities[i] = Vector3(0.5, 0.0, 0.0)
	return sim


## Step from t=from to t=to seconds, returning the peak-to-peak range of the
## centre of mass's sideways position over that window — how far it swings back
## and forth, which is MOTION, not a static lean. A bulk quantity, so unlike
## peak particle speed it is not amplified by the free end whipping, and unlike
## a max-excursion it does not count a rope that settled slightly off-vertical
## as still swinging.
func _run_and_peak_ke(sim: XPBDRope, from: float, to: float) -> float:
	var peak := 0.0
	var steps := int((to - from) / DT)
	for _i in steps:
		sim.step(DT)
		peak = maxf(peak, _kinetic_energy(sim))
	return peak


## Total kinetic energy, sum of 0.5 m v^2 over the dynamic particles. Total, so
## the free end whipping — high speed, tiny mass — barely counts; the bulk swing
## dominates. This is the quantity a vacuum swing conserves and air removes,
## whichever normal mode the energy happens to sit in.
func _kinetic_energy(sim: XPBDRope) -> float:
	var ke := 0.0
	for i in sim.positions.size():
		var w: float = sim.inv_mass[i]
		if w > 0.0:
			ke += 0.5 * (1.0 / w) * sim.velocities[i].length_squared()
	return ke
