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
# STATUS: spike, but a measured one (spikes/spike_d, spike_e, spike_g).
#
# Operating envelope, and it is narrower than the stretch column suggests:
# BELOW 8 ITERATIONS THE TENSION READOUT IS NOT USABLE. At 2-4 iterations the
# rope still holds its length (0.1-0.2% stretch) but the multiplier has not
# converged, the penalty term carries the force, and the reported tension comes
# out orders of magnitude high. At 8 and 16 it is right: -1.2% on a bare rope,
# +9.6% and +3.3% under a 250 kg payload, against the analytic static answer.
# So: 8 iterations is the floor, never fewer.
#
# THAT IS THE FLOOR, NOT THE ANSWER. The iterations a rope needs grow with its
# size, and a rope given too few reports tension that is wrong by orders of
# magnitude while its stretch column stays immaculate — the failure is
# invisible in every metric but the one the addon exists to deliver. Hence the
# length guard: [method required_iterations] is measured, [member iterations]
# is raised to meet it, and a rope past the ceiling says so instead of lying
# quietly. See [member length_guard] and spikes/spike_g_length_guard.gd.
#
# NOT yet run against tests/test_catenary.gd, which is the independent arbiter
# for both shape and tension, and the two-pin span still wants explaining.

## Narrow phase lives in one file for every core (ADR 0008): two solvers may
## disagree about how to solve a contact, never about where the surface is.
const RopeColliders := preload("res://addons/ropes/core/rope_colliders.gd")
const SHAPE_PLANE := RopeColliders.SHAPE_PLANE
const SHAPE_SPHERE := RopeColliders.SHAPE_SPHERE
const SHAPE_BOX := RopeColliders.SHAPE_BOX

const MIN_MASS := 1e-6
## Penalty bounds in N/m. The floor matches the reference's PENALTY_MIN; the
## ceiling exists only so mutually unsatisfiable constraints cannot ramp
## without limit.
const PENALTY_MIN := 1.0
const PENALTY_MAX := 1e10
## Most the penalty may grow in one dual update, as a factor. From a cold
## k = 1 this still reaches the 1e6 a heavy payload needs inside two steps.
const PENALTY_RAMP_MAX := 4.0

## How far a particle's one-step inertial guess may move RELATIVE TO ITS
## NEIGHBOURS' guesses, as a multiple of the shorter of its two adjacent
## segments. Not a velocity clamp — [member velocities] is untouched and keeps
## acting every subsequent step — and, critically, not an ABSOLUTE-position
## clamp either: see [method _clamp_deviation] for why the distinction is the
## whole fix.
##
## This is the fix for a reproducible divergence (spikes/spike_j_impulse.gd):
## a single violent impulse — 100 N*s on one particle of a 5 m, 25-segment
## rope — blew the core up within ~0.05 s. Confirmed by instrumentation
## (spikes/spike_k_impulse_mechanism.gd) before touching anything: the impulse
## moves the hit particle's one-step inertial guess (velocities[i] * h) tens
## of segment-lengths past its neighbours — 1000 m/s * h(1/60 s) = 16.7 m
## against a 0.2 m segment — producing a `c` no iteration budget can resolve
## in one step. lambdas[j] spikes off that huge `c`, beta is derived
## proportional to lambda (_beta_for), so the next penalty ramp is enormous —
## penalty went from a warm-started ~1e2 to the PENALTY_MAX ceiling in 3
## frames, entirely decoupled from the ~360 N/m that segment's own particles
## could physically justify. That confirmed the suspected mechanism (a raised
## lambda steepens the very ramp that raised it) but NOT the suggested fix:
## bounding the penalty (and, additively, lambda) against the segment's own
## inertial stiffness m/h^2 stopped the unbounded blow-up but only traded it
## for a narrow, chaotically parameter-sensitive survival band under a fine
## sweep of the cap's value — evidence the huge one-step `c` itself, not just
## the force computed from it, has to be kept geometrically sane.
##
## FIRST VERSION OF THIS FIX clamped absolute guess displacement and was
## WRONG: spikes/spike_l_galilean.gd (written after a review caught what
## spike_j's gate could not — tests/test_free_fall.gd only ever exercised
## XPBD) measured a hard terminal velocity at MAX_GUESS_STRETCH * seg_len / h
## exactly — 24 m/s at this rope's resolution — and a rope launched sideways
## fell at a DIFFERENT rate depending on launch speed, which is Galilean
## invariance broken outright (ADR 0003 protects this for damping; ADR 0006
## decision 3 is the reason it matters — a rope inside an accelerating
## rocket routinely exceeds 24 m/s and must not care). Clamping ABSOLUTE
## displacement cannot avoid this: a uniformly moving or free-falling rope has
## every particle moving together, which absolute clamping cannot tell apart
## from one particle moving alone.
##
## The corrected version clamps the DEVIATION from each particle's local
## neighbourhood, not its raw displacement (_clamp_deviation). A rigid
## translation — every particle sharing the same guess displacement, which is
## exactly what free fall and a sideways launch are — makes that deviation
## exactly zero by construction, at any speed, so the clamp never engages and
## imposes no speed limit. A single particle kicked far past its neighbours
## still shows a large deviation and is still caught. Re-run against
## spike_j_impulse.gd: identical result, every magnitude up to 500 N*s still
## survives — the relative clamp catches the same pathological case, just
## without the side effect.
const MAX_GUESS_STRETCH := 2.0

