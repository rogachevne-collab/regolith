extends SceneTree
# Spike D: why does AVBD bounce under a heavy payload?
#
# Observed by eye in demos/avbd_shootout.tscn: at 250 kg and 1250 kg the AVBD
# rope swings vertically with a large amplitude and never settles, while XPBD
# at 32 substeps calms down. The stretch table missed it because the average
# looked fine; the amplitude is the symptom.
#
# Suspected cycle: penalty too small -> the rope acts as a soft spring ->
# it overshoots -> the segment goes slack -> the unilateral clamp ZEROES the
# multiplier -> the holding force is lost -> free fall -> the rope catches
# again. If that is it, raising beta (which grows the penalty, so the
# correction is stiff enough not to overshoot into slack) should kill it.
#
# Measures the last 5 s of a 20 s run, when a working solver is settled.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_d_payload_bounce.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const ROPE_LEN := 5.0
const MASS_PER_M := 0.5
const SEGMENTS := 25          # 5 per metre, as in the bench and the demo
const RUN_S := 20.0
const WINDOW_S := 5.0         # the tail that must be quiet


func _initialize() -> void:
	for payload: float in [250.0, 1250.0]:
		print("\n=== %.0f kg on %.1f kg of rope (%.0f:1), exact static tension %.0f N ==="
				% [payload, MASS_PER_M * ROPE_LEN, payload / (MASS_PER_M * ROPE_LEN),
					(payload + MASS_PER_M * ROPE_LEN) * G])
		print("%-28s | %9s | %8s %8s | %8s | %9s"
				% ["config", "amplitude", "min str", "max str", "jitter", "tension"])
		_run({t = "XPBD sub=32", solver = "XPBD", sub = 32}, payload)
		for de: int in [2, 4]:
			for b: float in [1.0e4, 1.0e5, 1.0e6, 1.0e7]:
				# GDScript's % has no %e conversion; log10 keeps the label short.
				_run({t = "AVBD beta=1e%d de=%d" % [int(round(log(b) / log(10.0))), de],
						solver = "AVBD", b = b, de = de}, payload)
	quit(0)


func _run(cfg: Dictionary, payload: float) -> void:
	var sim: RefCounted
	if cfg.solver == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = cfg.sub
		sim.iterations = 1
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		# Fixed at 16 across every row so beta and dual_every are the only things
		# varying; the length guard would raise it for the loaded rows only and
		# the comparison would stop being one.
		sim.length_guard = false
		sim.iterations = 16
		sim.dual_every = cfg.de
		sim.beta_override = cfg.b
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -ROPE_LEN, 0))
	sim.pin(0)
	sim.add_point_mass(SEGMENTS, payload)

	var total := int(RUN_S / DT)
	var from := total - int(WINDOW_S / DT)
	var y_min := INF
	var y_max := -INF
	var s_min := INF
	var s_max := -INF
	var motion := 0.0
	var tension := 0.0
	var samples := 0
	var prev: PackedVector3Array = sim.positions.duplicate()

	for f in total:
		sim.step(DT)
		var curr: PackedVector3Array = sim.positions
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now) or len_now > ROPE_LEN * 20.0:
			print("%-28s | %9s" % [cfg.t, "DIVERGED"])
			return
		if f >= from:
			var y: float = curr[SEGMENTS].y
			y_min = minf(y_min, y)
			y_max = maxf(y_max, y)
			var s := len_now / ROPE_LEN - 1.0
			s_min = minf(s_min, s)
			s_max = maxf(s_max, s)
			var m := 0.0
			for i in curr.size():
				m += (curr[i] - prev[i]).length()
			motion += m / float(curr.size())
			tension += sim.tensions[0]
			samples += 1
		prev = curr.duplicate()

	var exact := (payload + MASS_PER_M * ROPE_LEN) * G
	print("%-28s | %8.3fm | %7.2f%% %7.2f%% | %6.2fmm | %8.0fN (%+.0f%%)"
			% [cfg.t, y_max - y_min, s_min * 100.0, s_max * 100.0,
				motion / samples * 1000.0, tension / samples,
				(tension / samples / exact - 1.0) * 100.0])
