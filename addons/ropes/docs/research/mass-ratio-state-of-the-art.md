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
  chains is still iteration-limited and "can take multiple frames".
- The penalty ramp `beta` is **unit-scale dependent**: the paper suggests
  1–1000, the shipped code uses 100000 with a comment that the right value
  depends on your length/mass/constraint scales. Budget tuning time.
- The shipped demo scenes are far milder than the headline figure
  (~200–1800:1, not 50,000:1). **Verify at our ratio before porting.**
- No independent published head-to-head reproduction of the headline number
  was found; one third-party WebGPU port exists, self-described as an early
  proof of concept.
- **Possible patent** — a USPTO record titled "Primal solver for simulation
  and display of rigid bodies in a virtual environment" (US 12,412,328) was
  surfaced but assignee/claims could NOT be verified. The code being MIT
  does not by itself grant patent rights. For a public plugin this must be
  checked before committing.

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
