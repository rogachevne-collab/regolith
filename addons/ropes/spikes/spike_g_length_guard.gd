extends SceneTree
# Spike G: how many iterations does AVBD need before its tension readout can be
# believed, as a function of chain length?
#
# Spike F found the wall but not its shape: at 16 iterations the tension error
# is -2.0% at 20 segments, +14% at 200 and +947% at 400, and under a 250 kg
# payload it arrives far sooner (+60% at 80). Stretch stays excellent
# throughout, so the failure is invisible in every column but this one. ADR 0007
# says the bound has to be established by measurement, so this is the
# measurement.
#
# Working hypothesis (from the paper's own limitations section): the primal step
# is Gauss-Seidel, information crosses the chain at a bounded rate, so what
# matters is SEGMENTS PER PRIMAL SWEEP and the requirement is
#
#     iterations >= segments / K
#
# for some K to be found here, separately for a loaded and an unloaded rope.
#
# RESULT: that hypothesis is wrong, and part A is what kills it. Segment count
# is a weak second-order term; the variable is FINENESS, M = segments /
# segment_length. The rule that shipped is AVBDRope.required_iterations().
#
# Two things have to be established before any rule can be trusted:
#
#   Part A — is the wall in SEGMENTS or in METRES? If it is metres, no amount of
#            iterations fixes a 100 m rope and the guard has to refuse instead
#            of scale. Two controls: fixed segment count over 25..200 m, and
#            fixed length at 1..8 segments per metre.
#   Part B — the ladder. For each rope, walk iterations upward and record where
#            the error crosses 10% and 5%. Three sets, selected by argument:
#            b1 separates fineness from segment count at a low particle count
#            (cheap and decisive), b2 is the four acceptance lengths at the
#            node's default resolution, b3 is the expensive corners.
#
# Everything is measured the way spike F measures it (12 s settle, mean over the
# last 3 s, tension of the TOP segment against the analytic static answer
# (payload + mass_per_m * length) * g), so the numbers drop straight into the
# same table.
#
# One part per run: the corners take minutes each, and this project hangs if two
# headless instances are up at once.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_g_length_guard.gd
#      ... -- part=a    (the controls; b1 / b2 / b3 for the ladders)

const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const MASS_PER_M := 0.5
const SIM_S := 12.0
const WINDOW_S := 3.0
const PAYLOAD := 250.0

## Iteration ladder. Starts at 8 because ADR 0007 forbids going below it for
## unrelated reasons (the multiplier has not converged at all down there).
const LADDER := [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256]

## Skip a probe estimated to cost more than this. GDScript reference core, so
## a 400-particle chain at 256 iterations is ~13 minutes of wall clock for one
## data point and the answer is already known to be "warn, not iterate".
const MAX_PROBE_S := 150.0
## Measured on this machine, part A: 10037 us/step at 201 particles x 16
## iterations = 3.1 us per particle-sweep.
const USEC_PER_PARTICLE_SWEEP := 3.1

## (length m, segments per metre). Grouped so the cheap, decisive probes run
## first: b1 varies resolution at a low segment count, which separates
## "segments" from "segment length" for good.
const CONFIGS := {
	"b1": [
		[5.0, 4.0],    # 20 segs, 0.25 m   — the operating point, M = 80
		[5.0, 8.0],    # 40 segs, 0.125 m  — M = 320
		[5.0, 16.0],   # 80 segs, 0.0625 m — M = 1280, a SHORT rope at high M
		[20.0, 1.0],   # 20 segs, 1.0 m    — M = 20
		[100.0, 1.0],  # 100 segs, 1.0 m   — M = 100, a LONG rope at low M
		[10.0, 8.0],   # 80 segs, 0.125 m  — M = 640
	],
	"b2": [
		[5.0, 4.0],    # 20 segs   — the four acceptance lengths at the
		[20.0, 4.0],   # 80 segs     default resolution
		[50.0, 4.0],   # 200 segs
		[100.0, 4.0],  # 400 segs
	],
	"b3": [
		[50.0, 2.0],   # 100 segs, 0.5 m   — M = 200
		[25.0, 8.0],   # 200 segs, 0.125 m — M = 1600, same M as 100 m at 4/m
		[50.0, 8.0],   # 400 segs, 0.125 m — M = 3200, the worst plausible rope
	],
}


func _initialize() -> void:
	var parts := "ab"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("part="):
			parts = a.substr(5)
	if parts.contains("a"):
		_part_a()
	for key: String in ["b1", "b2", "b3"]:
		if parts.contains(key):
			_part_b(key)
	quit(0)


# --- Part A: segments or metres? -------------------------------------------

