extends "res://addons/ropes/tests/rope_test.gd"
# Gate 3 test: the old rope's killer scenario as a regression test.
#
# A free rope (no anchors) is PLACED already draped over a box — 2.99 m
# hanging east, 1.45 m west, the rest lying across the top. Placing it near
# equilibrium is deliberate: dropping from the horizontal pumps meters per
# second of whip into free ends, and in vacuum with no bend dissipation in
# the model that swing is physically entitled to ring for a long time. The
# static claims are what this gate owns:
#   1) the drape settles and does not creep — the old rope on a box never
#      went quiescent and crept ~0.3 m per 5 s. Both diseases, checked in
#      vacuum: no aerodynamic crutch.
#   2) no penetration anywhere,
#   3) the 2.1x weight asymmetry holds (capstan allows ~12x at mu = 0.8),
#   4) tension reads about the weight of the longer hanging side.
# Control: the SAME placed drape with mu = 0 must slide off — falsifying
# accidental always-on friction.
#
# Resolution is 10 cm here on purpose: measured (2026-07-23), frictionless
# flow around TWO sharp corners ratchet-locks at 20 cm spacing (one corner
# is fine even at 20 cm; 10 cm flows). Known discretization artifact —
# friction masks it in practice; see ADR 0006.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_drape.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const REST_LEN := 6.0
const SEGMENTS := 60
const MASS_PER_M := 0.5
const ROPE_RADIUS := 0.03
const G := 9.8
const DT := 1.0 / 60.0
const BOX_HALF := Vector3(0.75, 0.75, 0.75)
const EAST_HANG := 2.99
const WEST_HANG := 1.45


func run() -> void:
	title = "DRAPE"

	print("  A) mu = 0.8: placed drape must settle, hold, not creep")
	var sim := _placed_drape(0.8)
	_run_seconds(sim, 8.0)
	var com_8s := sim.center_of_mass()
	_run_seconds(sim, 4.0)
	check("settled at t=12s (max speed m/s)", sim.max_speed(), 0.0, 0.02, true)
	check("creep between t=8s and t=12s (m)",
			sim.center_of_mass().distance_to(com_8s), 0.0, 0.02, true)

	# Particles are held a full radius off the surface. Segment chords may
	# hug a sharp corner closer than that — the accepted discretization
	# artifact of a coarse rope bent over an edge (ADR 0006) — but must
	# never enter the box.
	var particle_clear := 1e9
	for i in sim.positions.size():
		particle_clear = minf(particle_clear, _box_distance(sim.positions[i]))
	check("particle clearance (m)", particle_clear, ROPE_RADIUS, 0.006, true)
	var chord_clear := 1e9
	for j in SEGMENTS:
		var mid: Vector3 = (sim.positions[j] + sim.positions[j + 1]) * 0.5
		chord_clear = minf(chord_clear, _box_distance(mid))
	print("  chord clearance at corners: %.4f m" % chord_clear)
	if chord_clear < 0.0:
		print("  FAIL a segment chord entered the box")
		failures += 1

	var on_top := 0
	for i in sim.positions.size():
		var p: Vector3 = sim.positions[i]
		if absf(p.x) < BOX_HALF.x and absf(p.z) < BOX_HALF.z and p.y > BOX_HALF.y - 0.1:
			on_top += 1
	print("  particles resting on top: %d" % on_top)
	if on_top < 5:
		print("  FAIL rope did not stay on the box")
		failures += 1

	var hang_weight := EAST_HANG * MASS_PER_M * G
	var max_t := 0.0
	for j in SEGMENTS:
		max_t = maxf(max_t, sim.tensions[j])
	check("peak tension ~ east hang weight (N)", max_t, hang_weight, hang_weight * 0.3)

	print("  B) mu = 0: the same placed drape must slide off")
	var slick := _placed_drape(0.0)
	_run_seconds(slick, 8.0)
	var fell := slick.center_of_mass().y < -1.0
	print("  %s frictionless rope slid off (com.y = %.2f)" %
			["PASS" if fell else "FAIL", slick.center_of_mass().y])
	if not fell:
		failures += 1


func _placed_drape(mu: float) -> XPBDRope:
	var sim := XPBDRope.new()
	sim.setup(SEGMENTS, REST_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.stretch_compliance = 0.0
	sim.damping = 2.0
	sim.drag = 0.0  # vacuum: settling must come from contact + friction
	sim.radius = ROPE_RADIUS
	sim.friction = mu
	sim.substeps = 16
	sim.iterations = 2
	var box := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	sim.colliders = [{
		shape = XPBDRope.SHAPE_BOX,
		params = BOX_HALF,
		xform = box,
		prev_xform = box,
		linear_velocity = Vector3.ZERO,
		angular_velocity = Vector3.ZERO,
	}]
	var wall := BOX_HALF.x + ROPE_RADIUS
	var top := BOX_HALF.y + ROPE_RADIUS
	_lay_polyline(sim, [
		Vector3(-wall, top - WEST_HANG, 0),
		Vector3(-wall, top, 0),
		Vector3(wall, top, 0),
		Vector3(wall, top - EAST_HANG, 0),
	])
	return sim


## Distribute particles evenly by arc length along a polyline.
func _lay_polyline(sim: XPBDRope, points: Array) -> void:
	var total := 0.0
	for k in points.size() - 1:
		total += (points[k + 1] as Vector3).distance_to(points[k])
	var count: int = sim.positions.size()
	for i in count:
		var s := total * float(i) / float(count - 1)
		var walked := 0.0
		var p: Vector3 = points[-1]
		for k in points.size() - 1:
			var a: Vector3 = points[k]
			var b: Vector3 = points[k + 1]
			var seg := a.distance_to(b)
			if s <= walked + seg or k == points.size() - 2:
				p = a.lerp(b, clampf((s - walked) / seg, 0.0, 1.0))
				break
			walked += seg
		sim.positions[i] = p
	sim.prev_positions = sim.positions.duplicate()
	sim.velocities.fill(Vector3.ZERO)


func _run_seconds(sim: XPBDRope, seconds: float) -> void:
	for _i in int(seconds / DT):
		sim.step(DT)


func _box_distance(p: Vector3) -> float:
	var q := p.abs() - BOX_HALF
	var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0))
	return outside.length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
