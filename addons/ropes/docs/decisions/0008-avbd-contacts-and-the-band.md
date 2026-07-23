# 0008: Contacts for AVBD, and the band they must stay inside

Date: 2026-07-23. Status: proposed.

## Context

ADR 0006 settled the collision architecture and it is measured, shipped and
regression-tested against the old rope's killer scenario. ADR 0007 adopted AVBD
for load-bearing ropes and named contacts as the one thing blocking it: "until
that lands AVBD cannot replace XPBD for anything that touches the world."

So contacts for AVBD are the next work either way. This ADR exists because
something changed underneath that work in the last day, and it changes what the
contact rows are allowed to look like.

`spikes/spike_g_length_guard.gd` measured why AVBD's tension readout degrades
with rope size, and found it is not the segment count but *fineness*,
`M = segments / segment_length`. The guard that came out of it raises iterations
as `0.85 * M^0.5` free hanging and `1.15 * M^0.6` loaded — real money: a 50 m
rope carrying 250 kg goes from 16 iterations to 64.

`spikes/spike_h_direct_primal.gd` then asked whether that tax is inherent or an
artifact of *how* the primal step is solved. AVBD's primal Hessian is block
tridiagonal — particle `i` couples to `i-1` and `i+1` through its two segments
and to nothing else — and the method solves it by Gauss-Seidel over those 3x3
blocks. Replacing that sweep with an exact block-Thomas solve, changing nothing
else, collapses the guard's rule to the iteration floor across a 16x range in
fineness:

| rope | M | sweep | direct |
|---|---|---|---|
| 20 m, 4/m, 250 kg | 320 | 32 iterations, +7.0% | **8**, +0.0% |
| 5 m, 16/m, 250 kg | 1280 | 64 iterations, +8.0% | **8**, -0.0% |
| 50 m, 4/m, 250 kg | 800 | 48 iterations, +7.3% | **12**, -1.0% |

Two pinned ends and a fully slack rope — the two cases a frozen active set
should have broken — came back indistinguishable from the sweep, and no block
came back singular.

It is not a clean win, and this ADR would be dishonest to imply it is. On
jitter — the column AVBD was actually adopted for — the direct solve is 40x
quieter on the 20 m rope (0.06 mm against 2.55 mm) and then *loses* on the
50 m one: its jitter plateaus near 3.4 mm while the sweep's keeps falling to
1.53 mm at 48 iterations. Scaling the Newton step to damp it makes the method
diverge outright, because the dual update and the derived beta both assume the
primal step reaches its minimum. So the exact step buys tension convergence
cheaply and does not, today, buy quiet on long ropes.

That result is not shipped and may never be. But it is worth **keeping
available**, and it is available only for as long as every constraint row stays
inside the tridiagonal band. Contacts are what is about to add rows. Written one
way they leave the door open; written another way they close it permanently and
nobody will notice for six months.

## Decision

**1. A contact is an AVBD row, not a projection bolted onto one.**

`C(x_i) = sd(x_i) - radius >= 0`, unilateral, with its own multiplier
`lambda_c >= 0` and its own ramped penalty, warm-started across frames exactly
like a distance row. This is native to the formulation — bounds on the
multiplier per row are how the paper does contact — and it is the same property
that made AVBD worth adopting: the holding force lives in a multiplier that
survives the frame instead of being rediscovered from positional error every
frame. A rope lying on a box should be quiet for the same structural reason a
rope holding a rover is quiet (13x less jitter, ADR 0007).

**2. The narrow phase is reused verbatim from ADR 0006.**

Broadphase once per tick, exact analytic signed distance per substep to cached
*colliders* rather than cached contacts, collider transforms interpolated across
substeps from body velocities, particle plus segment-midpoint samples with
barycentric distribution, and the measured corner-chord rule (midpoint samples
act only when at least one endpoint is contact-free). None of that geometry
knows or cares which solver is asking. Sharing it is also the only thing that
keeps the two-core maintenance cost ADR 0007 accepted from doubling in practice.

**3. Every contact row must touch only the block-tridiagonal band.**

This is the rule this ADR exists to state. For each kind of row, the blocks it
writes:

