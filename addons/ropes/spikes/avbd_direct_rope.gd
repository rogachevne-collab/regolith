extends "res://addons/ropes/core/avbd_rope.gd"
# AVBD with the primal step solved DIRECTLY instead of swept.
#
# Everything else is the parent's: same augmented-Lagrangian energy, same
# warm-started multipliers, same unilateral clamp, same derived beta, same dual
# step. The only difference is [method _primal_sweep], and it is the difference
# the length guard exists because of.
#
# The idea is Deul, Kugelstadt, Weiler, Bender, *Direct Position-Based Solver
# for Stiff Rods*, CGF 37(6), 2018 — but NOT a port of it. The paper solves a
# Cosserat rod's whole constraint system inside XPBD; what is borrowed is the
# one structural observation underneath it: a chain's system is block
# tridiagonal, so it can be solved exactly in O(N) by the Thomas algorithm
# instead of iterated. Here the system being solved is AVBD's own primal
# Hessian, which is already block tridiagonal — particle i couples to i-1 and
# i+1 through its two segments and to nothing else. The parent visits those
# 3x3 blocks one at a time (Gauss-Seidel); this visits them once, forward and
# back, and lands on the exact Newton step for the whole rope.
#
# Why it should matter: the guard's rule is `iterations >= 0.85 * M^0.5` free
# and `1.15 * M^0.6` loaded, where M is fineness. If the sweep count is what
# fineness taxes, an exact solve should collapse that rule to the floor of 8.
# If it does not, the tax is somewhere else — in the beta derivation — and that
# is worth knowing too, because it says the guard is load-bearing rather than a
# workaround for a solvable problem.
#
# Measured by spikes/spike_h_direct_primal.gd.
#
# HONEST CAVEATS, up front:
#  - The active set is frozen for the duration of one solve. A segment that is
#    slack when the blocks are assembled stays slack until the next iteration,
#    where the parent would have noticed mid-sweep. This is standard for an
#    active-set Newton and it is the most likely place for this to misbehave.
#  - One global Newton step can overshoot where N small local ones cannot;
#    [member relax] exists to find out whether that happens.
#  - Cost per iteration is higher: ~1 inverse and 2 matrix products per particle
#    against one 3x3 solve. It has to win on iteration COUNT or not at all, and
#    in GDScript the comparison is unfair to it besides (blocks live in a
#    PackedFloat64Array by hand because Basis has no addition operator).

## Damping on the global step, 1..0. 1.0 is the plain Newton step.
##
## MEASURED, AND THE ANSWER IS: LEAVE IT AT 1.0. It was added to test whether
## the direct step's jitter floor on long ropes (part 4 of the spike: 3.4 mm
## where the sweep reaches 1.53 mm) is a Newton step overshooting. It is not,
## or at least this does not fix it — 0.8, 0.6 and 0.4 all DIVERGE outright on
## the 50 m / 250 kg rope where 1.0 settles at -3.3%.
##
## Most likely reason, and it is a warning about the whole method rather than
## about this knob: the dual step and the derived beta both assume the primal
## step actually reaches its minimum. beta is solved from a steady state in
## which n_dual updates of size beta*C rebuild the penalty (see the parent's
## _beta_for). Under-solve the primal and C stays large every iteration, so the
## penalty ramps on an error that was never going to be corrected, and the
## multiplier ratchets — the same failure the length guard exists to prevent,
## reached from the other direction. A step-size knob is not free here; if the
## jitter floor is ever chased, it has to be chased with something the dual can
## still trust, such as a line search on the actual energy.
var relax := 1.0

## Set when a block turned out singular and the step fell back to the parent's
## sweep — a diagnostic, because a silent fallback would make this file look
## like it worked.
var fallbacks := 0

# 3x3 blocks, row-major, 9 doubles each, indexed 9 * particle.
var _dg := PackedFloat64Array()   # diagonal block H[i,i]
var _up := PackedFloat64Array()   # off-diagonal block H[i,i+1]; H[i+1,i] is its
                                  # transpose, and it is symmetric, so the same