## Ceiling on the EXTRA substeps [method _disturbance_substeps] may add for one
## tick, on top of [member substeps]. A real cap, not a floor like
## ITERATIONS_MAX: a disturbance past this is left to the ordinary
## clamp-and-iterate path exactly as before this existed, rather than paying
## for an arbitrarily fine subdivision of one tick. 16 matches the XPBD core's
## own usual range for a heavy payload (see the mass-ratio research note), so
## the worst case this can cost is "briefly as expensive as the other core."
const DISTURBANCE_SUBSTEPS_MAX := 16

## --- The length guard, all measured in spikes/spike_g_length_guard.gd -------
##
## Iteration floor. Below this the multiplier has not converged at any size
## (see the header); this is a hard floor, not part of the guard, and the guard
## cannot be turned off far enough to go under it.
const ITERATIONS_MIN := 8
## Iteration ceiling the guard will raise to on its own. Past this the cost is
## no longer worth paying blind: the step is O(particles x iterations), so a
## 400-particle rope at 96 costs 120 ms in this reference core against 23 ms at
## 16. A rope that needs more still RUNS at the ceiling — it is not refused,
## and at the ceiling it is usually close — but it is warned about, because
## "close" is not what get_segment_tension() promises.
const ITERATIONS_MAX := 96

## Fineness M = segments / segment_length = segments^2 / total_length, in 1/m.
## This — NOT the segment count, which was the obvious guess and is wrong — is
## what orders the failures. At 16 iterations, 200 segments read +3.0% at 0.5 m
## per segment, +14.2% at 0.25 m and +10154% at 0.125 m, all free hanging: same
## chain length in particles, three different worlds. The reason is in
## [method _beta_for], where the penalty ramp goes as 1/(n_dual^2 e^2 L^2), so
## halving the segment length asks four times as much of the dual ascent.
##
## The two regimes need different exponents, which is why they are separate
## constants rather than one K: a payload does not thin out along the rope the
## way the rope's own weight does, so it asks more of every segment rather than
## just the top ones. Measured crossings for the <= 10% tension band, iterations
## against M:
##
##     free     M =   80 ->  8    320 -> 12    640 -> 16    800 -> 24
##              M = 1280 -> 24   1600 -> 32           (max it / M^0.5 = 0.85)
##     loaded   M =  100 -> 16    320 -> 24    640 -> 48    800 -> 48
##              M = 1280 -> 64   1600 -> 96           (max it / M^0.6 = 1.15)
##
## Each constant is the WORST ratio observed, not the average, because the
## ladder that produced the crossings is coarse (8, 12, 16, 24, 32, 48, 64, 96,
## 128) and a rule fitted to the mean would sit below half the measurements.
const GUARD_FINENESS_FREE := 0.85
const GUARD_FINENESS_FREE_EXP := 0.5
const GUARD_FINENESS_LOADED := 1.15
const GUARD_FINENESS_LOADED_EXP := 0.6

## Second requirement, in iterations per segment. Fineness is not the whole
## story: information still has to cross the chain, so a long rope of coarse
## segments needs more than its M alone asks for. Only ever binds on the free
## side (100 segments of 1 m: M = 100 wants 9 by fineness, and 8 is enough
## measured; 400 segments of 0.25 m wants 34 by fineness and 36 by this).
const GUARD_SEGMENTS := 0.09

## A point mass above this fraction of the rope's own mass switches the guard
## to the loaded law. Deliberately low: the loaded law is the conservative one,
## and paying for it on a rope with a small hook is far cheaper than the
## alternative of reporting confident nonsense.
const GUARD_LOADED_FRACTION := 0.1

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
var _betas := PackedFloat64Array()     # per-segment penalty ramp, derived
var _prev_velocities := PackedVector3Array()
var _inertial := PackedVector3Array()
var _raw_guess := PackedVector3Array() # unclamped one-step displacement, this substep
var _raw_start := PackedVector3Array() # same, w-scaled gravity (adaptive warm start)

# --- Contacts (ADR 0006 for the geometry and the rules, ADR 0008 for the form)
#
# A contact is a constraint ROW like any other, not a projection bolted onto
# the end of the step: C = radius - signed_distance, unilateral, with its own
# multiplier and its own ramped penalty, both warm-started across frames. That
# persistence is the point — a rope lying on a box should be quiet for the same
# structural reason a rope holding a rover is quiet, because the supporting
# force lives in a multiplier that survives the frame instead of being
# rediscovered from penetration depth every time.
#
# Samples are indexed particles first, then segment midpoints: sample `i` is
# particle `i`, sample `count + j` is the midpoint of segment `j`. Multipliers
# are kept per SAMPLE rather than per (sample, collider) pair, so a sample
# touching two colliders at once warm-starts from whichever was deepest last
# frame. That is the common case done right and the rare case done adequately;
# a stable per-pair key needs collider identity the host does not yet provide.

## Colliders near the rope, pushed by the host once per tick — same contract as
## the XPBD core, same dictionary, deliberately interchangeable.
var colliders: Array[Dictionary] = []

## Contact thickness: samples keep this distance from collider surfaces.
var radius := 0.02

## Coulomb friction coefficient against all colliders.
var friction := 0.6

var _c_near: Array[bool] = []
var _c_xf: Array[Transform3D] = []
var _c_inv: Array[Transform3D] = []
var _contact_c := PackedFloat64Array()       # penetration, m; <= 0 = no contact
var _contact_n := PackedVector3Array()       # outward surface normal
var _contact_vel := PackedVector3Array()     # surface velocity at the sample
var _contact_lambda := PackedFloat64Array()  # N, >= 0: a contact pushes only
var _contact_penalty := PackedFloat64Array() # N/m
var _any_contact := false

var _total_length := 0.0               # m, as passed to setup()
var _rope_mass := 0.0                  # kg, the rope's own
var _point_mass := 0.0                 # kg, everything hung on it
var _iters := 16                       # effective_iterations(), cached per step
var _guard_warned := false

