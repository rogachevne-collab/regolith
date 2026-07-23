extends RefCounted
# AVBD rope solver — candidate alternative to core/xpbd_rope.gd, same data
# contract (packed arrays in, packed arrays out, no nodes, no physics server),
# so the two are interchangeable and comparable row for row.
#
# Method: Augmented Vertex Block Descent [Giles, Diaz, Yuksel, ACM TOG 44(4),
# 2025], specialized to a chain of 3-DOF particles with hard, unilateral
# distance constraints. Ported from the structure of the authors' own
# reference implementation (github.com/savant117/avbd-demo3d, MIT), which is
# 6-DOF rigid bodies: initialize and warm-start the constraints, warm-start the
# bodies, then alternate a primal sweep with a dual update, then BDF1.
#
# The one-line difference from XPBD: XPBD visits CONSTRAINTS and solves for the
# impulse (dual); AVBD visits PARTICLES and solves for the position (primal),
# with the constraint force carried in a multiplier that survives across
# frames. Primal methods are conditioned by stiffness ratio rather than mass
# ratio, which is why the method is interesting for a rope holding a rover.
#
# Units: meters, kilograms, seconds, Newtons. Tension IS lambda here — in this
# formulation the multiplier is the constraint force in Newtons, with no /h^2
# rescaling (compare XPBD, where tension = -lambda / h^2).
#
# STATUS: spike. Correct on small problems (matches the analytic hang tension
# to 0.03%); the parameter defaults below are provisional and NOT yet measured
# through bench/mass_ratio_bench.gd.

const MIN_MASS := 1e-6
## Penalty bounds in N/m. The floor matches the reference's PENALTY_MIN; the
## ceiling exists only so mutually unsatisfiable constraints cannot ramp
## without limit.
const PENALTY_MIN := 1.0
const PENALTY_MAX := 1e10

var positions := PackedVector3Array()
var prev_positions := PackedVector3Array()
var velocities := PackedVector3Array()
var inv_mass := PackedFloat64Array()
var rest_lengths := PackedFloat64Array()
var tensions := PackedFloat64Array()  # N, read straight off the multipliers

# Per-constraint AVBD state. Both persist ACROSS frames — that persistence is
# the method's main structural advantage over XPBD, where lambda is reset every
# substep and the holding force has to be rediscovered from nothing each time.
var lambdas := PackedFloat64Array()    # N, >= 0: a rope pulls, never pushes
var penalties := PackedFloat64Array()  # N/m, the ramped penalty k

var _c0 := PackedFloat64Array()        # constraint error at the start of the step
var _prev_velocities := PackedVector3Array()
var _inertial := PackedVector3Array()

var gravity := Vector3(0, -9.8, 0)

## Internal damping, 1/s — decays RELATIVE velocity of neighbours only, so it
## cannot slow a rope that falls as a whole (ADR 0003). Same as XPBD's.
var damping := 0.5

## Aerodynamic drag, 1/s. Decays absolute velocity. 0 = vacuum.
var drag := 0.0

## Substeps are NOT the quality dial here, unlike XPBD. Warm starting decays
## lambda once per step, so substepping multiplies that decay and throws away
## exactly the state the method depends on. Spend the budget on iterations.
var substeps := 1
var iterations := 16

## Primal sweeps per dual update. The paper and the reference update the dual
## after every primal sweep, which is right when a body's neighbourhood is a
## handful of contacts. Along a chain it is not: one Gauss-Seidel sweep leaves
## the primal far from its minimum, the dual ascent outruns it, and the solver
## diverges — measurably worse the MORE iterations it is given, which is the
## signature. Measured on a 50-particle chain at 20:1, 20 iterations:
## dual every sweep diverges, dual every 5th sweep settles at 2.3% stretch.
var dual_every := 4

## Stiffness ramp beta, N/m^2 (Eq. 12). Controls how fast the penalty grows
## with constraint error. It does not change the converged answer, only how
## many iterations reaching it takes. beta carries units, so no value is right
## at every scale: the paper quotes 10, the authors' own reference uses 1e4
## with a comment that the right value depends on the scene's length and mass
## scales.
var beta := 1.0e4

## Stabilization alpha (Eq. 18): the fraction of the constraint error already
## present at the START of a step that is deliberately left uncorrected. 0
## corrects everything at once, converting stored position error into momentum
## — the explosive correction that made the old rope buzz forever. 1 never
## corrects and lets error accumulate. Paper: 0.95, reference: 0.99.
var alpha := 0.95

