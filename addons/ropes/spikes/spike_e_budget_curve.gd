extends SceneTree
# Spike E: is a second solver ever worth shipping, or does one budget dial do?
#
# The only regime where XPBD still looked attractive is cost: a decorative rope
# in the background does not need a correct tension readout, and XPBD at 8
# substeps is ~5x cheaper than AVBD at 16 iterations. But that is an argument
# for a cheaper SETTING, not for a second solver — unless AVBD refuses to scale
# down. So: sweep each solver's own quality dial and put cost next to quality.
#
# Two ropes: one decorative (no payload, nobody reads its tension) and one
# load-bearing (250 kg, the rover case). Measured over the last 5 s of 15 s.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_e_budget_curve.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const ROPE_LEN := 5.0
const MASS_PER_M := 0.5
const SEGMENTS := 25
const RUN_S := 15.0
const WINDOW_S := 5.0


func _initialize() -> void:
	for payload: float in [0.0, 250.0]:
		var what := "decorative (no payload)" if payload == 0.0 else "load-bearing (250 kg)"
		print("\n=== %s, %d segments ===" % [what, SEGMENTS])
		print("%-18s | %9s | %8s | %8s | %9s"
				% ["config", "us/step", "stretch", "jitter", "tension err"])
		for sub: int in [4, 8, 16, 32]:
			_run("XPBD sub=%d" % sub, "XPBD", sub, payload)
		for it: int in [2, 4, 8, 16]:
			_run("AVBD iter=%d" % it, "AVBD", it, payload)
	quit(0)


func _run(label: String, solver: String, budget: int, payload: float) -> void:
	var sim: RefCounted
	if solver == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = budget
		sim.iterations = 1
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		# The budget IS what this spike sweeps, so the length guard has to stay
		# out of it — on, it would pull every row up to the same number and the
		# curve would be a flat line that proved nothing.
		sim.length_guard = false
		sim.iterations = budget
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -ROPE_LEN, 0))
	sim.pin(0)
	if payload > 0.0:
		sim.add_point_mass(SEGMENTS, payload)

	var total := int(RUN_S / DT)
	var from := total - int(WINDOW_S / DT)
	var stretch := 0.0
	var motion := 0.0
	var tension := 0.0
	var samples := 0
	var usec := 0.0
	var prev: PackedVector3Array = sim.positions.duplicate()

	for f in total:
		var t0 := Time.get_ticks_usec()
		sim.step(DT)
		var used := float(Time.get_ticks_usec() - t0)
		var curr: PackedVector3Array = sim.positions
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now) or len_now > ROPE_LEN * 20.0:
			print("%-18s | %9s" % [label, "DIVERGED"])
			return
		if f >= from:
			stretch += len_now / ROPE_LEN - 1.0
			var m := 0.0
			for i in curr.size():
				m += (curr[i] - prev[i]).length()
			motion += m / float(curr.size())
			tension += sim.tensions[0]
			usec += used
			samples += 1
		prev = curr.duplicate()

	var exact := (payload + MASS_PER_M * ROPE_LEN) * G
	print("%-18s | %9.0f | %7.3f%% | %6.2fmm | %+8.1f%%"
			% [label, usec / samples, stretch / samples * 100.0,
				motion / samples * 1000.0, (tension / samples / exact - 1.0) * 100.0])