var gravity := Vector3(0, -9.8, 0)

## Internal damping, 1/s — decays RELATIVE velocity of neighbours only, so it
## cannot slow a rope that falls as a whole (ADR 0003). Same as XPBD's.
var damping := 0.5

## Aerodynamic drag, 1/s. Decays absolute velocity. 0 = vacuum.
var drag := 0.0

## Substeps are NOT your quality dial here, unlike XPBD. Warm starting decays
## lambda once per substep, so authoring a permanently higher count multiplies
## that decay and throws away exactly the state the method depends on. Spend
## the budget on iterations instead. This is a floor, not a ceiling: [method
## step] may still add MORE, briefly and automatically, when [method
## _disturbance_substeps] detects a kick this budget cannot resolve in one —
## that is a reflex, not a setting, and it is supposed to cost lambda some of
## its warm start, because the kick already invalidated that estimate.
var substeps := 1

## Requested primal sweeps per step. The number actually run is
## [method effective_iterations], which is this raised to whatever the rope's
## size demands and never lowered — a rope authored with a generous budget
## keeps it.
var iterations := 16

## Raise [member iterations] to [method required_iterations] automatically.
##
## Leave it on. Off, this core happily runs a 400-segment rope at 16 iterations
## and reports a tension 947% high (free hanging) or 1549406% high (250 kg)
## while its stretch reads 0.39% — which is why the guard is here and not in
## the node: the core must not be usable in that mode by accident. Turning it
## off is for the spike that MEASURES the guard, and for nothing else. The
## floor of [constant ITERATIONS_MIN] applies either way.
var length_guard := true

## Primal sweeps per dual update. The paper and the reference update the dual
## after every primal sweep, which is right when a body's neighbourhood is a
## handful of contacts. Along a chain it is not: one Gauss-Seidel sweep leaves
## the primal far from its minimum, the dual ascent outruns it, and the solver
## diverges — measurably worse the MORE iterations it is given, which is the
## signature. Measured on a 50-particle chain at 20:1, 20 iterations:
## dual every sweep diverges, dual every 5th sweep settles at 2.3% stretch.
## Measured best at 2 once beta is right (spikes/spike_d_payload_bounce.gd).
var dual_every := 2

## Stretch this rope is allowed to settle at, as a fraction of rest length.
## This is the knob; the penalty ramp beta is DERIVED from it per segment (see
## [method _beta_for]), the same way the addon exposes compliance in m/N rather
## than an abstract 0..1 stiffness.
##
## Deriving it is not a nicety. beta carries units (N/m^2) and enters the
## steady state quadratically, so one constant cannot serve a 2.5 kg rope and a
## 1250 kg payload: the value that pins a rover (1e7) drives a bare rope's
## penalty into its ceiling, where the force is carried by the penalty term
## instead of the multiplier and the reported tension comes out ~75x too high —
## measured, and exactly the quantity ADR 0001 exists to protect.
var max_stretch := 0.01

## Set non-zero to override the derived penalty ramp with a fixed beta, N/m^2.
## For experiments only; a fixed value does not survive a change of scale.
var beta_override := 0.0

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
	_raw_guess.resize(count)
	_raw_start.resize(count)
	inv_mass.resize(count)
	rest_lengths.resize(segment_count)
	lambdas.resize(segment_count)
	penalties.resize(segment_count)
	tensions.resize(segment_count)
	_c0.resize(segment_count)
	_betas.resize(segment_count)
	_betas.fill(0.0)
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
	var samples := count + segment_count
	_contact_c.resize(samples)
	_contact_n.resize(samples)
	_contact_vel.resize(samples)
	_contact_lambda.resize(samples)
	_contact_penalty.resize(samples)
	_contact_c.fill(0.0)
	_contact_n.fill(Vector3.ZERO)
	_contact_vel.fill(Vector3.ZERO)
	_contact_lambda.fill(0.0)
	_contact_penalty.fill(penalty_start)
	_total_length = total_length
	_rope_mass = maxf(mass_per_meter, MIN_MASS) * total_length
	_point_mass = 0.0
	_guard_warned = false
	_iters = effective_iterations()


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
		# The guard's two laws are chosen by this, so it has to be tracked here
		# rather than sniffed out of inv_mass later — by then a pinned end and
		# a heavy hook look the same.
		_point_mass += extra_kg


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


## True when what is hung on this rope dominates the rope's own weight. Selects
## which of the guard's two laws applies; see [constant GUARD_LOADED_FRACTION].
func is_loaded() -> bool:
	return _point_mass > _rope_mass * GUARD_LOADED_FRACTION