## Warm-start decay gamma (Eq. 19): how much of the previous step's multiplier
## and penalty carries in. Must stay below 1 so the penalty can also fall.
var gamma := 0.99

## Penalty floor k_start, N/m (Eq. 10). Deliberately small: k is the dual
## ascent step size, NOT a spring stiffness. The holding force is carried by
## lambda; k only decides how fast lambda finds it. Setting k anywhere near a
## particle's inertial stiffness m/h^2 makes the dual overshoot every step.
var penalty_start := PENALTY_MIN

## Bound on |lambda|, N (paper §4, "Bounding the Dual Variables").
var max_lambda := 1e12


func setup(segment_count: int, total_length: float, mass_per_meter: float) -> void:
	assert(segment_count >= 1, "rope needs at least one segment")
	assert(total_length > 0.0, "rope length must be positive")
	assert(mass_per_meter > 0.0, "mass_per_meter must be positive")
	var count := segment_count + 1
	positions.resize(count)
	prev_positions.resize(count)
	velocities.resize(count)
	_prev_velocities.resize(count)
	_inertial.resize(count)
	inv_mass.resize(count)
	rest_lengths.resize(segment_count)
	lambdas.resize(segment_count)
	penalties.resize(segment_count)
	tensions.resize(segment_count)
	_c0.resize(segment_count)
	velocities.fill(Vector3.ZERO)
	_prev_velocities.fill(Vector3.ZERO)
	lambdas.fill(0.0)
	penalties.fill(penalty_start)
	tensions.fill(0.0)
	_c0.fill(0.0)
	var seg_rest := total_length / segment_count
	rest_lengths.fill(seg_rest)
	# Lumped masses: each particle carries half of each adjacent segment.
	var seg_mass := maxf(mass_per_meter, MIN_MASS) * seg_rest
	for i in count:
		var m := seg_mass if (i > 0 and i < count - 1) else seg_mass * 0.5
		inv_mass[i] = 1.0 / maxf(m, MIN_MASS)


## Lay particles along a straight line from a to b, at rest.
func lay_line(a: Vector3, b: Vector3) -> void:
	var count := positions.size()
	for i in count:
		positions[i] = a.lerp(b, float(i) / float(count - 1))
	prev_positions = positions.duplicate()
	velocities.fill(Vector3.ZERO)
	_prev_velocities.fill(Vector3.ZERO)


func pin(index: int) -> void:
	inv_mass[index] = 0.0


## Add lumped mass in kg to one particle (a hook, a weight, a vehicle).
func add_point_mass(index: int, extra_kg: float) -> void:
	assert(extra_kg >= 0.0, "point mass must not be negative")
	if inv_mass[index] > 0.0:
		inv_mass[index] = 1.0 / maxf(1.0 / inv_mass[index] + extra_kg, MIN_MASS)


## Move a pinned particle that is TRAVELLING (an anchor on a moving crane).
func move_pin(index: int, to: Vector3, velocity := Vector3.ZERO) -> void:
	positions[index] = to
	prev_positions[index] = to
	velocities[index] = velocity


## Rigidly move the whole rope — shape, velocities and the warm-started
## multipliers all survive, so no transient is manufactured.
func teleport(delta: Vector3) -> void:
	for i in positions.size():
		positions[i] += delta
		prev_positions[i] += delta


func apply_impulse(index: int, impulse: Vector3) -> void:
	velocities[index] += impulse * inv_mass[index]


func step(dt: float) -> void:
	if not (dt > 0.0) or not is_finite(dt):
		return
	var h := dt / float(substeps)
	for _s in substeps:
		_substep(h)
	for j in rest_lengths.size():
		tensions[j] = lambdas[j]


