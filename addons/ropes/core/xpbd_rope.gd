extends RefCounted
# XPBD rope solver — reference implementation. Pure math over arrays: no
# nodes, no physics server, no scene tree. The future C++ core replicates
# this exact contract; tests pin its behavior (ADR 0001, 0002).
#
# Units: meters, kilograms, seconds, Newtons. Tension comes from XPBD
# Lagrange multipliers (force = -lambda / h^2), never estimated from
# geometry. Rope constraints are unilateral: they resist stretch, never
# compression.
#
# Collision (ADR 0006): the host pushes nearby colliders as pure data once
# per tick; every substep this core evaluates exact signed distances to
# them analytically, with collider transforms interpolated across substeps
# from body velocities. Contacts are unilateral constraint rows solved in
# the SAME iteration loop as distance constraints. Friction is Coulomb,
# capped by the accumulated contact force, applied once per particle after
# all its contacts. Restitution is 0.
#
# Array ownership: every public array is BORROWED, valid until the next
# step(). Copy what you need to keep. The C++ core exposes the same buffers
# without allocating per tick.
#
# Validity domain: constraint violations are assumed small relative to a
# segment's rest length within one substep. Moving a pin further than that
# in a single step leaves the domain — use teleport() for jumps (ADR 0004).

const MIN_MASS := 1e-6

## Narrow phase lives in one file for every core (ADR 0008): two solvers may
## disagree about how to solve a contact, never about where the surface is.
const RopeColliders := preload("res://addons/ropes/core/rope_colliders.gd")

## Re-exported so the host (nodes/rope_3d.gd) keeps addressing shapes through
## the core it drives rather than reaching past it.
const SHAPE_PLANE := RopeColliders.SHAPE_PLANE
const SHAPE_SPHERE := RopeColliders.SHAPE_SPHERE
const SHAPE_BOX := RopeColliders.SHAPE_BOX

var positions := PackedVector3Array()
var prev_positions := PackedVector3Array()
var velocities := PackedVector3Array()
var inv_mass := PackedFloat64Array()
var rest_lengths := PackedFloat64Array()
var lambdas := PackedFloat64Array()   # accumulated within a substep, <= 0
var tensions := PackedFloat64Array()  # N, from the last substep's lambdas

var gravity := Vector3(0, -9.8, 0)

## Stretch compliance in m/N. 0 = as stiff as the budget allows.
var stretch_compliance := 0.0

## Internal damping, 1/s. Decays the RELATIVE velocity of neighboring
## particles — the rope's own fiber friction. Galilean invariant: it cannot
## slow a rope that falls or flies as a whole, only one that stretches,
## bends or vibrates (ADR 0003).
var damping := 0.5

## Aerodynamic drag, 1/s. Decays ABSOLUTE velocity, so it does impose a
## terminal speed of |gravity| / drag — that is what air does. 0 = vacuum.
var drag := 0.0

## Contact thickness: particles keep this distance from collider surfaces.
var radius := 0.02

## Coulomb friction coefficient against all colliders (per-collider values
## can arrive later; one honest knob for now).
var friction := 0.6

var substeps := 8
var iterations := 1

## Colliders near the rope, pushed by the host once per tick. Each entry:
## { shape: int, params: Vector3, xform: Transform3D, prev_xform:
##   Transform3D, linear_velocity: Vector3, angular_velocity: Vector3 }
## prev_xform is last tick's transform: the core interpolates between them
## across substeps (ADR 0006). Basis must be orthonormal (no scaled shapes).
var colliders: Array[Dictionary] = []

# Per-particle contact accumulators, valid within one substep.
var _contact_lambda := PackedFloat64Array()
var _contact_normal := PackedVector3Array()
var _contact_vel := PackedVector3Array()

# Interpolated collider state for the current substep.
var _c_xf: Array[Transform3D] = []
var _c_inv: Array[Transform3D] = []
var _c_near: Array[bool] = []