## Primal sweeps this chain needs before its tension readout can be believed.
## Measured, not derived — spikes/spike_g_length_guard.gd, and the constants it
## produced are documented above.
##
## Deliberately NOT clamped to [constant ITERATIONS_MAX]: a caller has to be
## able to see a requirement run off the end of the budget, because that is
## precisely the configuration that must warn instead of quietly under-solving.
##
## What it costs, since this is spending someone's frame. A step is
## O(particles x iterations); in node terms M = length * spm^2, so the rule is
## `sqrt(length) * spm` free and `length^0.6 * spm^1.2` loaded, and the step
## cost grows as `length^1.5 * spm^2` free, `length^1.6 * spm^2.2` loaded. At 4
## segments per metre, measured in this GDScript reference core (spike_g; a C++
## port is ADR 0001's whole point, so read these as ratios):
##
##            segs   free  us/step  |  loaded  us/step
##     5 m      20      8      620  |      16     1100
##    20 m      80     16     4400  |      38    10800
##    50 m     200     26    16500  |      64    43000
##   100 m     400     36    42000  |      98   past the ceiling -> warning
##
## So at 4 per metre every free rope up to 100 m is served, and every loaded
## one up to 50 m. Resolution runs out sooner than length: 5 m at the node's
## maximum 16 per metre wants 32 free and 86 loaded, 20 m at 16 per metre wants
## 62 and 194. The ropes that get warned are the ones where the honest budget
## is more than a frame is worth, and saying so beats charging for it quietly
## or — far worse — not charging and reporting the number anyway.
static func required_iterations(segment_count: int, total_length: float,
		loaded: bool) -> int:
	if segment_count < 1 or not (total_length > 0.0):
		return ITERATIONS_MIN
	var n := float(segment_count)
	# Fineness, 1/m. Written the long way round because the segment length is
	# the quantity that actually drives it and the squared segment count is an
	# accident of how it is usually authored.
	var fineness := n / (total_length / n)
	var need := GUARD_SEGMENTS * n
	if loaded:
		need = maxf(need, GUARD_FINENESS_LOADED
				* pow(fineness, GUARD_FINENESS_LOADED_EXP))
	else:
		need = maxf(need, GUARD_FINENESS_FREE
				* pow(fineness, GUARD_FINENESS_FREE_EXP))
	# Round up to even. dual_every is 2, so an odd sweep at the end is paid for
	# and then never gets the dual update that would have used it.
	return maxi(ITERATIONS_MIN, int(ceil(need * 0.5)) * 2)


## What a rope past the ceiling has to say, or "" when it is inside the
## envelope. Static and shared so the core's runtime warning and the node's
## editor warning cannot drift apart from each other or from the rule.
static func guard_warning(segment_count: int, total_length: float, loaded: bool,
		iterations_used: int) -> String:
	var need := required_iterations(segment_count, total_length, loaded)
	if iterations_used >= need:
		return ""
	return ("AVBD rope: %d segments over %.1f m (%.2f m per segment%s) needs %d "
			+ "iterations for a trustworthy tension readout and is running %d. "
			+ "TENSION READINGS AT THIS LENGTH AND RESOLUTION ARE NOT "
			+ "TRUSTWORTHY — shape and "
			+ "stretch still are, which is why this cannot be seen without "
			+ "being told. Use fewer segments per metre, a shorter rope, or "
			+ "stop reading tension off it.") % [segment_count, total_length,
					total_length / maxf(float(segment_count), 1.0),
					", loaded" if loaded else "", need, iterations_used]


## Primal sweeps this step will actually run: [member iterations] raised to the
## rope's requirement, never lowered, floored at [constant ITERATIONS_MIN] and
## — for the automatic raise only — capped at [constant ITERATIONS_MAX]. An
## explicit [member iterations] above the cap is honoured; someone who types
## 200 has decided to pay for 200.
func effective_iterations() -> int:
	var want := maxi(iterations, ITERATIONS_MIN)
	if not length_guard or rest_lengths.is_empty():
		return want
	var need := required_iterations(rest_lengths.size(), _total_length, is_loaded())
	var used := maxi(want, mini(need, ITERATIONS_MAX))
	if used < need and not _guard_warned:
		# Once per rope. This fires every step otherwise, and a warning that
		# spams is a warning that gets filtered out.
		_guard_warned = true
		push_warning(guard_warning(rest_lengths.size(), _total_length,
				is_loaded(), used))
	return used


func step(dt: float) -> void:
	if not (dt > 0.0) or not is_finite(dt):
		return
	# Once per step, not per substep: the guard reads iterations and the derived
	# beta reads the guard, so both have to see the same number all the way
	# through or the penalty ramp is calibrated for a sweep count that never ran.
	_iters = effective_iterations()
	# One broadphase reject per step, not per iteration: the collider list only
	# changes when the host refreshes it (ADR 0006 decision 2).
	_any_contact = not colliders.is_empty() \
			and RopeColliders.cull(colliders, positions, radius, max_speed() * dt, _c_near)
	var base_substeps := maxi(substeps, 1)
	# Decided ONCE per tick, from velocities as they stand right now — which
	# already include any apply_impulse() calls made this frame, before any
	# substep has touched them. A kick this violent cannot be resolved by
	# clamp-and-iterate at the authored substep count; see
	# _disturbance_substeps for what "violent" means here.
	var eff_substeps := maxi(base_substeps, _disturbance_substeps(dt / float(base_substeps)))
	var h := dt / float(eff_substeps)
	for _s in eff_substeps:
		_substep(h)
	for j in rest_lengths.size():
		tensions[j] = lambdas[j]


## Extra substeps this tick needs, above [param base] steps of [param h_base]
## seconds each, because some particle's velocity alone — before gravity or
## warm-starting are folded in, which only sharpens the number — would still
## blow past its neighbourhood's [method _max_guess_disp] cap. That cap is
## the same one [method _clamp_deviation] enforces every step by force; this
## asks for finer steps instead of relying on that clamp to recover a coarse
## one, which is the difference between the guess landing near the solver's
## reach and being torn back to it. A rope with nothing violent happening
## returns 1 unconditionally — the neighbour-relative deviation of an ordinary
## settling or swinging rope never approaches the cap, so this costs one cheap
## O(particles) pass for nothing on every ordinary tick.
##
## Deliberately reads velocities, not a full replica of [member _raw_guess]:
## gravity is common-mode across neighbours, so it mostly cancels out of the
## DEVIATION this is measuring, and the warm-start weight in _raw_start exists
## to avoid injecting energy into an otherwise-quiet rope, which is not what
## is being decided here. Good enough to size the subdivision; the real guess
## is still built properly, per substep, once eff_substeps is decided.
func _disturbance_substeps(h_base: float) -> int:
	var count := positions.size()
	if count < 3:
		return 1
	var worst := 1.0
	for i in count:
		if inv_mass[i] == 0.0:
			continue
		var cap := _max_guess_disp(i)
		if not (cap > 0.0) or not is_finite(cap):
			continue
		var neighbor_sum := Vector3.ZERO
		var neighbor_count := 0
		if i - 1 >= 0:
			neighbor_sum += velocities[i - 1]
			neighbor_count += 1
		if i + 1 < count:
			neighbor_sum += velocities[i + 1]
			neighbor_count += 1
		if neighbor_count == 0:
			continue
		var rigid := neighbor_sum / float(neighbor_count)
		var dev_len := (velocities[i] - rigid).length() * h_base
		if dev_len > cap:
			worst = maxf(worst, dev_len / cap)
	return clampi(int(ceil(worst)), 1, DISTURBANCE_SUBSTEPS_MAX)


