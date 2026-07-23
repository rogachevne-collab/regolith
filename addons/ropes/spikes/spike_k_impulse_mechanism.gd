extends SceneTree
# Spike K: what a violent single impulse actually does inside AVBD, frame by
# frame — the instrumentation that found the mechanism behind the divergence
# in spike_j_impulse.gd, and now the record that the fix addresses it.
#
# 100 N*s on the middle particle of a bare 5 m, 25-segment rope (particle mass
# 0.1 kg) is a 1000 m/s kick. Before the fix (core/avbd_rope.gd's
# MAX_GUESS_STRETCH), that single hit sent the hit particle's one-step
# inertial guess (velocities[i] * h, h = 1/60 s) 16.7 m past its neighbour —
# eighty times the segment's own 0.2 m rest length — and the constraint
# machinery had no way to treat that as anything but a real, enormous
# constraint violation: lambdas[j] spiked off it, beta is derived proportional
# to lambda (_beta_for), so the penalty ramp spiked with it, hit
# PENALTY_MAX within 3 frames, and the rope never recovered (see ADR history /
# the task that produced this file for the un-fixed numbers).
#
# What is printed below, on an unpatched core, would show penalties and
# lambdas racing to their absolute ceilings in single-digit frames and
# total_polyline_length climbing without bound. On the fixed core it stays
# bounded: a visible peak stretch, then recovery, matching what
# spike_j_impulse.gd's threshold table now reports (this exact case is one of
# its "ok" cells).
#
# Run: godot --headless --path . -s addons/ropes/spikes/spike_k_impulse_mechanism.gd

const AVBDRope := preload("res://addons/ropes/core/avbd_rope.gd")

const DT := 1.0 / 60.0
const G := 9.8
const MASS_PER_M := 0.5
const ROPE_LEN := 5.0
const SEGMENTS := 25
const HIT_IMPULSE := 100.0
const HIT_PARTICLE := SEGMENTS / 2
const PAYLOAD := 0.0
const FRAMES_TO_PRINT := 20


func _initialize() -> void:
	var sim := AVBDRope.new()
	sim.substeps = 1
	sim.iterations = AVBDRope.ITERATIONS_MIN
	sim.setup(SEGMENTS, ROPE_LEN, MASS_PER_M)
	sim.gravity = Vector3(0, -G, 0)
	sim.damping = 0.5
	sim.drag = 0.0
	sim.lay_line(Vector3.ZERO, Vector3(0.0001, -ROPE_LEN, 0))
	sim.pin(0)
	if PAYLOAD > 0.0:
		sim.add_point_mass(SEGMENTS, PAYLOAD)

	for _f in int(4.0 / DT):
		sim.step(DT)

	var h := DT / float(sim.substeps)
	var m_particle: float = 1.0 / sim.inv_mass[HIT_PARTICLE]
	var m_over_h2 := m_particle / (h * h)
	print("settled. particle %d mass = %.4f kg, m/h^2 = %.3f N/m"
			% [HIT_PARTICLE, m_particle, m_over_h2])

	sim.apply_impulse(HIT_PARTICLE, Vector3(HIT_IMPULSE, 0.0, 0.0))
	print("impulse %.0f N*s -> dv = %.2f m/s; guess displacement dv*h = %.2f m"
			% [HIT_IMPULSE, HIT_IMPULSE / m_particle,
				(HIT_IMPULSE / m_particle) * h])
	print("(a bare segment is %.2f m, so an unclamped guess would be %.0fx that)"
			% [ROPE_LEN / SEGMENTS,
				((HIT_IMPULSE / m_particle) * h) / (ROPE_LEN / SEGMENTS)])

	print("\n%-5s %-14s %-14s %-14s %-14s %-12s"
			% ["frame", "lam[j-1]", "lam[j]", "pen[j-1]", "pen[j]", "len_now"])
	for f in FRAMES_TO_PRINT:
		sim.step(DT)
		var j := HIT_PARTICLE
		var jm1 := HIT_PARTICLE - 1
		print("%-5d %-14.4f %-14.4f %-14.4f %-14.4f %-12.4f"
				% [f, sim.lambdas[jm1], sim.lambdas[j], sim.penalties[jm1],
					sim.penalties[j], sim.total_polyline_length()])
		if not is_finite(sim.total_polyline_length()):
			print("NOT FINITE — the mechanism is back, or a new one showed up.")
			break
	quit(0)
