extends SceneTree
# Spike C: XPBD vs AVBD at the OPERATING POINT, not at a stunt ratio.
#
# docs/research/mass-ratio-state-of-the-art.md fixes the target: a rover on a
# cable is ~100:1 payload-to-rope, and XPBD's stretch falls off as the square
# of the substep count (32 substeps -> 2.6%, 64 -> 0.65%). So the question is
# not "does XPBD explode at 50,000:1" (it does, and so does everything else),
# it is "at 100:1, what does AVBD buy over XPBD at its own recommended
# budget" — and the answer decides whether porting AVBD is worth anything.
#
# Both solvers run the identical contract, 1/60 s, damping and drag off.
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_c_solver_shootout.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")
const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const SEGMENTS := 50
const ROPE_LEN := 5.0
const MASS_PER_M := 0.5          # 2.5 kg of rope
const FRAMES := 120
const BLOWN := 10.0              # 1000% stretch: gone, stop wasting time


func _initialize() -> void:
	for ratio: float in [20.0, 100.0, 500.0]:
		var load_kg: float = MASS_PER_M * ROPE_LEN * ratio
		print("\n=== payload %.0f kg on %.1f kg of rope (%.0f:1), %d segments ==="
				% [load_kg, MASS_PER_M * ROPE_LEN, ratio, SEGMENTS])
		print("%-30s | %10s %10s | %9s | %8s"
				% ["config", "max str %", "end str %", "T err %", "ms/frame"])
		for cfg in _configs():
			_run(cfg, load_kg)
	quit(0)


func _configs() -> Array:
	return [
		{"s": "XPBD", "sub": 8, "it": 1},
		{"s": "XPBD", "sub": 32, "it": 1},
		{"s": "XPBD", "sub": 64, "it": 1},
		{"s": "AVBD", "it": 8, "b": 1.0e4, "de": 1},
		{"s": "AVBD", "it": 8, "b": 1.0e6, "de": 1},
		{"s": "AVBD", "it": 20, "b": 1.0e6, "de": 1},
		{"s": "AVBD", "it": 20, "b": 1.0e6, "de": 5},
	]


func _label(cfg: Dictionary) -> String:
	if cfg.s == "XPBD":
		return "XPBD sub=%d it=%d" % [cfg.sub, cfg.it]
	return "AVBD it=%d beta=%.0f dual/%d" % [cfg.it, cfg.b, cfg.de]


func _run(cfg: Dictionary, load_kg: float) -> void:
	var sim: RefCounted
	if cfg.s == "XPBD":
		sim = XPBDRope.new()
		sim.substeps = cfg.sub
		sim.iterations = cfg.it
	else:
		sim = AVBDRope.new()
		sim.substeps = 1
		sim.iterations = cfg.it
		sim.dual_every = cfg.de
		sim.beta = cfg.b
		sim.penalty_start = 1.0
		sim.alpha = 0.95
		sim.gamma = 0.99
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.0
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0, -ROPE_LEN, 0))
	sim.pin(0)
	sim.add_point_mass(SEGMENTS, load_kg)

	var max_s := 0.0
	var t0 := Time.get_ticks_usec()
	var done := 0
	for _f in FRAMES:
		sim.step(DT)
		done += 1
		var s: float = sim.total_polyline_length() / ROPE_LEN - 1.0
		if not is_finite(s) or s > BLOWN:
			print("%-30s | %10s" % [_label(cfg), "DIVERGED"])
			return
		max_s = maxf(max_s, s)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / float(done)
	var exact := (load_kg + MASS_PER_M * ROPE_LEN) * G
	print("%-30s | %10.4f %10.4f | %9.2f | %8.3f"
			% [_label(cfg), max_s * 100.0,
				(sim.total_polyline_length() / ROPE_LEN - 1.0) * 100.0,
				(sim.tensions[0] / exact - 1.0) * 100.0, ms])