func _substep(h: float) -> void:
	var count := positions.size()
	var segs := rest_lengths.size()
	var inv_h2 := 1.0 / (h * h)

	# --- Constraints: cache C(x-), warm start the duals (Eq. 19), derive beta.
	# beta is derived from the STATIC weight the rope (+ payload) must carry —
	# never from the live multiplier. It used to be maxf(lambdas[j],
	# lambda_floor), which reads as "warm start from whichever is bigger" but
	# is actually a closed loop: lambda feeds beta, beta sets how hard the next
	# dual update may raise lambda, so a lambda spike steepens the very ramp
	# that produced it — the mechanism spike_k caught directly (measured: a
	# 100 N*s impulse took the penalty from a warm-started ~1e2 to
	# PENALTY_MAX in 3 frames). See the note above _beta_for for what this
	# costs and what it does not.
	var lambda_floor := _hanging_weight()
	for j in segs:
		_betas[j] = _beta_for(lambda_floor, rest_lengths[j])
		var c0 := positions[j].distance_to(positions[j + 1]) - rest_lengths[j]
		# A rope is unilateral, so only OVERSTRETCH is error worth spreading
		# over later steps. Without this clamp the stabilization term reads a
		# slack segment as pre-stretched and manufactures tension out of
		# nothing the moment it goes taut.
		_c0[j] = maxf(c0, 0.0)
		lambdas[j] = clampf(lambdas[j] * alpha * gamma, 0.0, max_lambda)
		penalties[j] = clampf(penalties[j] * gamma, penalty_start, PENALTY_MAX)

	# Contacts warm start the same way, and for the same reason. A sample that
	# has left its collider is caught by the dual step, which zeroes a clamped
	# multiplier — no separate bookkeeping for "the contact ended".
	if _any_contact:
		RopeColliders.interpolate(colliders, 1.0, _c_near, _c_xf, _c_inv)
		for s in _contact_lambda.size():
			_contact_lambda[s] = clampf(_contact_lambda[s] * alpha * gamma,
					0.0, max_lambda)
			_contact_penalty[s] = clampf(_contact_penalty[s] * gamma,
					penalty_start, PENALTY_MAX)

	# --- Particles: inertial position y, and the initial guess for x.
	#
	# Both guesses are built in two passes. Pass 1 computes each particle's
	# own RAW one-step displacement in isolation — the free-flight answer,
	# unclamped. Pass 2 splits that against its immediate neighbours' raw
	# displacements into a locally rigid part (left untouched, however large)
	# and a deviation from it (the only part ever clamped) — see
	# _clamp_deviation for why this split, and not a clamp on the raw
	# displacement itself, is what keeps the guess Galilean invariant.
	var g_len_sq := gravity.length_squared()
	_raw_guess.resize(count)
	_raw_start.resize(count)
	for i in count:
		if inv_mass[i] == 0.0:
			# A pin's own position is set externally (move_pin/teleport), not
			# by this guess — but its VELOCITY still counts as what its
			# neighbourhood is doing, the same way [method _apply_damping]
			# already treats a pinned particle's velocity as meaningful.
			_raw_guess[i] = velocities[i] * h
			_raw_start[i] = _raw_guess[i]
			continue
		_raw_guess[i] = velocities[i] * h + gravity * (h * h)
		# Adaptive warm start (VBD): guess where the particle will actually end
		# up, not where it would fall freely. A particle that was NOT
		# accelerating downward last frame is being held by the rope, so the
		# free-fall guess would drop it and have the constraint yank it back —
		# injecting exactly the energy that keeps a hanging rope buzzing.
		var w := 0.0
		if g_len_sq > 0.0:
			var accel := (velocities[i] - _prev_velocities[i]) / h
			w = clampf(accel.dot(gravity) / g_len_sq, 0.0, 1.0)
		_raw_start[i] = velocities[i] * h + gravity * (w * h * h)

	for i in count:
		prev_positions[i] = positions[i]
		if inv_mass[i] == 0.0:
			_inertial[i] = positions[i]
			continue
		var cap := _max_guess_disp(i)
		_inertial[i] = positions[i] + _clamp_deviation(i, _raw_guess, cap)
		positions[i] += _clamp_deviation(i, _raw_start, cap)

	# --- Main loop: primal (move particles), then dual (update forces).
	for it in _iters:
		# Re-probed every iteration, not cached for the step. ADR 0006 decision
		# 2 is that a frozen contact plane cannot represent "the particle went
		# around the edge" — and this core runs at substeps = 1, so caching per
		# substep WOULD be caching per tick, which is exactly the failure that
		# decision names. It is also affordable: 16 iterations x 49 samples is
		# fewer probes per step than XPBD at 32 substeps pays for the same rope.
		if _any_contact:
			_probe_contacts()
		_primal_sweep(it, inv_h2)
		if (it + 1) % dual_every == 0:
			for j in segs:
				_update_dual(j, _betas[j])
			if _any_contact:
				_update_contact_duals()

	# --- BDF1 velocity update.
	for i in count:
		_prev_velocities[i] = velocities[i]
		if inv_mass[i] != 0.0:
			velocities[i] = (positions[i] - prev_positions[i]) / h
	if _any_contact:
		_solve_contact_velocities(h)
	_apply_damping(h, segs)