var _uu := PackedFloat64Array()   # Thomas U_i
var _zz := PackedVector3Array()   # Thomas z_i
var _dx := PackedVector3Array()

# Scratch, allocated once. GDScript pays for every array it creates, and this
# code runs per segment per iteration — a spike that measures its own allocator
# is not measuring the method.
var _a9 := PackedFloat64Array()
var _t9 := PackedFloat64Array()
var _i9 := PackedFloat64Array()
var _p9 := PackedFloat64Array()


func _primal_sweep(_it: int, inv_h2: float) -> void:
	var count := positions.size()
	if _zz.size() != count:
		_dg.resize(count * 9)
		_up.resize(count * 9)
		_uu.resize(count * 9)
		_zz.resize(count)
		_dx.resize(count)
		_a9.resize(9)
		_t9.resize(9)
		_i9.resize(9)
		_p9.resize(9)

	_assemble(count, inv_h2)
	if not _thomas(count):
		# Fall back rather than leave the rope where a singular block left it.
		fallbacks += 1
		super._primal_sweep(_it, inv_h2)
		return
	for i in count:
		if inv_mass[i] != 0.0:
			positions[i] += _dx[i] * relax


# --- assembly ---------------------------------------------------------------

## H and its right-hand side, built exactly as [method _solve_particle] builds
## its 3x3 block — same k, same clamped lambda, same stiffness rescaling, same
## exact d2C/dx2. If these two ever disagree, this file is measuring a
## different solver and the comparison is worthless, so the arithmetic below is
## deliberately a transcription rather than a rewrite.
func _assemble(count: int, inv_h2: float) -> void:
	for i in count:
		var o := i * 9
		var m_over_h2 := 0.0
		if inv_mass[i] != 0.0:
			m_over_h2 = inv_h2 / inv_mass[i]
			_zz[i] = (_inertial[i] - positions[i]) * m_over_h2
		else:
			# Pinned: a Dirichlet row. Identity block, zero force, and the
			# couplings to it are cleared below — dx is then exactly zero and
			# the neighbours keep the stiffness the pin gives them.
			m_over_h2 = 1.0
			_zz[i] = Vector3.ZERO
		for e in 9:
			_dg[o + e] = 0.0
			_up[o + e] = 0.0
		_dg[o] = m_over_h2
		_dg[o + 4] = m_over_h2
		_dg[o + 8] = m_over_h2

	for j in rest_lengths.size():
		var d := positions[j + 1] - positions[j]
		var seg_len := d.length()
		if seg_len < 1e-12:
			continue
		var dir := d / seg_len
		var c := seg_len - rest_lengths[j] - alpha * _c0[j]
		var k := penalties[j]
		var lam_raw := k * c + lambdas[j]
		var lam := maxf(lam_raw, 0.0)
		if lam_raw < 0.0 and absf(c) > 1e-12:
			k = minf(k, absf(lambdas[j] / c))
		var g := lam / seg_len

		# A = k dd^T + g (I - dd^T): the segment's contribution. It lands on
		# both endpoints' diagonals and, negated, on the block between them.
		var kg := k - g
		_a9[0] = kg * dir.x * dir.x + g
		_a9[1] = kg * dir.x * dir.y
		_a9[2] = kg * dir.x * dir.z
		_a9[3] = _a9[1]
		_a9[4] = kg * dir.y * dir.y + g
		_a9[5] = kg * dir.y * dir.z
		_a9[6] = _a9[2]
		_a9[7] = _a9[5]
		_a9[8] = kg * dir.z * dir.z + g
		var oj := j * 9
		var ok := (j + 1) * 9
		for e in 9:
			_dg[oj + e] += _a9[e]
			_dg[ok + e] += _a9[e]
			_up[oj + e] = -_a9[e]

		# grad = dC/dx: -dir at the near end, +dir at the far one, and the
		# force is -grad * lam.
		_zz[j] += dir * lam
		_zz[j + 1] -= dir * lam

	# Clear the couplings of pinned particles, in both directions. dx is zero
	# there, so those blocks contribute nothing and keeping them would only
	# make the tridiagonal solve carry a row it must not move.
	for i in count:
		if inv_mass[i] != 0.0:
			continue
		var o := i * 9
		for e in 9:
			_up[o + e] = 0.0
			if i > 0:
				_up[o - 9 + e] = 0.0
		_zz[i] = Vector3.ZERO
		for e in 9:
			_dg[o + e] = 0.0
		_dg[o] = 1.0
		_dg[o + 4] = 1.0
		_dg[o + 8] = 1.0