func setup(segment_count: int, total_length: float, mass_per_meter: float) -> void:
	assert(segment_count >= 1, "rope needs at least one segment")
	assert(total_length > 0.0, "rope length must be positive")
	assert(mass_per_meter > 0.0, "mass_per_meter must be positive")
	var count := segment_count + 1
	positions.resize(count)
	prev_positions.resize(count)
	velocities.resize(count)
	inv_mass.resize(count)
	rest_lengths.resize(segment_count)
	lambdas.resize(segment_count)
	tensions.resize(segment_count)
	_contact_lambda.resize(count)
	_contact_normal.resize(count)
	_contact_vel.resize(count)
	velocities.fill(Vector3.ZERO)
	lambdas.fill(0.0)
	tensions.fill(0.0)
	var seg_rest := total_length / segment_count
	rest_lengths.fill(seg_rest)
	# Lumped masses: each particle carries half of each adjacent segment.
	var seg_mass := maxf(mass_per_meter, MIN_MASS) * seg_rest
	for i in count:
		var m := seg_mass if (i > 0 and i < count - 1) else seg_mass * 0.5
		inv_mass[i] = 1.0 / maxf(m, MIN_MASS)


## Lay particles along a straight line from a to b, at rest.
##
## [param jitter] is a lateral offset in meters modelling the fact that no
## real rope is manufactured perfectly straight. It exists for one reason:
## an axially compressed column is in UNSTABLE equilibrium (Euler
## buckling), and a mathematically perfect line never leaves it — a rope
## dropped exactly end-first telescopes into itself instead of toppling
## into a heap. Neither self-contact nor bending stiffness can break that
## symmetry: a collinear column satisfies both. The seed must come from
## the rope's shape, so it lives here in seeding, never in step().
##
## The pattern is a fixed function of particle index, so determinism holds.
## Keep it far below anything observable (Rope3D uses 0.1 mm); pass 0 for a
## mathematically exact line, as the analytic tests do.
func lay_line(a: Vector3, b: Vector3, jitter := 0.0) -> void:
	var count := positions.size()
	var axis := b - a
	var u := Vector3.ZERO
	var v := Vector3.ZERO
	if jitter != 0.0 and axis.length_squared() > 1e-18:
		var dir := axis.normalized()
		u = dir.cross(Vector3.UP)
		if u.length_squared() < 1e-12:
			u = dir.cross(Vector3.RIGHT)
		u = u.normalized()
		v = dir.cross(u)
	for i in count:
		var p := a.lerp(b, float(i) / float(count - 1))
		if jitter != 0.0:
			p += u * (jitter * sin(i * 1.7)) + v * (jitter * sin(i * 2.3))
		positions[i] = p
	prev_positions = positions.duplicate()
	velocities.fill(Vector3.ZERO)


func pin(index: int) -> void:
	inv_mass[index] = 0.0


## Add lumped mass in kg to one particle (a hook, a weight).
func add_point_mass(index: int, extra_kg: float) -> void:
	assert(extra_kg >= 0.0, "point mass must not be negative")
	if inv_mass[index] > 0.0:
		inv_mass[index] = 1.0 / maxf(1.0 / inv_mass[index] + extra_kg, MIN_MASS)


## Move a pinned particle that is TRAVELING (an anchor on a moving crane).
## Its velocity is the damping reference for the rest of the rope, so pass
## the anchor's real velocity; for a jump use [method teleport] instead.
func move_pin(index: int, to: Vector3, velocity := Vector3.ZERO) -> void:
	positions[index] = to
	prev_positions[index] = to
	velocities[index] = velocity


## Rigidly move the whole rope by delta. Use when an anchor JUMPS (level
## load, respawn, parent teleport): shape and velocities survive and no
## constraint violation is manufactured, so no transient is injected.
func teleport(delta: Vector3) -> void:
	for i in positions.size():
		positions[i] += delta
		prev_positions[i] += delta


func apply_impulse(index: int, impulse: Vector3) -> void:
	velocities[index] += impulse * inv_mass[index]


