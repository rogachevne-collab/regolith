extends "res://addons/ropes/tests/rope_test.gd"
# A settled hung load must report its own weight as tension — and the segments
# above it must each carry the weight hanging below them. This exists because
# the number was believed broken: measured on the gate5 lift bench the tension
# read a fraction of the load and swung wildly, and the README called it an
# under-report. It was a mis-diagnosis. That bench lifts a rover by an
# off-centre hook, so the load SWINGS, and a swinging load's tension genuinely
# ranges from below mg (at the extremes) to above it (at the bottom) — physics,
# not a solver fault. Settle the same load with no swing and the readout is
# exact. This test is that settled case, so the mis-diagnosis cannot come back.
#
# Run: godot --headless --path . -s addons/ropes/tests/test_hang_tension.gd

const XPBDRope := preload("res://addons/ropes/core/xpbd_rope.gd")

const REST := 4.0
const SEG := 20
const MPM := 0.5
const G := 9.8
const DT := 1.0 / 60.0
const LOAD := 300.0


func run() -> void:
	title = "HANG TENSION"

	# Two ways to hang the same weight: lumped on the end particle, and a proxy
	# standing in for a rigid body. Both must report the true weight.
	check("point-mass load: top tension = weight (N)",
			_settled_top_tension(false), (MPM * REST + LOAD) * G, 30.0)
	check("proxy load: top tension = weight (N)",
			_settled_top_tension(true), (MPM * REST + LOAD) * G, 30.0)

	# The profile down the rope. A 300 kg load on 2 kg of fibre swamps it, so
	# every segment carries essentially the whole load and the tension is nearly
	# uniform — the bottom segment already holds the load's weight, the top holds
	# the load plus the rope's own little weight. (Tension falling to near zero
	# down a rope is the DISTRIBUTED case — a rope hanging under its own weight,
	# which is what test_catenary covers — not an end load.)
	var sim := _hang(false)
	_settle(sim)
	var top := sim.tensions[0]
	var bottom := sim.tensions[SEG - 1]
	print("  tension top=%.1f N  bottom=%.1f N" % [top, bottom])
	check("bottom segment carries the load's weight (N)", bottom, LOAD * G, 30.0)
	if not (top > bottom):
		print("  FAIL top does not add the rope's own weight (top %.1f, bottom %.1f)" % [top, bottom])
		failures += 1
	else:
		print("  PASS top carries load + rope, more than the bottom")


func _settled_top_tension(proxy: bool) -> float:
	var sim := _hang(proxy)
	if proxy:
		_settle_proxy(sim)
	else:
		_settle(sim)
	return sim.tensions[0]


func _hang(proxy: bool) -> XPBDRope:
	var sim := XPBDRope.new()
	sim.setup(SEG, REST, MPM)
	sim.gravity = Vector3(0, -G, 0)
	sim.stretch_compliance = 0.0
	sim.damping = 0.5
	sim.drag = 1.0  # air, so the hang oscillation settles to a clean read
	sim.substeps = 16
	sim.iterations = 4
	sim.lay_line(Vector3.ZERO, Vector3(0, -REST, 0), 0.0001)
	sim.pin(0)
	if proxy:
		sim.attach_proxy(SEG, LOAD)
	else:
		sim.add_point_mass(SEG, LOAD)
	return sim


func _settle(sim: XPBDRope) -> void:
	for _i in int(20.0 / DT):
		sim.step(DT)


## Drive the proxy the way Rope3D does, against a 1-DOF hanging body.
func _settle_proxy(sim: XPBDRope) -> void:
	var pos := sim.positions[SEG]
	var vel := Vector3.ZERO
	for _i in int(20.0 / DT):
		sim.seat_proxy(SEG, pos, vel)
		sim.step(DT)
		vel += sim.proxy_momentum(SEG) / LOAD
		vel.y += -G * DT
		pos += vel * DT
		sim.reseat_proxy(SEG, pos)