# --- block Thomas -----------------------------------------------------------

## Forward elimination and back substitution over 3x3 blocks. O(N) with one
## 3x3 inverse per particle, which is the whole point: no sweep count anywhere.
func _thomas(count: int) -> bool:
	var t := _t9
	var inv := _i9
	var tmp := _p9

	for i in count:
		var o := i * 9
		# T = H[i,i] - H[i,i-1] * U[i-1]
		for e in 9:
			t[e] = _dg[o + e]
		var rhs := _zz[i]
		if i > 0:
			_mul(_up, o - 9, _uu, o - 9, tmp, 0)
			for e in 9:
				t[e] -= tmp[e]
			rhs -= _xform(_up, o - 9, _zz[i - 1])
		if not _inverse(t, inv):
			return false
		# U[i] = T^-1 H[i,i+1];  z[i] = T^-1 rhs
		_mul(inv, 0, _up, o, _uu, o)
		_zz[i] = _xform(inv, 0, rhs)

	_dx[count - 1] = _zz[count - 1]
	for i in range(count - 2, -1, -1):
		_dx[i] = _zz[i] - _xform(_uu, i * 9, _dx[i + 1])
	return true


func _mul(a: PackedFloat64Array, ao: int, b: PackedFloat64Array, bo: int,
		out: PackedFloat64Array, oo: int) -> void:
	for r in 3:
		for cc in 3:
			out[oo + r * 3 + cc] = (a[ao + r * 3] * b[bo + cc]
					+ a[ao + r * 3 + 1] * b[bo + 3 + cc]
					+ a[ao + r * 3 + 2] * b[bo + 6 + cc])


func _xform(a: PackedFloat64Array, ao: int, v: Vector3) -> Vector3:
	return Vector3(
		a[ao] * v.x + a[ao + 1] * v.y + a[ao + 2] * v.z,
		a[ao + 3] * v.x + a[ao + 4] * v.y + a[ao + 5] * v.z,
		a[ao + 6] * v.x + a[ao + 7] * v.y + a[ao + 8] * v.z,
	)


func _inverse(m: PackedFloat64Array, out: PackedFloat64Array) -> bool:
	var c00 := m[4] * m[8] - m[5] * m[7]
	var c01 := m[5] * m[6] - m[3] * m[8]
	var c02 := m[3] * m[7] - m[4] * m[6]
	var det := m[0] * c00 + m[1] * c01 + m[2] * c02
	if absf(det) < 1e-30 or not is_finite(det):
		return false
	var inv_det := 1.0 / det
	out[0] = c00 * inv_det
	out[1] = (m[2] * m[7] - m[1] * m[8]) * inv_det
	out[2] = (m[1] * m[5] - m[2] * m[4]) * inv_det
	out[3] = c01 * inv_det
	out[4] = (m[0] * m[8] - m[2] * m[6]) * inv_det
	out[5] = (m[2] * m[3] - m[0] * m[5]) * inv_det
	out[6] = c02 * inv_det
	out[7] = (m[1] * m[6] - m[0] * m[7]) * inv_det
	out[8] = (m[0] * m[4] - m[1] * m[3]) * inv_det
	return true