func step(dt: float) -> void:
	if not (dt > 0.0) or not is_finite(dt):
		return
	var count := positions.size()
	var segs := rest_lengths.size()
	var h := dt / float(substeps)
	var h2 := h * h
	var alpha := stretch_compliance / h2
	var have_contacts := not colliders.is_empty()
	if have_contacts:
		have_contacts = _cull_colliders(dt)
	for s in substeps:
		for i in count:
			if inv_mass[i] == 0.0:
				prev_positions[i] = positions[i]
				continue
			velocities[i] += gravity * h
			prev_positions[i] = positions[i]
			positions[i] += velocities[i] * h
		lambdas.fill(0.0)
		if have_contacts:
			_contact_lambda.fill(0.0)
			_contact_normal.fill(Vector3.ZERO)
			_contact_vel.fill(Vector3.ZERO)
			# End of this substep in tick time: substeps sweep prev -> curr.
			_interpolate_colliders(float(s + 1) / float(substeps))
		for _it in iterations:
			# Red-black sweep: no two segments of the same color share a
			# particle, so the result cannot depend on traversal order and
			# each color is a parallel batch for the C++ port (ADR 0005).
			for j in range(0, segs, 2):
				_solve_segment(j, alpha)
			for j in range(1, segs, 2):
				_solve_segment(j, alpha)
			if have_contacts:
				_solve_contacts()
		for i in count:
			if inv_mass[i] != 0.0:
				velocities[i] = (positions[i] - prev_positions[i]) / h
		if have_contacts:
			_solve_contact_velocities(h)
		_apply_damping(h, segs)
	for j in segs:
		assert(lambdas[j] <= 0.0, "tension lambda must be non-positive")
		tensions[j] = -lambdas[j] / h2


func _solve_segment(j: int, alpha: float) -> void:
	var wi := inv_mass[j]
	var wj := inv_mass[j + 1]
	var w := wi + wj
	if w == 0.0 and alpha == 0.0:
		# Rigid segment between two pins: the constraint force is unbounded
		# and no position can move. Tension stays 0, meaning "no reading".
		return
	var d := positions[j + 1] - positions[j]
	var seg_len := d.length()
	if seg_len < 1e-12:
		return
	# Capped at half the rest length. Two radii is the right floor only while
	# the rope is coarse relative to its own thickness: a user who sets a
	# fat radius on a coarse rope can make 2r exceed the rest length, and
	# then the two projections have no common solution — separation pushes
	# past rest, tension pulls back, every substep, forever. The cap keeps
	# the floor in "this is a fold, not a mild squeeze" territory at any
	# resolution, and never contradicts the rest length.
	var min_sep := minf(2.0 * radius, rest_lengths[j] * 0.5)
	if seg_len < min_sep:
		# The rope has thickness against ITSELF, not only against the world.
		# Neighbours cannot come closer than two radii any more than a real
		# rope can fold through its own body. Without this a rope dropped
		# end-first collapses to a single point — measured: polyline length
		# 4.0 m -> 0.0 m in under 3 s (2026-07-23). This is the local half
		# of self-contact; the general pair case stays deferred (ADR 0006).
		# A squashed segment carries no tension, so lambda is untouched.
		if w == 0.0:
			return
		var apart := (min_sep - seg_len) / w
		var sep_dir := d / seg_len
		positions[j] -= sep_dir * (apart * wi)
		positions[j + 1] += sep_dir * (apart * wj)
		return
	var c := seg_len - rest_lengths[j]
	var dl := (-c - alpha * lambdas[j]) / (w + alpha)
	if lambdas[j] + dl > 0.0:  # unilateral: tension only
		dl = -lambdas[j]
	lambdas[j] += dl
	if w == 0.0:
		return  # compliant segment between two pins: force known, no motion
	var dir := d / seg_len
	positions[j] -= dir * (dl * wi)
	positions[j + 1] += dir * (dl * wj)


# --- collision -------------------------------------------------------------


## Bounding-sphere reject, once per step. Without it every particle is tested
## against every collider on every substep, so a rope hanging in mid-air pays
## full price for the ground five meters below it. Returns false if nothing
## is in reach at all.
func _cull_colliders(dt: float) -> bool:
	return RopeColliders.cull(colliders, positions, radius, max_speed() * dt, _c_near)


func _interpolate_colliders(t: float) -> void:
	RopeColliders.interpolate(colliders, t, _c_near, _c_xf, _c_inv)


