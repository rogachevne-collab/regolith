extends SceneTree
# Spike I: do AVBD's contact rows hold anything up at all?
#
# The smallest question that has to be answered yes before tests/test_drape.gd
# is worth pointing at this core: drop a rope on a floor, does it stop on the
# floor. Both cores get the identical scene, so the XPBD column is the control
# — if a number looks wrong, the first thing to check is whether it is wrong
# for both, which would make it the scene's fault rather than the solver's.
#
# Reported: clearance (the closest any particle got to the surface, which must
# stay at the rope's radius and never go below it), settle speed, and how far
# the rope drifted sideways once it landed. A rope that lands and then slides
# is a friction bug; a rope that lands and buzzes is the disease from spike B.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_i_avbd_contacts.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const MASS_PER_M := 0.5
const ROPE_LEN := 4.0
const SEGMENTS := 20
const RADIUS := 0.03
const DROP_H := 0.6


func _initialize() -> void:
	print("=== a %.0f m rope dropped %.1f m onto a plane, %d segments, r = %.2f m ==="
			% [ROPE_LEN, DROP_H, SEGMENTS, RADIUS])
	print("clearance must sit AT the radius and never go under it")
	print("%-8s %5s | %10s %10s %10s %9s %9s"
			% ["solver", "mu", "clearance", "worst", "settled", "drift", "us/step"])
	for mu: float in [0.0, 0.6]:
		for which: String in ["XPBD", "AVBD"]:
			_drop(which, mu)
	# The frictionless case sinks and never settles at the floor budget. The
	# contact penalty is derived exactly like a segment's, so if this is the
	# same iteration-count story the length guard already measured, more
	# iterations must fix it — and if they do not, the tolerance is wrong
	# rather than the budget.
	print("\n=== frictionless AVBD, budget swept ===")
	print("%-8s %5s | %10s %10s %10s %9s %9s"
			% ["solver", "iter", "clearance", "worst", "settled", "drift", "us/step"])
	for iters: int in [8, 16, 32, 64]:
		_drop("AVBD", 0.0, iters)
	quit(0)


func _drop(which: String, mu: float, iters := 0) -> void:
	var sim: RefCounted
	if which == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = 16
		sim.iterations = 2
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		sim.iterations = iters if iters > 0 else AVBDRope.ITERATIONS_MIN
		if iters > 0:
			# Sweeping the budget on purpose; the guard would flatten the sweep.
			sim.length_guard = false
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 2.0
	sim.drag = 0.0
	sim.radius = RADIUS
	sim.friction = mu
	# A floor at y = 0, and nothing else in the scene. Typed explicitly: `sim`
	# is RefCounted here so the two cores stay interchangeable, which means the
	# compiler cannot see that the target is Array[Dictionary].
	var floor_plane: Array[Dictionary] = [{
		shape = XPBDRope.SHAPE_PLANE,
		params = Vector3.ZERO,
		xform = Transform3D.IDENTITY,
		prev_xform = Transform3D.IDENTITY,
		linear_velocity = Vector3.ZERO,
		angular_velocity = Vector3.ZERO,
	}]
	sim.colliders = floor_plane
	# Laid flat and slightly tilted, so it lands progressively rather than all
	# at once — an all-at-once landing hides ordering bugs.
	sim.lay_line(Vector3(-ROPE_LEN * 0.5, DROP_H, 0.0),
			Vector3(ROPE_LEN * 0.5, DROP_H + 0.15, 0.0))

	var worst := 1e9
	var usec := 0.0
	var frames := int(6.0 / DT)
	for f in frames:
		var t0 := Time.get_ticks_usec()
		sim.step(DT)
		usec += float(Time.get_ticks_usec() - t0)
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now) or len_now > ROPE_LEN * 20.0:
			print("%-8s %5s | %10s" % [which, mu, "-- DIVERGED --"])
			return
		# Only start watching once it has had time to arrive.
		if f > int(2.0 / DT):
			for i in sim.positions.size():
				worst = minf(worst, sim.positions[i].y)

	var clearance := 1e9
	var landed: PackedVector3Array = sim.positions
	for i in landed.size():
		clearance = minf(clearance, landed[i].y)
	var drift := 0.0
	for i in landed.size():
		drift = maxf(drift, absf(landed[i].z))
	print("%-8s %5s | %10.4f %10.4f %10.4f %9.4f %9.0f"
			% [which, ("%d" % iters) if iters > 0 else ("%.1f" % mu),
				clearance, worst, sim.max_speed(), drift, usec / float(frames)])