func _substep(h: float) -> void:
	var count := positions.size()
	var segs := rest_lengths.size()
	var inv_h2 := 1.0 / (h * h)

	# --- Constraints: cache C(x-) and warm start the duals (Eq. 19).
	for j in segs:
		var c0 := positions[j].distance_to(positions[j + 1]) - rest_lengths[j]
		# A rope is unilateral, so only OVERSTRETCH is error worth spreading
		# over later steps. Without this clamp the stabilization term reads a
		# slack segment as pre-stretched and manufactures tension out of
		# nothing the moment it goes taut.
		_c0[j] = maxf(c0, 0.0)
		lambdas[j] = clampf(lambdas[j] * alpha * gamma, 0.0, max_lambda)
		penalties[j] = clampf(penalties[j] * gamma, penalty_start, PENALTY_MAX)

	# --- Particles: inertial position y, and the initial guess for x.
	var g_len_sq := gravity.length_squared()
	for i in count:
		prev_positions[i] = positions[i]
		if inv_mass[i] == 0.0:
			_inertial[i] = positions[i]
			continue
		_inertial[i] = positions[i] + velocities[i] * h + gravity * (h * h)
		# Adaptive warm start (VBD): guess where the particle will actually end
		# up, not where it would fall freely. A particle that was NOT
		# accelerating downward last frame is being held by the rope, so the
		# free-fall guess would drop it and have the constraint yank it back —
		# injecting exactly the energy that keeps a hanging rope buzzing.
		var w := 0.0
		if g_len_sq > 0.0:
			var accel := (velocities[i] - _prev_velocities[i]) / h
			w = clampf(accel.dot(gravity) / g_len_sq, 0.0, 1.0)
		positions[i] += velocities[i] * h + gravity * (w * h * h)

	# --- Main loop: primal (move particles), then dual (update forces).
	for it in iterations:
		# Sweep direction alternates. Gauss-Seidel carries information one
		# particle per sweep in the direction it runs, so a fixed direction
		# would need ~N iterations to tell the far end of the rope that the
		# near end is loaded. (A GPU port would colour the particles and lose
		# this; a rope on a CPU does not have to.)
		if it % 2 == 0:
			for i in count:
				_solve_particle(i, inv_h2)
		else:
			for i in range(count - 1, -1, -1):
				_solve_particle(i, inv_h2)
		if (it + 1) % dual_every == 0:
			for j in segs:
				_update_dual(j)

	# --- BDF1 velocity update.
	for i in count:
		_prev_velocities[i] = velocities[i]
		if inv_mass[i] != 0.0:
			velocities[i] = (positions[i] - prev_positions[i]) / h
	_apply_damping(h, segs)


## One block of the block coordinate descent: move particle i to the minimum of
## its own local variational energy, holding every other particle fixed (Eq. 3),
## by one Newton step on the resulting 3x3 system (Eq. 4).
func _solve_particle(i: int, inv_h2: float) -> void:
	if inv_mass[i] == 0.0:
		return
	var m_over_h2 := inv_h2 / inv_mass[i]
	# Symmetric 3x3 system kept as its 6 distinct entries. Starts at the
	# inertia term M/h^2 (Eqs. 5, 6) and takes one rank-1 plus one transverse
	# term per attached segment.
	var h00 := m_over_h2
	var h11 := m_over_h2
	var h22 := m_over_h2
	var h01 := 0.0
	var h02 := 0.0
	var h12 := 0.0
	var f := (_inertial[i] - positions[i]) * m_over_h2

	for s in 2:
		var j := i - 1 + s  # the segments (i-1, i) and (i, i+1)
		if j < 0 or j >= rest_lengths.size():
			continue
		var d := positions[j + 1] - positions[j]
		var seg_len := d.length()
		if seg_len < 1e-12:
			continue
		var dir := d / seg_len
		var c := seg_len - rest_lengths[j] - alpha * _c0[j]

		# Unilateral: a rope pulls, never pushes, so the FORCE clamps at zero
		# (Eq. 13). The HESSIAN must not clamp with it — paper §3.2: a clamped
		# force with a zeroed Hessian is a discontinuity that stops the
		# optimizer from making progress. Concretely, a particle between one
		# taut and one slack segment would carry the taut segment's kilonewtons
		# against nothing but its own 50 g of inertia and leave the scene.
		var k := penalties[j]
		var lam_raw := k * c + lambdas[j]
		var lam := maxf(lam_raw, 0.0)
		if lam_raw < 0.0 and absf(c) > 1e-12:
			# Stiffness rescaling (Eq. 14): use the stiffness that would exactly
			# produce the clamped force, so a slack segment fades out smoothly
			# instead of stamping stiffness it is not entitled to.
			k = minf(k, absf(lambdas[j] / c))

		# grad = dC/dx_i: +dir at the far end of the segment, -dir at the near.
		var grad := dir if j == i - 1 else -dir
		f -= grad * lam

		# H += k grad grad^T + lambda d2C/dx^2, and for a distance constraint
		# d2C/dx^2 = (I - dir dir^T)/len exactly. Under tension (lambda >= 0)
		# that term is already positive semi-definite, so unlike the general
		# case (paper §3.5) a rope needs no diagonal approximation to keep the
		# system SPD — the exact Hessian is available and cheaper.
		#
		# Physically this second term is why the method holds a heavy load: it
		# is the transverse stiffness lambda/len of a taut string. XPBD has no
		# equivalent and has to discover it through iterations.
		var g := lam / seg_len
		h00 += k * dir.x * dir.x + g * (1.0 - dir.x * dir.x)
		h11 += k * dir.y * dir.y + g * (1.0 - dir.y * dir.y)
		h22 += k * dir.z * dir.z + g * (1.0 - dir.z * dir.z)
		h01 += (k - g) * dir.x * dir.y
		h02 += (k - g) * dir.x * dir.z
		h12 += (k - g) * dir.y * dir.z

	positions[i] += _solve_sym3(h00, h01, h02, h11, h12, h22, f)