| row | blocks written | inside the band |
|---|---|---|
| particle vs world | rank-1 update on that particle's own diagonal | yes |
| friction at that contact | same particle, same diagonal block | yes |
| midpoint sample, distributed barycentrically to `i` and `i+1` | diagonals of `i` and `i+1`, plus the `(i, i+1)` coupling that segment already owns | yes |
| neighbour thickness, `|x_i - x_i+1| >= 2r` | identical structure to a distance row | yes |
| capsule/segment vs world (the C++ narrow-phase refinement) | same two endpoints as the midpoint case | yes |
| general pairwise self-contact, non-adjacent `i` and `j` | a block at `(i, j)` arbitrarily far off the diagonal | **no** |

So the entire contact set ADR 0006 specifies — including the capsule narrow
phase it defers to the C++ port — is compatible with a direct solve. Only
general self-contact is not, and ADR 0006 decision 8 already defers that.

**4. When general self-contact comes, it is a separate pass, not a row in the
same matrix.** The banded system is solved as one; the off-band pairs are then
relaxed by Gauss-Seidel on top. This is a constraint on a future gate, recorded
now because the alternative — discovering it after the direct solve is load
bearing — is expensive.

**5. Friction ships as ADR 0006 already measured it, not reformulated.**

ADR 0006's stick/slide split at the velocity stage was derived from two distinct
measured failure modes (a settled drape's limit cycle growing 0.02 -> 0.05 m/s
when only approach velocity is killed; corners freezing so hard a frictionless
rope stopped sliding when both directions are killed unconditionally). Native
AVBD friction — a tangential multiplier bounded by `mu * lambda_n` inside the
same solve — is better and also stays on the diagonal, so rule 3 permits it.
It is still not first: changing the normal rows and the friction model in the
same step means two changes and one test, and the test in question is the one
that took the longest to earn. Native friction is the follow-up, measured
separately, against the same bar.

**6. The bar is `tests/test_drape.gd`, unchanged, run against AVBD.**

An asymmetric drape over a box must settle, hold, not creep, not penetrate, and
slide off only at zero friction. XPBD's current numbers are the target to match
or beat: settled at 0.019 m/s, creep 0.0011 m over four seconds, particle
clearance exactly one radius, peak tension within 1.4% of the analytic hang
weight, and com.y = -34.1 at mu = 0. AVBD is expected to be markedly quieter on
the settle and creep columns; if it is not, that is a finding, because quiet is
the entire reason it was adopted.

**7. A new analytic arbiter: the capstan equation.**

Every claim this project trusts has an analytic answer behind it — catenary for
shape and tension, free fall for the damping model, the constitutive relation
for compliance. ADR 0006's central friction claim, "static friction is what
makes a wrap hold", has no such answer behind it; it is checked only by a drape
that stays put. The capstan (Euler-Eytelwein) relation `T2 = T1 * e^(mu * theta)`
gives one: wrap a rope around a cylinder through a known angle, pull one end,
and the other end's tension is determined. It tests the narrow phase, the
friction model and the tension readout simultaneously, and it is exactly the
kind of test that separates a rope from a decoration. It is written once and
serves both cores.

**8. Unchanged from ADR 0006 and not reopened here:** restitution 0, the
velocity fix running once per particle after all its contacts, one-way coupling
at this gate, doubles internally regardless of engine precision, unsupported
shapes skipped with a one-time warning.

## Consequences

- Both cores will have contacts, so the maintenance cost ADR 0007 knowingly
  took on becomes real rather than theoretical. Decision 2 is the mitigation and
  it should be watched: the moment the narrow phase forks per solver, that bet
  has been lost.
- The direct primal solve stays available at no cost today. If it is later
  adopted, the length guard from ADR 0007 does not disappear — its rule shrinks
  toward the floor, but the mechanism (measure, clamp, warn) and its test stay,
  and they are what would catch a contact row that quietly breaks the band.
- The capstan test is new work with no existing scaffolding, and it may well
  fail first time on the current point-sample narrow phase, since a wrap is
  precisely the geometry where sample spacing against a curved surface bites.
  That is a reason to write it, not a reason to defer it.
- `get_segment_tension()` stays about segments. A contact multiplier is also a
  force in Newtons and will be tempting to expose through the same call; it must
  not be, or the one number this addon promises stops meaning one thing.
- Rule 3 is a constraint on code that does not exist yet, which is the weakest
  kind of decision to enforce. The enforcement plan is that the direct core in
  `spikes/avbd_direct_rope.gd` keeps working: it overrides `_primal_sweep` and
  nothing else, so a contact row written outside the band will make it visibly
  wrong rather than silently slower.
