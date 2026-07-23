# Mass-ratio ill-conditioning: state of the art, 2023–2026

Date: 2026-07-23. Question: can anything published recently beat
substeps/LRA for a heavy payload on a light rope, on a CPU?

## The framing that matters

Macklin et al., *Primal/Dual Descent Methods for Dynamics* (SCA 2020,
https://mmacklin.com/primaldual.pdf) established the dichotomy:

- **Dual** methods (XPBD, sequential impulse) are insensitive to *stiffness*
  ratio and **ill-conditioned in *mass* ratio**.
- **Primal** methods (VBD, projective dynamics) are insensitive to *mass*
  ratio and ill-conditioned in *stiffness* ratio.

So our stretch under heavy payloads is not a tuning failure — it is a
property of the formulation we chose, and substeps are the only lever
inside XPBD.

**Measured, and better than the literature's framing suggests.** Our own
sweep (`bench/mass_ratio_bench.gd`, table in the README) shows stretch is
linear in mass ratio but **inversely quadratic in substeps**: each doubling
of substeps costs 2x and removes 4x the stretch. The budget for a target
accuracy therefore grows as the *square root* of the mass ratio, not
linearly. At 100:1 — a rover on a cable, our actual use case — 32 substeps
gives 2.6% and 64 gives 0.65%, which is sub-millisecond in C++.

That reframes the whole question: plain XPBD is adequate for Regolith, and
the methods below matter for extreme ratios, many simultaneous ropes, or a
tighter accuracy promise to plugin users. None of them is urgent.

## The one genuinely new result: AVBD

*Augmented Vertex Block Descent*, Giles, Diaz, Yuksel — ACM TOG 44(4),
SIGGRAPH 2025. https://graphics.cs.utah.edu/research/projects/avbd/
Reference code (MIT): https://github.com/savant117/avbd-demo2d and
`avbd-demo3d`.

Hybrid primal-dual. The primal step is VBD: visit one particle at a time and
take a single Newton step on a 3x3 local system. Constraints are
augmented-Lagrangian energies; after each primal sweep a dual step updates
the multiplier and ramps a penalty stiffness. Both are **warm-started across
frames**. Being primal, mass ratio does not condition the local systems; the
augmented Lagrangian recovers the hard constraints plain VBD cannot.

Why it fits us specifically:

- **Claim at our exact scenario** (paper Fig. 7): a 50-body chain with a
  heavy object at the end at 50,000:1. AVBD holds; XPBD at 20 substeps
  stretches; XPBD at 50 iterations fails outright.
- **Tension readout survives.** The paper states the augmented Lagrangian
  converges to the same constraint forces as XPBD's multipliers; in the
  reference code `lambda` *is* the constraint force. Our public contract
  (`get_segment_tension`) is unaffected.
- **Unilateral constraints and fracture are native** — force bounds per
  row give rope-pulls-never-pushes and cable-snaps-under-overload for free.
- **Cost** ~2–4x a plain XPBD sweep per iteration, but far fewer iterations,
  and it scales with bodies rather than constraints. Chain topology needs no
  graph coloring on CPU. Reference solver is ~740 lines of readable C++.
- **Warm-started multipliers are ideal for a winch**: a rope holding a
  vehicle is quasi-static, so last frame's tension is nearly this frame's.

Caveats, stated honestly:

- The paper's own limitation section admits force propagation along long
  chains is still iteration-limited and "can take multiple frames". **This is
  the one that bites** — see the length wall below.
- The penalty ramp `beta` is **unit-scale dependent**: the paper suggests
  1–1000, the shipped code uses 100000 with a comment that the right value
  depends on your length/mass/constraint scales. Now derived rather than
  tuned; see below.
- No independent published head-to-head reproduction of the headline number
  was found; one third-party WebGPU port exists, self-described as an early
  proof of concept.
- **Patent: checked, and clear enough to proceed.** US 12,412,328 B2,
  "Primal solver for simulation and display of rigid bodies in a virtual
  environment", assignee **Roblox Corporation**, sole inventor **Christopher
  Giles** — the AVBD author — filed 2023-07-31, granted 2025-09-09. Claim 1
  covers obtaining a rigid body's state, computing Jacobians and Hessians per
  constraint, and applying a *two-stage primal solver*. But the specification
  solves directly for **velocities** with Newton plus preconditioned conjugate
  residual, never mentions vertex block descent, augmented Lagrangian, dual
  variables or penalty stiffness, and expressly distinguishes itself from
  methods using Lagrange multipliers. AVBD is built on Lagrange multipliers,
  so it sits on the far side of the line the patent draws for itself. Roblox
  also let Giles publish AVBD with Utah under CC-BY 4.0 with permissive
  reference code. Not legal advice; risk judged low, and recorded here so the
  judgement is revisitable.
  Related Roblox family, different subject (splitting bodies into splinters):
  US 11,769,297 / 12,073,511 / US20220207826A1.

## What our own port measures (2026-07-23)

`core/avbd_rope.gd` is AVBD specialized to a chain of 3-DOF particles, ported
from the structure of the authors' 3D reference. Measured against the shipping
XPBD core on identical scenarios (`spikes/spike_d`, `spike_e`, `spike_f`;
visual side-by-side in `demos/avbd_shootout.tscn`).

**Where it wins, at the operating point** (5 m rope, 25 segments, 250 kg):

| | us/step | stretch | jitter | tension err |
|---|---|---|---|---|
| XPBD sub=32 | 912 | 3.28% | 5.39 mm | +2.3% |
| AVBD iter=8 | 755 | 0.92% | 0.41 mm | +9.6% |
| AVBD iter=16 | 1180 | 0.92% | 0.39 mm | +3.3% |

The column that matters most is **jitter** — mean particle motion per tick on a
rope that has visually stopped. It is the quantity spike B identified as the
disease ("a coupled body never sleeps, 0 sleeping ticks of 840"), and no paper
in this area reports it: they report constraint error, which a rope trading
energy back and forth can keep small while never settling. AVBD is quiet by
construction, because the holding force lives in a multiplier that survives the
frame instead of being re-derived from positional error every frame.

**Deriving beta instead of tuning it.** Solving the method's own steady state
for the penalty gives

    C_inf = lam (1 - alpha gamma) / (n_dual k (1 - alpha))
    k_inf = sqrt( lam beta (1 - alpha gamma) / (1 - gamma) )

and eliminating k, for a target stretch `e` on segments of length `L`:

    beta = lam (1 - alpha gamma)(1 - gamma) / ( n_dual^2 (1-alpha)^2 e^2 L^2 )

For a 1250 kg payload on 0.2 m segments at 1% this returns 1.14e7; sweeping for
the best value by hand had found 1e7. So the plugin exposes `max_stretch` and
derives beta per segment from the segment's own multiplier — one constant
cannot serve a 2.5 kg rope and a 1250 kg payload, and getting it wrong does not
show up in the stretch column, only in the tension.

**The length wall — the finding that bounds everything.** Free hanging, 4
segments per metre, XPBD at 32 substeps vs AVBD at 16 iterations, tension error
against the analytic static answer:

| length | segments | XPBD | AVBD |
|---|---|---|---|
| 5 m | 20 | -2.5% | -2.0% |
| 20 m | 80 | -0.6% | +1.0% |
| 50 m | 200 | -1.5% | **+14.2%** |
| 100 m | 400 | -4.3% | **+947%** |

With a 250 kg payload it degrades faster: +0.3%, +60%, +350%, +1549406%.

**Stretch stays excellent throughout** (0.39% at 50 m against XPBD's 2.69%), so
nothing but the tension column reveals the failure — the same blind spot as the
beta mistake.

## What the length wall actually is (2026-07-23)

`spikes/spike_g_length_guard.gd`. Same protocol as above throughout: 4 segments
per metre unless stated, 12 s settle, mean over the last 3 s, tension of the
top segment against `(payload + mass_per_m * length) * g`.

**The obvious hypothesis is wrong.** The paper's limitation section blames
Gauss-Seidel propagation, which says the bound should be on *segment count* —
`iterations >= segments / K`. Hold the segment count at 200 and vary the
length, at 16 iterations, and that story falls apart:

| segments | length | segment length | free hanging | 250 kg |
|---|---|---|---|---|
| 200 | 200 m | 1.0 m | +9.7% | +18.3% |
| 200 | 100 m | 0.5 m | +3.0% | +62.1% |
| 200 | 50 m | 0.25 m | +14.2% | +349% |
| 200 | 25 m | 0.125 m | **+10154%** | **+98743%** |

Identical chains in particles; four different worlds. Holding the *length* at
50 m and refining instead gives the same answer from the other side: 50
segments reads -0.5%, 100 reads +1.0%, 200 reads +14.2%, 400 reads
**+12131336%**. Refinement — the thing a user reaches for to make a rope look
better — is what breaks the tension readout.

**The variable is fineness**, `M = segments / segment_length = segments^2 /
length`, in 1/m. Every measurement above and below orders correctly by it. The
mechanism is not propagation, it is the derived penalty ramp: `beta` goes as
`1 / (n_dual^2 * e^2 * L^2)`, so halving the segment length asks four times as
much of the dual ascent per step. `max_stretch` is a *fraction*, so a shorter
segment means a tighter absolute tolerance, and past some point the penalty
term takes over the load from the multiplier — which is exactly the failure the
beta derivation was written to prevent at a different scale.

**Two regimes, two exponents.** Minimum iterations for a tension error inside
10%, from a ladder of 8, 12, 16, 24, 32, 48, 64, 96, 128:

| M (1/m) | rope measured | free | 250 kg |
|---|---|---|---|
| 80 | 5 m, 20 segs | 8 | 8 |
| 100 | 100 m, 100 segs | 8 | 16 |
| 320 | 20 m, 80 segs | 12 | 32 |
| 320 | 5 m, 40 segs | 12 | 24 |
| 640 | 10 m, 80 segs | 16 | 48 |
| 800 | 50 m, 200 segs | 24 | 48 |
| 1280 | 5 m, 80 segs | 24 | 64 |
| 1600 | 100 m, 400 segs | 32 | 96 |

Free hanging follows `M^0.5`; under a payload the exponent rises to `M^0.6`,
because a load does not thin out along the rope the way the
rope's own weight does — every segment carries it, so every segment needs the
budget the top one needs. A second, weaker floor of `0.09 * segments` binds on
the free side only, where fineness is low but the chain is long (400 coarse
segments want 34 by fineness and 36 by this).

**The rule as shipped** (`AVBDRope.required_iterations`, clamped inside the
core so it cannot be bypassed by using the core directly, and applied by
`Rope3D` where the segment count is decided):

    free    iterations >= max(0.85 * M^0.5, 0.09 * segments)
    loaded  iterations >= max(1.15 * M^0.6, 0.09 * segments)
    floored at 8, rounded up to even, automatic raise capped at 96

Both leading constants are the *worst* ratio in the table, not a least-squares
fit: the ladder is coarse, and a rule through the mean sits below half of what
it is supposed to cover.

Rounded to even because `dual_every` is 2 and an odd trailing sweep is paid for
without ever getting its dual update. Capped because the step is
O(particles x iterations) and past the cap the honest move is to say so:
`Rope3D._get_configuration_warnings()` in the editor and `push_warning` at
runtime, wording shared with the core so they cannot drift.

**What it costs**, this GDScript reference core, 4 segments per metre:

| | segs | free | us/step | loaded | us/step |
|---|---|---|---|---|---|
| 5 m | 20 | 8 | 620 | 16 | 1100 |
| 20 m | 80 | 16 | 4400 | 38 | 10800 |
| 50 m | 200 | 26 | 16500 | 64 | 43000 |
| 100 m | 400 | 36 | 42000 | 98 | *past the ceiling* |

So at the default resolution every free rope to 100 m is served and every
loaded one to 50 m. A loaded 100 m rope still runs — at the ceiling of 96,
where it measures +8.7% — but it is warned about, because "nearly" is not what
`get_segment_tension()` promises. Resolution runs out sooner than length: 5 m
at the node's maximum 16 segments per metre wants 32 free and 86 loaded, 20 m
at 16 per metre wants 62 and 194.

**Acceptance, with the guard actually driving** (`spike_f`, which is now the
acceptance harness: AVBD is handed the floor of 8 and left to raise itself).
Tension error against the analytic static answer, XPBD at 32 substeps beside
it for scale:

| | segs | XPBD | AVBD | iter |
|---|---|---|---|---|
| 5 m free | 20 | -2.5% | **-1.2%** | 8 |
| 20 m free | 80 | -0.6% | **+1.0%** | 16 |
| 50 m free | 200 | -1.5% | **+1.8%** | 26 |
| 100 m free | 400 | -4.3% | **+3.2%** | 36 |
| 5 m + 250 kg | 20 | +3.9% | **+0.3%** | 16 |
| 20 m + 250 kg | 80 | -10.1% | **+3.1%** | 38 |
| 50 m + 250 kg | 200 | +20.5% | **+3.3%** | 64 |
| 100 m + 250 kg | 400 | +0.9% | **+8.7%** | 96 † |

† the only row that warns: the rule wants 98 and the ceiling is 96. It is
inside the 10% band anyway, which is the point of warning rather than refusing.
Jitter on the same runs is 1.4 mm against XPBD's 16.9 mm at 50 m loaded, so the
budget the guard spends does not undo what AVBD was adopted for. Note also that
the worst XPBD row here is its 20 m and 50 m loaded ones — the guard costs AVBD
its iteration advantage on long ropes but not its accuracy advantage.

**Caveats, because this is a fit and not a derivation.** One payload (250 kg),
one linear density (0.5 kg/m), one damping (0.5 1/s), one timestep (60 Hz);
`loaded` is a binary switch on whether anything hung on the rope exceeds 10% of
its own mass, and a heavier payload than 250 kg is not claimed to be covered.
The ladder is coarse, so every crossing is known only to within one rung. Long
ropes are also not perfectly settled at 12 s — the spike reports max particle
speed alongside every number for exactly this reason, and the 200 m row above
is the one to distrust.

**Catenary, as the independent arbiter** (12 m over 10 m, 60 segments, settled):
analytic sag 2.9234 m, H 23.01 N, T_support 37.33 N, against the nominal 12 m.
XPBD: sag +0.1%, H -0.1%, T_support -1.1%. AVBD: sag **+2.3%**, H -2.6%,
T_support -1.4%. An earlier reading of 121 N where XPBD read 16 N on a
two-pin span turned out to be an unsettled transient, not a formulation
error — it does not reproduce once the rope is allowed to stop.

**The 2.3% sag reading is explained, not a formulation error (2026-07-23).**
AVBD is a soft constraint by construction — `max_stretch` is the stretch the
penalty ramp is *derived* to settle at, not a tolerance around an otherwise
rigid answer. So the rope really is longer than 12 m at rest: measured
settled length 12.081 m, i.e. **+0.68% stretch**, against XPBD's own +0.04%
(12.009 m) at compliance 0. A shallow catenary's sag is strongly
length-sensitive — solving `a sinh(d/a) = L/2` at a few lengths near 12 m
(half-span 5 m) shows the sag itself shifting far faster than the length
does:

| length | vs. nominal | sag | sag shift |
|---|---|---|---|
| 12.000 m | — | 2.9234 m | — |
| 12.072 m | +0.60% | 2.9821 m | +2.01% |
| 12.081 m | +0.68% (AVBD's measured settle) | 2.9895 m | +2.26% |
| 12.120 m | +1.00% | 3.0209 m | +3.33% |

(An initial hand estimate guessed the 1%-length sensitivity at +4.0%; the
solved value is +3.33% — same order and direction, confirmed rather than
assumed, off by about a fifth.) Solving the *same* analytic formulas for the
length each core actually produced, instead of the nominal 12 m, removes the
length-driven component and leaves only shape error:

| | settled length | stretch | sag vs. nominal-L ref | sag vs. own-L ref | H vs. own-L ref | T_support vs. own-L ref |
|---|---|---|---|---|---|---|
| XPBD | 12.009 m | +0.04% | +0.1% | **+0.01%** | -0.02% | -1.07% |
| AVBD | 12.081 m | +0.68% | +2.3% | **+0.05%** | -0.77% | -1.15% |

Both cores' shape is correct to a few hundredths of a percent once compared
against the length they actually built — the 2.3% was entirely the length
difference, not the equilibrium geometry. `tests/test_catenary.gd` now
checks both cores this way: sag and tension against the catenary solved from
each core's own settled length, with the settled length itself separately
bounded against what that core is designed to hold (near-rigid for XPBD,
1.5x `max_stretch` for AVBD) so a real stretch regression still fails it.
Measurement: `spikes/spike_f_catenary_and_length.gd`.

This is what promotes the runner-up below from "nice to have" to "the answer
for long ropes".

## Runner-up: direct solve for the chain

Deul, Kugelstadt, Weiler, Bender, *Direct Position-Based Solver for Stiff
Rods*, CGF 37(6), 2018.
https://vci.rwth-aachen.de/ca/media/papers/2018-CGF-Rods.pdf

Solves all constraints of an acyclic structure simultaneously inside XPBD
instead of sweeping them — O(N) for a chain (Thomas algorithm). Propagation
error disappears entirely, so mass ratio stops mattering. Weekend-scale for
chain-only, no tuning parameters, tension trivially available.

Its limit is exactly our gate 3: the moment the rope contacts terrain or
wraps a pulley the topology is no longer acyclic and the solve must be
split. Also needs the end rigid bodies folded into the system.

### Measured, as a primal step inside AVBD (2026-07-23)

Porting Deul as a third core was rejected — it has AVBD's collision blocker and
a worse version of it, and ADR 0007 already priced two solvers. What was taken
instead is the one structural observation underneath the paper: **AVBD's own
primal Hessian is already block tridiagonal**, because particle `i` couples to
`i-1` and `i+1` through its two segments and to nothing else. So the sweep can
be replaced by a block Thomas solve — O(N), exact, no iteration count anywhere
— changing nothing else about the method. `spikes/avbd_direct_rope.gd`
overrides `_primal_sweep` and only that; `spikes/spike_h_direct_primal.gd`
measures it. Iterations at which the tension error first falls inside 10%:

| rope | M | sweep | | direct | |
|---|---|---|---|---|---|
| 5 m, 4/m, free | 80 | 8 | −1.2% | 8 | −2.5% |
| 5 m, 4/m, 250 kg | 80 | 8 | +0.6% | 8 | −0.0% |
| 20 m, 4/m, 250 kg | 320 | 32 | +7.0% | **8** | +0.0% |
| 5 m, 16/m, free | 1280 | 24 | +1.5% | **8** | −0.6% |
| 5 m, 16/m, 250 kg | 1280 | 64 | +8.0% | **8** | −0.0% |
| 50 m, 4/m, 250 kg | 800 | 48 | +7.3% | **12** | −1.0% |

**The fineness tax is the sweep, not the beta derivation.** That was the open
question and it is answered: across a 16x range in M the exact solve sits on
the floor of 8, and where the sweep only just scrapes inside the band at its
crossing (+7 to +8%) the direct solve is at −0.0 to −1.0%. The residual is the
50 m rope wanting 12 rather than 8, i.e. the weak segment-count term survives
and the fineness term does not.

Both risk cases the frozen active set could have broken came back clean. Two
pinned ends (a Dirichlet row at each end, which the hang cases never exercise):
catenary sag +2.3% and support tension −2.0% at 8 iterations, against the
sweep's +2.3% / −1.3% — indistinguishable. Every segment slack in zero gravity,
the case where the sweep re-decides the active set per particle and this does
not: peak tension 0.000000000 N, peak drift 0.000000000 m, exactly as the
sweep. No block ever came back singular.

**Jitter, which is the column that nearly got missed.** The table above is
tension only, and tension is not why AVBD was adopted — quiet is. Measured at
each core's own crossing: 20 m under 250 kg, sweep 2.55 mm against direct's
**0.06 mm**; 5 m at 16 per metre under load, 0.97 mm against **0.00 mm**. So
far so good. But the 50 m rope goes the other way — 1.53 mm for the sweep at 48
iterations against 7.41 mm for the direct solve at 12 — so the two were run on
the same rope at the same budget:

| iterations | sweep tension / jitter | direct tension / jitter |
|---|---|---|
| 12 | +10730% / 4.94 mm | −1.0% / 7.41 mm |
| 24 | +86.1% / 3.32 mm | −3.3% / 3.42 mm |
| 48 | +7.3% / **1.53 mm** | +0.9% / **3.59 mm** |

**The direct solve's jitter plateaus near 3.4 mm and stops improving, while the
sweep's keeps falling.** It wins tension by four orders of magnitude at 12
iterations and loses "the rope has stopped moving" at 48. That is a real
limitation, not a measurement artifact, and it is the reason this result is
recorded as promising rather than as a decision.

The obvious suspect — one exact Newton step overshooting where N small block
solves damp each other — was tested by scaling the step (`relax` in
`avbd_direct_rope.gd`) and **rejected**: at 24 iterations 1.0 settles at −3.3%
while 0.8, 0.6 and 0.4 all diverge outright. The likely reason is worth stating
because it generalises: the dual step and the derived beta both assume the
primal step reaches its minimum. Under-solve the primal and the constraint error
stays large every iteration, so the penalty ramps against an error that was
never going to be corrected and the multiplier ratchets — the length guard's
failure mode reached from the other direction. Any future attempt at the jitter
floor has to use something the dual can still trust, such as a line search on
the actual energy, not a fixed step scale.

Cost, honestly: in GDScript the direct step is ~3x the sweep per iteration
(two 3x3 products and an inverse per particle, with the blocks hand-rolled in a
`PackedFloat64Array` because `Basis` has no addition), so the net ranges from
3x *worse* on a short rope the sweep already solved at 8 to 2.4x better on a
fine loaded one. In C++ the per-iteration ratio should be ~1.3–1.5x on flop
count, which turns every row into a win. That is a projection, not a measurement.

Untested and load-bearing for any decision to ship it: contacts. The argument
that they preserve the structure — a particle-versus-world contact is a rank-1
update on that particle's own diagonal block, so the matrix stays tridiagonal,
while non-adjacent self-contact would break it and would have to go to a sweep
on top — is reasoning, not measurement. Also untested: moving anchors, rigid
body coupling, jitter and stretch (only tension was measured), payloads other
than 250 kg.

## Cheapest probe: warm-started multipliers

Persisting lambda across frames on our existing solver is about a day of
work. Textbook XPBD resets lambda every substep by construction, so
persisting it drifts toward an augmented-Lagrangian form — which is
literally half of AVBD. Good de-risking step *toward* AVBD rather than an
independent option.

## Rejected, with reasons

MGPBD (SIGGRAPH 2025), JGS2 (SIGGRAPH 2025), Chebyshev/SOR acceleration,
multigrid PBD, learned preconditioners: all GPU, all large-DOF cloth/FEM,
all aimed at *stiffness*-ratio and mesh-resolution conditioning — the
opposite axis from our problem. Plain VBD lacks hard constraints and still
stretches. Classical LRA caps *visual* stretch but does not deliver correct
tension to the heavy body, so it is a cosmetic backstop, never the fix.

## What shipping engines do (none solve it)

Jolt soft bodies are XPBD — same dual formulation, same problem. Obi's own
docs say to keep particle/rigidbody mass ratios small and prescribe more
substeps. Havok reshapes inertia tensors across chains to even out effective
mass ratios — fudging the physics, not fixing the solver. Unreal's cable is
visual-only Verlet with kinematic ends. Rapier's rope joint is a distance
limit. PhysX handles articulated rigid chains via reduced coordinates, but
that is not a particle rope.

Conclusion: no production engine solves the heavy-payload rope case. If we
do, that is the plugin's headline feature.