## Dual step (Eqs. 11-13): the multiplier absorbs the force the penalty just
## discovered, and the penalty ramps in proportion to the error that remains.
func _update_dual(j: int) -> void:
	var seg_len := positions[j].distance_to(positions[j + 1])
	var c := seg_len - rest_lengths[j] - alpha * _c0[j]
	var lam := penalties[j] * c + lambdas[j]
	if lam <= 0.0:
		# Slack: the force clamps to zero, and per §3.2 a clamped constraint
		# must NOT ramp its penalty — otherwise every slack segment grows an
		# enormous stiffness it will never need.
		lambdas[j] = 0.0
		return
	lambdas[j] = minf(lam, max_lambda)
	penalties[j] = minf(penalties[j] + beta * absf(c), PENALTY_MAX)


## Solve H dx = f for a symmetric positive definite H given as its 6 distinct
## entries. Cramer on the adjugate: 3x3 is small enough that a factorization
## buys nothing, and GDScript floats are 64-bit whatever the engine build is.
func _solve_sym3(a: float, b: float, c: float, d: float, e: float, f: float, r: Vector3) -> Vector3:
	var i00 := d * f - e * e
	var i01 := c * e - b * f
	var i02 := b * e - c * d
	var det := a * i00 + b * i01 + c * i02
	if absf(det) < 1e-30:
		return Vector3.ZERO
	var i11 := a * f - c * c
	var i12 := b * c - a * e
	var i22 := a * d - b * b
	var inv_det := 1.0 / det
	return Vector3(
		(i00 * r.x + i01 * r.y + i02 * r.z) * inv_det,
		(i01 * r.x + i11 * r.y + i12 * r.z) * inv_det,
		(i02 * r.x + i12 * r.y + i22 * r.z) * inv_det,
	)


func _apply_damping(h: float, segs: int) -> void:
	if damping > 0.0:
		var k := 1.0 - exp(-damping * h)
		for j in segs:
			var wi := inv_mass[j]
			var wj := inv_mass[j + 1]
			var w := wi + wj
			if w == 0.0:
				continue
			var impulse := (velocities[j + 1] - velocities[j]) * (k / w)
			velocities[j] += impulse * wi
			velocities[j + 1] -= impulse * wj
	if drag > 0.0:
		var kd := exp(-drag * h)
		for i in velocities.size():
			if inv_mass[i] != 0.0:
				velocities[i] *= kd


func segment_count() -> int:
	return rest_lengths.size()


func total_polyline_length() -> float:
	var out := 0.0
	for j in rest_lengths.size():
		out += positions[j].distance_to(positions[j + 1])
	return out


func max_speed() -> float:
	var out := 0.0
	for i in velocities.size():
		out = maxf(out, velocities[i].length())
	return out


## Center of mass in meters — the quantity gravity and damping must not lie
## about (see tests/test_free_fall.gd).
func center_of_mass() -> Vector3:
	var total := 0.0
	var acc := Vector3.ZERO
	for i in positions.size():
		if inv_mass[i] == 0.0:
			continue
		var m := 1.0 / inv_mass[i]
		acc += positions[i] * m
		total += m
	return acc / total if total > 0.0 else Vector3.ZERO