## One primal pass over the whole rope. Its own method because it is the seam:
## the primal step is block coordinate descent over particles, and the length
## guard exists entirely because that descent needs more sweeps as the rope gets
## finer. An exact solve of the same system would not (the Hessian is block
## tridiagonal — particle i touches only i-1 and i+1 — so block Thomas is O(N)).
## spikes/avbd_direct_rope.gd overrides this and nothing else to measure that.
##
## Sweep direction alternates. Gauss-Seidel carries information one particle per
## sweep in the direction it runs, so a fixed direction would need ~N iterations
## to tell the far end of the rope that the near end is loaded. (A GPU port
## would colour the particles and lose this; a rope on a CPU does not have to.)
func _primal_sweep(it: int, inv_h2: float) -> void:
	var count := positions.size()
	if it % 2 == 0:
		for i in count:
			_solve_particle(i, inv_h2)
	else:
		for i in range(count - 1, -1, -1):
			_solve_particle(i, inv_h2)


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

	if _any_contact:
		var hc := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
		f += _accumulate_contacts(i, rest_lengths.size() + 1, hc)
		h00 += hc[0]
		h01 += hc[1]
		h02 += hc[2]
		h11 += hc[3]
		h12 += hc[4]
		h22 += hc[5]

	positions[i] += _solve_sym3(h00, h01, h02, h11, h12, h22, f)


## Deepest contact per sample, refreshed from the live signed distance field.
func _probe_contacts() -> void:
	var count := positions.size()
	var segs := rest_lengths.size()
	_contact_c.fill(0.0)
	for ci in colliders.size():
		if not _c_near[ci]:
			continue
		var col: Dictionary = colliders[ci]
		var shape: int = col.shape
		var params: Vector3 = col.params
		for i in count:
			if inv_mass[i] != 0.0:
				_probe_sample(col, ci, shape, params, i, i, i)
		for j in segs:
			# Midpoints exist to catch what slips BETWEEN particles. When both
			# endpoints already carry contact, the chord cutting the corner is a
			# discretization artifact a rope bent over a sharp edge is entitled
			# to, and fighting it injects energy every step (ADR 0006, measured
			# on the drape). Same rule, same reason, as the XPBD core.
			if _contact_c[j] > 0.0 and _contact_c[j + 1] > 0.0:
				continue
			if inv_mass[j] != 0.0 or inv_mass[j + 1] != 0.0:
				_probe_sample(col, ci, shape, params, count + j, j, j + 1)


func _probe_sample(col: Dictionary, ci: int, shape: int, params: Vector3,
		s: int, a: int, b: int) -> void:
	var p := positions[a] if a == b else (positions[a] + positions[b]) * 0.5
	var xf := _c_xf[ci]
	var hit := RopeColliders.probe(shape, params, xf, _c_inv[ci], p)
	if not is_finite(hit.w):
		return
	# C > 0 is penetration. Written this way round, not as (distance - radius),
	# so the sign convention and the clamp are identical to a stretched
	# segment's and _solve_particle needs no second code path.
	var c := radius - hit.w
	if c <= _contact_c[s]:
		return
	_contact_c[s] = c
	_contact_n[s] = Vector3(hit.x, hit.y, hit.z)
	_contact_vel[s] = RopeColliders.surface_velocity(col, xf, p)


## Contact rows touching particle i, folded into the same 3x3 local system as
## its segments: its own sample, and the two midpoints it shares.
##
## Every term here lands on particle i's OWN diagonal block, or — for a
## midpoint, whose gradient is split half and half — on the block between i and
## its neighbour, which the segment between them already owns. That is ADR
## 0008's band rule, and it is what keeps the direct block-tridiagonal solve in
## spikes/avbd_direct_rope.gd available.
##
## The curvature term lambda * d2C/dx2 is dropped, unlike the distance
## constraint where it is exact and cheap. For a plane it is exactly zero; for
## a sphere or box face it is the surface's own curvature, which at contact
## scale is small next to the penalty term, and including it would make the
## block indefinite where the surface is convex.
func _accumulate_contacts(i: int, count: int, h: PackedFloat64Array) -> Vector3:
	var f := Vector3.ZERO
	for t in 3:
		var s := i if t == 0 else (count + i - 1 if t == 1 else count + i)
		var w := 1.0 if t == 0 else 0.5
		if t == 1 and i == 0:
			continue
		if t == 2 and i >= count - 1:
			continue
		var c: float = _contact_c[s]
		if c <= 0.0:
			continue
		var k: float = _contact_penalty[s]
		var lam_raw := k * c + _contact_lambda[s]
		var lam := maxf(lam_raw, 0.0)
		if lam_raw < 0.0 and absf(c) > 1e-12:
			k = minf(k, absf(_contact_lambda[s] / c))
		var n: Vector3 = _contact_n[s]
		# grad = dC/dx_i = -n * w, and the force is -grad * lam.
		f += n * (lam * w)
		var kw := k * w * w
		h[0] += kw * n.x * n.x
		h[1] += kw * n.x * n.y
		h[2] += kw * n.x * n.z
		h[3] += kw * n.y * n.y
		h[4] += kw * n.y * n.z
		h[5] += kw * n.z * n.z
	return f


