extends SceneTree
# Spike L: does the impulse fix cost Galilean invariance?
#
# The fix for spike_j's divergence clamps each particle's one-step inertial
# guess to MAX_GUESS_STRETCH times its segment length. That bound is on
# ABSOLUTE displacement, so it is also a speed cap: at 60 Hz, 2 x 0.2 m is
# 24 m/s, above which the clamp fires on every particle every step.
#
# A rope at rest and the same rope translating uniformly must obey the same
# physics — that is the principle ADR 0003 protects for damping ("it cannot
# slow a rope that falls as a whole") and ADR 0006 decision 3 exists for (a
# rope inside an accelerating rocket). tests/test_free_fall.gd checks it, but
# only against XPBD, so the gate cannot see this.
#
# Free fall is the clean test: with nothing pinned, the centre of mass must
# follow 1/2 g t^2 exactly, whatever the solver does internally. Anything that
# steals momentum shows up here and nowhere else.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_l_galilean.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const MASS_PER_M := 0.5
const ROPE_LEN := 5.0
const SEGMENTS := 25


func _initialize() -> void:
	var seg := ROPE_LEN / SEGMENTS
	print("=== free fall: centre of mass against 1/2 g t^2 ===")
	print("segment %.3f m, so the guess clamp bites above %.1f m/s"
			% [seg, AVBDRope.MAX_GUESS_STRETCH * seg / DT])
	print("%-8s %7s | %12s %12s %10s %10s"
			% ["solver", "t", "fall", "analytic", "err", "speed"])
	for seconds: float in [1.0, 2.0, 4.0, 8.0]:
		for which: String in ["XPBD", "AVBD"]:
			_fall(which, seconds)

	print("\n=== the same rope, launched sideways at speed ===")
	print("a uniform translation must not change the fall at all")
	print("%-8s %7s | %12s %12s %10s"
			% ["solver", "v m/s", "fall @4s", "analytic", "err"])
	for speed: float in [0.0, 10.0, 30.0, 100.0]:
		for which: String in ["XPBD", "AVBD"]:
			_fall(which, 4.0, speed)
	quit(0)


func _fall(which: String, seconds: float, launch := 0.0) -> void:
	var sim: RefCounted
	if which == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = 32
		sim.iterations = 1
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	# No damping of any kind: both are Galilean invariant by design, so they
	# cannot change this answer, and leaving them out removes the argument.
	sim.damping = 0.0
	sim.drag = 0.0
	sim.lay_line(Vector3(-ROPE_LEN * 0.5, 0.0, 0.0), Vector3(ROPE_LEN * 0.5, 0.0, 0.0))
	if launch != 0.0:
		for i in sim.positions.size():
			sim.velocities[i] = Vector3(launch, 0.0, 0.0)

	var start: Vector3 = sim.center_of_mass()
	var frames := int(seconds / DT)
	for _f in frames:
		sim.step(DT)
	var fell: float = start.y - (sim.center_of_mass() as Vector3).y
	var t := float(frames) * DT
	var exact := 0.5 * G * t * t
	if launch != 0.0:
		print("%-8s %7.0f | %12.5f %12.5f %9.3f%%"
				% [which, launch, fell, exact, (fell / exact - 1.0) * 100.0])
	else:
		print("%-8s %7.1f | %12.5f %12.5f %9.3f%% %10.2f"
				% [which, t, fell, exact, (fell / exact - 1.0) * 100.0,
					sim.max_speed()])