func _part_a() -> void:
	print("=== control 1: 200 segments held fixed, length varied (iter=16) ===")
	print("if the error is flat, the wall is in SEGMENTS and iterations can fix it")
	print("%8s %6s %7s | %10s %9s %9s"
			% ["length", "segs", "seg/m", "T err", "stretch", "us/step"])
	for length: float in [25.0, 50.0, 100.0, 200.0]:
		for payload: float in [0.0, PAYLOAD]:
			var r := _probe(200, length, payload, 16)
			_row(length, 200, payload, r)

	print("\n=== control 2: 50 m held fixed, resolution varied (iter=16) ===")
	print("if the error grows with seg/m, refinement alone breaks the readout")
	print("%8s %6s %7s | %10s %9s %9s"
			% ["length", "segs", "seg/m", "T err", "stretch", "us/step"])
	for segs: int in [50, 100, 200, 400]:
		for payload: float in [0.0, PAYLOAD]:
			var r := _probe(segs, 50.0, payload, 16)
			_row(50.0, segs, payload, r)


func _row(length: float, segs: int, payload: float, r: Dictionary) -> void:
	print("%7.0fm %6d %7.1f | %+9.1f%% %8.3f%% %9.0f  %s"
			% [length, segs, float(segs) / length, r.err, r.stretch, r.usec,
				"free" if payload == 0.0 else "%.0f kg" % payload])


# --- Part B: the ladder -----------------------------------------------------

func _part_b(key: String) -> void:
	for payload: float in [0.0, PAYLOAD]:
		print("\n=== %s: minimum iterations, %s ===" % [key,
				"free hanging" if payload == 0.0 else "%.0f kg payload" % payload])
		print("M = segments / segment_length = segments^2 / length — part A says")
		print("this, not the segment count, is what orders the failures.")
		print("%6s %7s %6s %7s %6s | %10s %9s %8s %9s"
				% ["segs", "length", "seg m", "M", "iters", "T err", "stretch",
					"speed", "us/step"])
		var summary: Array[String] = []
		for cfg: Array in CONFIGS[key]:
			var length: float = cfg[0]
			var segs := int(round(length * float(cfg[1])))
			var seg_m := length / float(segs)
			var m_metric := float(segs) / seg_m
			var at10 := 0
			var at5 := 0
			for iters: int in LADDER:
				var est := USEC_PER_PARTICLE_SWEEP * (segs + 1) * iters \
						* (SIM_S / DT) / 1e6
				if est > MAX_PROBE_S:
					print("%6d %6.0fm %6.3f %7.0f %6d | %10s (est %.0f s)"
							% [segs, length, seg_m, m_metric, iters, "skipped", est])
					break
				var r := _probe(segs, length, payload, iters)
				print("%6d %6.0fm %6.3f %7.0f %6d | %+9.1f%% %8.3f%% %7.4f %9.0f"
						% [segs, length, seg_m, m_metric, iters, r.err, r.stretch,
							r.speed, r.usec])
				var e: float = absf(r.err)
				if at10 == 0 and e <= 10.0:
					at10 = iters
				if e <= 5.0:
					at5 = iters
					break
			# If M is the right variable, M / iterations is constant down this
			# column whatever the segment count and length were.
			summary.append("%6d %6.0fm M=%-6.0f | <=10%% at %s (M/it=%s) | <=5%% at %s (M/it=%s)"
					% [segs, length, m_metric,
						"%4d" % at10 if at10 > 0 else "  --",
						"%6.1f" % (m_metric / at10) if at10 > 0 else "    --",
						"%4d" % at5 if at5 > 0 else "  --",
						"%6.1f" % (m_metric / at5) if at5 > 0 else "    --"])
		print("  -- crossings, %s --" % ["free" if payload == 0.0 else "loaded"])
		for s: String in summary:
			print("  " + s)


# --- shared -----------------------------------------------------------------

func _probe(segs: int, length: float, payload: float, iters: int) -> Dictionary:
	var sim := AVBDRope.new()
	# The core clamps iterations up to whatever the guard demands; this spike is
	# what MEASURES the guard, so it is the one caller allowed below it. The
	# floor of 8 still applies — the ladder starts there anyway.
	sim.length_guard = false
	sim.substeps = 1
	sim.iterations = iters
	sim.setup(segs, length, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -length, 0))
	sim.pin(0)
	if payload > 0.0:
		sim.add_point_mass(segs, payload)

	var total := int(SIM_S / DT)
	var from := total - int(WINDOW_S / DT)
	var stretch := 0.0
	var tension := 0.0
	var usec := 0.0
	var samples := 0
	for f in total:
		var t0 := Time.get_ticks_usec()
		sim.step(DT)
		var used := float(Time.get_ticks_usec() - t0)
		var len_now: float = sim.total_polyline_length()
		if not is_finite(len_now) or len_now > length * 20.0:
			return {"err": INF, "stretch": INF, "usec": 0.0, "speed": INF}
		if f >= from:
			stretch += len_now / length - 1.0
			tension += sim.tensions[0]
			usec += used
			samples += 1

	var exact := (payload + MASS_PER_M * length) * G
	return {
		"err": (tension / samples / exact - 1.0) * 100.0,
		"stretch": stretch / samples * 100.0,
		"usec": usec / samples,
		# Steady state is the claim being made; a rope still moving at the end
		# of the window has not earned the word and its tension is a transient.
		"speed": sim.max_speed(),
	}