func _update_contact_duals() -> void:
	var floor_n := _hanging_weight()
	# Tolerance is absolute here, not a fraction: a contact's natural scale is
	# the rope's own thickness, so "1% of the radius" plays the part max_stretch
	# plays for a segment. Same derivation, different length scale.
	var tol := maxf(max_stretch * radius, 1e-9)
	for s in _contact_lambda.size():
		var c: float = _contact_c[s]
		if c <= 0.0:
			_contact_lambda[s] = 0.0
			continue
		var lam := _contact_penalty[s] * c + _contact_lambda[s]
		if lam <= 0.0:
			_contact_lambda[s] = 0.0
			continue
		_contact_lambda[s] = minf(lam, max_lambda)
		# Same reasoning as the segment loop above: the static floor drives
		# beta here too, not the live contact multiplier.
		var b := _beta_for_tolerance(floor_n, tol)
		_contact_penalty[s] = minf(_contact_penalty[s] + b * absf(c),
				minf(_contact_penalty[s] * PENALTY_RAMP_MAX, PENALTY_MAX))


## Restitution 0 + Coulomb friction, ONCE per particle after all its contacts —
## per-contact damping made the old rope worse, measured (ADR 0006 decision 6).
## The stick/slide split is that ADR's, unchanged and unre-derived: it was
## measured against two distinct failures and this is not the step at which to
## also reformulate it (ADR 0008 decision 5).
func _solve_contact_velocities(h: float) -> void:
	var count := positions.size()
	for i in count:
		if inv_mass[i] == 0.0:
			continue
		var normal := Vector3.ZERO
		var force := 0.0
		var surface := Vector3.ZERO
		for t in 3:
			var s := i if t == 0 else (count + i - 1 if t == 1 else count + i)
			if t == 1 and i == 0:
				continue
			if t == 2 and i >= count - 1:
				continue
			var share: float = _contact_lambda[s] * (1.0 if t == 0 else 0.5)
			if share <= 0.0 or _contact_c[s] <= 0.0:
				continue
			normal += _contact_n[s] * share
			force += share
			surface = _contact_vel[s]
		if force <= 0.0:
			continue
		var nl := normal.length()
		if nl < 1e-12:
			continue
		var n := normal / nl
		var v_rel := velocities[i] - surface
		var vn := n.dot(v_rel)
		var vt := v_rel - n * vn
		# Friction impulse cap mu * N * h, and in THIS formulation the
		# multiplier already is N in Newtons — no /h^2 rescaling, unlike XPBD.
		var max_dvt := friction * force * h * inv_mass[i]
		var vt_len := vt.length()
		if vt_len <= max_dvt:
			# STUCK: stiction grabs every component, normal included. Keeping
			# projection-manufactured separation speed here is an energy pump
			# (measured as a limit cycle growing 0.02 -> 0.05 m/s on a settled
			# drape). Real separation is driven by the position solve, which
			# re-decides the contact next step anyway.
			velocities[i] = surface
		else:
			# SLIDING: only approach velocity dies, so velocity can still rotate
			# around a corner. Killing both directions unconditionally froze
			# corners so hard even a frictionless rope stopped sliding.
			if vn < 0.0:
				velocities[i] -= n * vn
			velocities[i] -= vt * (max_dvt / vt_len)


## Dual step (Eqs. 11-13): the multiplier absorbs the force the penalty just
## discovered, and the penalty ramps in proportion to the error that remains.
func _update_dual(j: int, b: float) -> void:
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
	# Rate-limit the ramp rather than cap where it ends up. The failure mode is
	# a penalty that overshoots WITHIN one step — with few dual updates per
	# step beta has to be steep, and one steep update puts k far past what the
	# constraint needs, into the regime where the penalty term carries the
	# force and the multiplier ratchets (measured: tension +3e8% at 2
	# iterations). Bounding how fast k may grow kills the overshoot without
	# bounding the converged value, which an absolute cap did at the cost of
	# the cases that were already correct.
	penalties[j] = minf(penalties[j] + b * absf(c),
			minf(penalties[j] * PENALTY_RAMP_MAX, PENALTY_MAX))