func _solve_contacts() -> void:
	var count := positions.size()
	for ci in colliders.size():
		if not _c_near[ci]:
			continue
		var col: Dictionary = colliders[ci]
		var shape: int = col.shape
		var params: Vector3 = col.params
		# Detection samples: every particle, then every segment midpoint —
		# spacing of half a segment is the honest resolution limit (ADR 0006).
		for i in count:
			_contact_sample(ci, shape, params, i, i)
		for j in rest_lengths.size():
			# Midpoints exist to catch what slips BETWEEN particles (an edge
			# poking into the gap). When both endpoints already carry
			# contact, the chord cutting the corner is a discretization
			# artifact of a rope bent over a sharp edge — at 20 cm segments
			# the chord MUST cut a 90-degree corner. Fighting it injects
			# energy every substep (measured: the drape never settled and
			# even a frictionless rope jammed on the edge).
			if _contact_lambda[j] > 0.0 and _contact_lambda[j + 1] > 0.0:
				continue
			_contact_sample(ci, shape, params, j, j + 1)


func _contact_sample(ci: int, shape: int, params: Vector3, a: int, b: int) -> void:
	var wa := inv_mass[a]
	var wb := inv_mass[b]
	var midpoint := a != b
	var w_eff: float
	var p: Vector3
	if midpoint:
		w_eff = 0.25 * (wa + wb)
		if w_eff == 0.0:
			return
		p = (positions[a] + positions[b]) * 0.5
	else:
		w_eff = wa
		if w_eff == 0.0:
			return
		p = positions[a]

	var xf := _c_xf[ci]
	var hit := RopeColliders.probe(shape, params, xf, _c_inv[ci], p)
	if not is_finite(hit.w):
		return
	var pen := radius - hit.w
	if pen <= 0.0:
		return
	var n := Vector3(hit.x, hit.y, hit.z)
	var dl := pen / w_eff
	var col: Dictionary = colliders[ci]
	var surface_vel := RopeColliders.surface_velocity(col, xf, p)
	if midpoint:
		positions[a] += n * (dl * 0.5 * wa)
		positions[b] += n * (dl * 0.5 * wb)
		_note_contact(a, dl * 0.5, n, surface_vel)
		_note_contact(b, dl * 0.5, n, surface_vel)
	else:
		positions[a] += n * (dl * wa)
		_note_contact(a, dl, n, surface_vel)


func _note_contact(i: int, lambda_share: float, n: Vector3, surface_vel: Vector3) -> void:
	_contact_lambda[i] += lambda_share
	_contact_normal[i] += n * lambda_share
	_contact_vel[i] = surface_vel


## Restitution 0 + Coulomb friction, ONCE per particle after all its
## contacts — per-contact damping made the old rope worse, measured.
func _solve_contact_velocities(h: float) -> void:
	for i in positions.size():
		if _contact_lambda[i] <= 0.0 or inv_mass[i] == 0.0:
			continue
		var nl := _contact_normal[i].length()
		if nl < 1e-12:
			continue
		var n := _contact_normal[i] / nl
		var v_rel := velocities[i] - _contact_vel[i]
		var vn := n.dot(v_rel)
		var vt := v_rel - n * vn
		# Friction impulse cap: mu * N * h, with N = lambda / h^2.
		var max_dvt := friction * _contact_lambda[i] / h * inv_mass[i]
		var vt_len := vt.length()
		if vt_len <= max_dvt:
			# STUCK: static friction won, and stiction grabs every
			# component — normal velocity dies in both directions. Keeping
			# projection-manufactured separation speed here is an energy
			# pump (constraint pulls in, contact pushes out, reconstruction
			# books the push as velocity): measured as a limit cycle
			# growing 0.02 -> 0.05 m/s on a settled drape. Real separation
			# is delayed one substep at most: no penetration, no row.
			velocities[i] = _contact_vel[i]
		else:
			# SLIDING: inelastic in approach only. The separating component
			# must survive — it is how velocity rotates while rounding a
			# corner; killing it froze even a frictionless rope on the box
			# (measured).
			if vn < 0.0:
				vn = 0.0
			vt -= vt * (max_dvt / vt_len)
			velocities[i] = _contact_vel[i] + n * vn + vt


# --- damping ---------------------------------------------------------------


func _apply_damping(h: float, segs: int) -> void:
	if damping > 0.0:
		# Exponential decay of relative velocity; momentum-conserving, so
		# uniform motion of the whole rope is untouched.
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


# --- readbacks -------------------------------------------------------------


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