## `lam` is always [method _hanging_weight]'s floor now, never a segment's own
## live lambda — see the note in [method _substep]. Measured cost and benefit
## of that change, all headless, same machine, same day (2026-07-23):
##
##   BENEFIT — spikes/spike_g_length_guard.gd part b1, free and loaded,
##   identical configs run before and after: every required_iterations()
##   crossing is UNCHANGED (this file's guard calibration still holds,
##   nothing to re-tune), and every under-budget error shrank, by 2 to 6
##   orders of magnitude at the low end — a 1280-fineness loaded rope at 16
##   iterations read +209431% before this change and +454% after. That is
##   the exact failure this file's own operating-envelope section names at
##   the top: "the multiplier has not converged, the penalty term carries
##   the force, and the reported tension comes out orders of magnitude
##   high." A live, spiking lambda was making that worse, not incidental
##   to it.
##
##   BENEFIT — spikes/spike_i_avbd_contacts.gd, guarded settings (the only
##   supported configuration, [member length_guard] on): frictionless AVBD
##   contact settling improved on every metric measured — clearance 0.0297
##   -> 0.0300 m, worst penetration after settle-time 0.0140 -> 0.0273 m,
##   residual speed 0.582 -> 0.262 m/s.
##
##   COST — spikes/spike_j_impulse.gd's single-hit threshold sweep: a free or
##   lightly loaded rope that survived one hit up to 200 N*s before this
##   change now dies starting at 100 N*s — the ceiling moved down, not up.
##   The realistic range this spike also covers (0.5-20 N*s, this file's own
##   "violent... exactly the sort of thing a player does" reference point)
##   is unchanged. Four repeated 500 N*s hits were already a 100%-diverge
##   case before this change and remain one after — not a regression, but
##   not the fix either, despite what the blow-up narrative on
##   [member MAX_GUESS_STRETCH] implies about repetition specifically. The
##   old, unbounded formula was supplying real — if dangerous — emergency
##   stiffness in exactly this narrow, already-unrealistic corner, and
##   losing it is the price of closing the loop.
##
##   COST — spike_i's own budget sweep, [member length_guard] deliberately
##   OFF with a hand-picked iteration count (a mode this file's own docs say
##   must never be used outside the spike that measures the guard): 16
##   iterations settled badly before this change and diverges outright
##   after.
##
## Net, across both spikes: every SUPPORTED configuration (guard on,
## realistic impulse) is better or unchanged; both costs land on corners the
## rest of this file already documents as out of envelope. Full test gate:
## 6/6 green, catenary and free-fall numbers unchanged to 3 significant
## figures — both were already floor-dominated in steady state, which is
## the point. All four spikes above were A/B'd by reverting to
## maxf(lambda, floor) and back, not run once and assumed.
##
## The penalty ramp that lands a segment at [member max_stretch] under tension
## `lam`. Solving the method's own steady state for beta:
##
##   the multiplier decays to (alpha*gamma) each step and is rebuilt by n_dual
##   updates of k*C, while C itself settles at (1-alpha) of the stretch and the
##   penalty decays to gamma and is rebuilt by n_dual updates of beta*C. Both
##   fixed points together give
##
##     beta = lam (1 - alpha gamma)(1 - gamma) / ( n_dual^2 (1-alpha)^2 e^2 L^2 )
##
## Checked against the value found by sweeping: for a 1250 kg payload on 0.2 m
## segments at 1% this returns 1.14e7, and the sweep's best was 1e7.
func _beta_for(lam: float, seg_len: float) -> float:
	if beta_override > 0.0:
		return beta_override
	return _beta_for_tolerance(lam,
			maxf(max_stretch, 1e-6) * maxf(seg_len, 1e-6))


## The same derivation with the tolerance given in METRES instead of as a
## fraction of a segment. Split out so contacts can use it — their tolerance is
## an absolute penetration depth, not a stretch — without either duplicating
## the formula or making the segment case go through a fraction it does not
## have. Identical arithmetic for the segment call, by construction.
func _beta_for_tolerance(lam: float, tol_m: float) -> float:
	var n_dual := maxf(1.0, floorf(float(_iters) / float(maxi(dual_every, 1))))
	var denom := n_dual * n_dual * pow(1.0 - alpha, 2.0) * pow(maxf(tol_m, 1e-9), 2.0)
	return lam * (1.0 - alpha * gamma) * (1.0 - gamma) / maxf(denom, 1e-30)


## Cap on this step's inertial-guess DEVIATION for particle i (see
## _clamp_deviation). Based on the shorter of the two segments touching the
## particle, so a rope that tapers in resolution is bounded by its finer
## side, not its coarser one.
func _max_guess_disp(i: int) -> float:
	var segs := rest_lengths.size()
	var len_a := rest_lengths[i - 1] if i - 1 >= 0 and i - 1 < segs else -1.0
	var len_b := rest_lengths[i] if i >= 0 and i < segs else -1.0
	var ref := -1.0
	if len_a > 0.0:
		ref = len_a
	if len_b > 0.0 and (ref < 0.0 or len_b < ref):
		ref = len_b
	if ref <= 0.0:
		return INF
	return MAX_GUESS_STRETCH * ref


## Splits particle i's raw one-step displacement `raw[i]` into a locally
## rigid part — the mean of its immediate neighbours' raw displacements,
## excluding i's OWN, so this particle's own kick cannot dilute the reference
## it is measured against — and the deviation from it, and returns the rigid
## part plus that deviation clamped to `cap`.
##
## This, not a clamp on `raw[i]` directly, is what makes the guess Galilean
## invariant: add any common velocity u to every particle (a uniform launch,
## or the shared acceleration of free fall) and every raw[i] shifts by the
## same u * h, so the neighbour MEAN shifts by exactly u * h too — the
## deviation, their difference, is unchanged. A rope moving together, however
## fast, never has its motion clamped; only a particle moving relative to its
## own neighbourhood does, which is the only thing that can actually produce
## an unresolvable constraint error (spikes/spike_l_galilean.gd).
func _clamp_deviation(i: int, raw: PackedVector3Array, cap: float) -> Vector3:
	var neighbor_sum := Vector3.ZERO
	var neighbor_count := 0
	if i - 1 >= 0:
		neighbor_sum += raw[i - 1]
		neighbor_count += 1
	if i + 1 < raw.size():
		neighbor_sum += raw[i + 1]
		neighbor_count += 1
	var rigid := neighbor_sum / float(neighbor_count) if neighbor_count > 0 else raw[i]
	var deviation := raw[i] - rigid
	var dev_len := deviation.length()
	if dev_len > cap and dev_len > 1e-12:
		deviation *= cap / dev_len
	return rigid + deviation


## Weight the rope carries with nothing attached — the smallest tension any
## segment has to hold, used as the floor when deriving beta.
func _hanging_weight() -> float:
	var total := 0.0
	for i in inv_mass.size():
		if inv_mass[i] > 0.0:
			total += 1.0 / inv_mass[i]
	return total * gravity.length()


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
