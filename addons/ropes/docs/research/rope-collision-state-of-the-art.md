# Rope/rod/cable collision: state of the art, 2020-2026

Date: 2026-07-23. Question: what has actually changed in rod/rope contact
since our architecture (ADR 0006) was written, and does anything published
beat what we already do, on a CPU, at 60 Hz?

## What we already do, so this note does not recommend it back

Contacts are unilateral rows in the same iteration loop as the distance
constraints. Colliders are cached once per tick from one broadphase query;
every substep the core evaluates exact analytic signed distance to those
cached shapes, with transforms interpolated across substeps. Detection
samples particles plus segment midpoints, barycentric-distributed to the
endpoints. Coulomb friction at the velocity stage with a measured
stick/slide split; restitution 0. Adjacent particles held `2*radius` apart
(self-thickness); general pairwise self-contact deferred. Analytic shapes
only: plane, sphere, box. Known gaps, in the project's own words: no true
capsule/segment narrow phase yet (point+midpoint sampling causes a measured
"tube sink" and a two-corner ratchet artifact), no concave/voxel terrain, no
general self-contact.

The short version of this whole survey: **the field's answer to our two
biggest documented gaps — segment-vs-shape narrow phase, and terrain as an
SDF instead of convex decomposition — is one paper, and it says both are
close to free.** Section 4/5 below is the load-bearing part of this note.

---

## 1. What's genuinely new since 2020

**Graphics.** The center of gravity moved to (a) intersection-*guaranteed*
barrier methods for offline/quasi-real-time quality work (IPC and its
codimensional/GPU descendants, §2), and (b) GPU local-global solvers that
recover something close to interactive rates for fiber/hair assemblies with
real Coulomb friction (Daviet, SIGGRAPH 2023, §3). Contact *detection*
itself also advanced: exact closest-point optimization against implicit
surfaces (SDFs) generalizes cleanly to 1-D rod segments and is *not* more
expensive than naive point sampling (Macklin et al., 2020, §4/§5) — this
is the single most relevant published result for this project.

**Robotics/engineering.** The line is differentiable, learning-friendly
discrete elastic rod (DER) simulators aimed at real robot manipulation of
cables and wires: DEFORM (Chen et al., CoRL 2024) and its branched
extension DEFT (2025), both explicitly targeting real-time rates for
system identification and control, not visual fidelity. A parallel,
more classically-flavored robotics line reformulates rod-rigid contact as
a convex program inside Drake (Li & Chou, 2025) and — notably — validates
itself against the capstan equation (§8). Neither line touches terrain-SDF
contact or general self-contact/knots; both assume a small number of
well-separated contacts (grasping, table contact), which is a materially
easier problem than ours.

---

## 2. IPC and codimensional descendants: guarantees, cost, real-time variants

**Incremental Potential Contact.** Minchen Li, Zachary Ferguson, Teseo
Schneider, Timothy R. Langlois, Denis Zorin, Daniele Panozzo, Chenfanfu
Jiang, Danny M. Kaufman, *Incremental Potential Contact: Intersection- and
Inversion-free, Large-Deformation Dynamics*, ACM TOG 39(4):49, SIGGRAPH
2020. https://ipc-sim.github.io/file/IPC-paper-350ppi.pdf — verified.
Guarantee: trajectories are provably intersection-free and inversion-free
for *any* timestep, material, or velocity, by combining a log-barrier
potential (infinite cost at zero distance) with conservative-advancement
continuous collision detection inside an implicit Newton solve. This is a
correctness guarantee our analytic-SDF approach does not have in the
concave/self-contact case — but see cost, below.

**Codimensional IPC (C-IPC).** Minchen Li, Danny M. Kaufman, Chenfanfu
Jiang, *Codimensional Incremental Potential Contact*, ACM TOG 40(4),
SIGGRAPH 2021. https://ipc-sim.github.io/C-IPC/file/paper_small.pdf —
verified (fetched and read in full). This is the direct answer to "rods
with thickness": it extends IPC's barrier to enforce a *distance offset*
between codimension-1 (shell/mesh) and codimension-0 (rod centerline)
elements, so a polyline rod behaves as if it had a real cylindrical
radius without volumetric meshing — precisely our own `radius` parameter,
done with a correctness proof instead of a documented tube-sink artifact.
The paper's own "Noodles" scene is 625 forty-segment discrete rods (our
exact object) dropped into a bowl and piling up with self-contact.

**Cost, measured and quoted directly from the paper's own statistics
table (Fig. 24), not estimated:** timings are reported in **minutes per
timestep**, not milliseconds. Noodles (126.8K DOF, 8 Newton iterations/step
average): **9.8 min avg, 41.9 min max**, per single timestep, on the
paper's own hardware. Braids: 3.5 min avg / 16.9 min max. Twisting
cylinder: 10.2 / 33.4 min. This is four to six orders of magnitude away
from a 60 Hz budget (16.7 ms). IPC/C-IPC is the correctness ceiling for
this class of problem, not a candidate technique for us.

**GPU descendants close the gap by 1-2 orders of magnitude, still nowhere
near 60 Hz for contact-rich scenes.** GIPC (Kemeng Huang, Floyd M. Chitalu,
Huancheng Lin, Taku Komura, *GIPC: Fast and Stable Gauss-Newton
Optimization of IPC Barrier Energy*, ACM TOG 43(2), April 2024,
https://dl.acm.org/doi/10.1145/3643028 — verified via search, abstract
confirmed) replaces the barrier Hessian's eigendecomposition with a
GPU-friendly Gauss-Newton approximation and a PCG solver: first fully
GPU-resident IPC. StiffGIPC (Huang, Lu, Lin, Komura, Minchen Li, arXiv
2411.06224, Nov 2024, updated May 2025; ACM TOG,
https://dl.acm.org/doi/10.1145/3735126 — verified) adds a multilevel
Additive Schwarz preconditioner and claims up to 10x over GIPC on stiff
materials. Most recently, Juntian Zheng, Zhaofeng Luo, Minchen Li (CMU /
Genesis AI), *Robust and Efficient Penetration-Free Elastodynamics without
Barriers*, ACM TOG, SIGGRAPH 2026, arXiv:2512.12151 — verified via fetch —
replaces the log-barrier with a custom augmented-Lagrangian solver and
claims **up to 103x over GIPC** on contact-rich benchmarks. None of these
three states a frame-rate or claims real-time/interactive use; all require
a CUDA GPU; none targets rods or ropes specifically (general FEM
solids/cloth benchmarks). Chasing the arithmetic: even a 100x-over-GIPC
speedup applied to the Noodles number above is still on the order of a
tenth of a second per step, and that is before accounting for the fact
GIPC itself is a different (bigger, GPU-only) codebase than our CPU
GDScript/C++ core.

**Verdict for this project: nothing in the IPC family is usable at 60 Hz
on a CPU, and porting the barrier+CCD machinery would be a multi-month
rewrite of the whole solver, not a collision-module change.** The value
here is conceptual, not code: C-IPC's distance-offset formulation is the
textbook description of what our `radius` parameter is already doing
informally, and its Noodles scene is the existence proof that rod
self-contact with thickness is at least representable — just not
affordably, by this method, at our rate.

---

## 3. Exact/nonsmooth Coulomb friction for fiber and rod assemblies

The user's memory was accurate on both papers, and both exist as stated:

- Florence Bertails-Descoubes, Florent Cadoux, Gilles Daviet, Vincent
  Acary, *A Nonsmooth Newton Solver for Capturing Exact Coulomb Friction in
  Fiber Assemblies*, ACM TOG 30(1), 2011.
  https://inria.hal.science/inria-00557706 — verified. Poses contact +
  exact Coulomb friction as a single nonsmooth root-finding problem (not
  the graphics-standard LCP approximation), solved by a nonsmooth Newton
  iteration. Captures stick-slip, entangling curls, tight knots.
- Danny M. Kaufman, Rasmus Tamstorf, Breannan Smith, Jean-Marie Aubry,
  Eitan Grinspun, *Adaptive Nonlinearity for Collisions in Complex Rod
  Assemblies*, ACM TOG 33(4):123, 2014.
  https://dl.acm.org/doi/10.1145/2601097.2601100 — verified (abstract).
  **Correction to the memory, worth stating explicitly:** this paper is
  about the nonlinearity of the *collision-response* time-integration step
  under transversal impact (rod stiffness makes stretching modes react
  extremely nonlinearly to lateral impact), not specifically exact
  Coulomb friction. It is the right paper, just solving an adjacent
  problem in the same rod-assembly space (up to 1.7M contacts/step,
  Disney production scale) — cite it as "adaptive nonlinear collision
  response," not as the friction paper.

**Has the exact-friction line advanced since 2020? Yes, on both ends —
geometry and solver:**

- Octave Crespel, Emile Hohnadel, Thibaut Métivet, Florence
  Bertails-Descoubes, *Contact Detection Between Curved Fibres: High Order
  Makes a Difference*, ACM TOG 43(4), SIGGRAPH 2024.
  https://hal.science/hal-04364565v2 — verified. Same lab, 13 years later.
  Shows low-order (linear-segment) fiber-fiber contact detection produces
  *force artifacts*, not just geometric error, when fiber curvature at
  contact is significant — directly the mechanism behind our own
  documented "chords are entitled to hug the edge" finding, from the other
  direction (this paper is fiber-fiber; ours is fiber-vs-static-edge, but
  the discretization argument is the same shape). Proposes an adaptive,
  high-order curve-curve closest-point scheme.
- Gilles Daviet, *Interactive Hair Simulation on the GPU using ADMM*, ACM
  SIGGRAPH 2023 Conference Proceedings.
  https://dl.acm.org/doi/10.1145/3588432.3591551 — verified via search +
  abstract. Same author as the 2011 solver, this time a GPU local-global
  ADMM solver for DER with (near-)exact Coulomb friction, explicitly
  validated against **analytic** cantilever, bend-twist, and stick-slip
  benchmarks (the same "validate against a closed-form answer" discipline
  our own catenary/mass-ratio tests use). Reported cost: **0.18-8 seconds
  per frame** for several-thousand-strand hair assemblies on GPU — the
  paper's own word "real-time" is used loosely, in the sense of
  interactive editing turnaround, not 60 Hz. For a single rope with a
  handful of contacts the per-element cost would be a tiny fraction of
  that, but the published numbers are for hair-scale problems and cannot
  be extrapolated to a per-rope budget without re-measuring.

**Robotics-side convex reformulation, very recent:** Wei-Chen Li, Glen
Chou, *A Convex Formulation of Compliant Contact between Filaments and
Rigid Bodies*, arXiv:2509.13434, Sept 2025 — verified via fetch (PDF
downloaded and read). Built on Drake (open-source, BSD-licensed robotics
toolkit); reformulates filament-rigid contact + friction as a convex
program, and uses the capstan test as its own validation (§8). No timing
numbers were visible in the fetched excerpt; Drake's convex solves are
not generally run at 60 Hz on a CPU for anything but small scenes, so
treat this as a modeling reference, not a performance target.

**Net assessment:** this line has real 2020+ advances, but every one of
them is either GPU-bound (Daviet 2023, seconds/frame at hair scale) or a
convex-program robotics tool (Li & Chou 2025, no throughput claim). None
is a drop-in for a CPU GDScript/C++ core at 60 Hz. The useful takeaway is
methodological: high-order curve-curve detection (Crespel et al. 2024) is
the right long-term answer to our own edge-artifact findings, whenever we
get to general self-contact (§6) — it is a detection-accuracy fix, cheap
in principle, not a solver rewrite.

---

## 4. Capsule/segment vs point-based contact: what production actually does

This is where the survey pays for itself. Miles Macklin, Kenny Erleben,
Matthias Müller, Nuttapong Chentanez, Stefan Jeschke, Zach Corse, *Local
Optimization for Robust Signed Distance Field Collision*, Proc. ACM
Comput. Graph. Interact. Tech. 3(1), May 2020.
https://mmacklin.com/sdfcontact.pdf — verified (downloaded, converted to
text, read in full; author is NVIDIA/Copenhagen, first author is the same
Miles Macklin behind PBD/XPBD and NVIDIA Flex).

**The problem statement is our problem, verbatim.** The paper opens by
observing that point-sampling a 1-D or 2-D element against an SDF "may be
insufficient to detect overlap for particularly sharp features," and that
"point-sampling fails to capture the case of edge-edge contacts" — this is
our documented tube-sink and two-corner-ratchet artifacts, independently
discovered and named by someone else.

**The fix:** instead of sampling fixed points, solve a small per-element
*continuous optimization* for the closest point between the element
(triangle face, or — the case that matters to us — a line segment) and
the SDF isosurface. Three solvers compared: projected gradient descent,
Frank-Wolfe, and golden-section search. **For a 1-D segment specifically,
golden-section search is a scalar bisection-style search with no
gradients needed** — the natural, cheap choice for exactly our "segment
midpoint vs. shape" problem.

**Measured cost — this is the number that matters for us.** Table 1, a
scene of **128 ropes made of 1-D segments** (Fig. 4 in the paper) against
an SDF, gridded at 256³: naive point sampling costs **98 µs** per
timestep; golden-section search over full *segments* costs **99 µs**.
One microsecond of difference. Exact segment-vs-SDF narrow phase, done
right, is not a performance tradeoff against point sampling — it is
free. (Their rigid-shell/cloth-dragon numbers show the same pattern:
0.08-0.445 ms even for 20K-635K element meshes, and one case where
SDF-based contact beat triangle-mesh BVH contact by **30x**: 15 ms
mesh-based vs <0.5 ms SDF-based on a 129K-triangle shell.)

**Read a second time, against the PDF, 2026-07-23 — the numbers are exact
and the platform is not ours.** Table 1's rope row verbatim: SDF 256³,
4224 points, 4096 elements, Simple 98 µs, PGD 102 µs, FW 99 µs, GS 99 µs.
Fig. 4's caption states the failure being fixed as "point-based sampling
misses edge-edge contacts leading to interpenetration across the sharp SDF
edge" — our tube sink, named independently. The BVH figure is verbatim too,
along with the authors' own caveat on it, which matters: "this is not a
perfect comparison, since SDFs implicitly resample the surface geometry
(possibly losing detail)", and their method "generates exactly one contact
per-triangle rather than one per-feature pair".

But §8 opens: "we have implemented it in CUDA and run it on an NVIDIA GTX
2080 Ti." **Every timing in Table 1 is GPU.** The paper's own explanation of
why the optimization is nearly free is "once SDF data enters the GPU cache
it is fast to sample", plus the culling in Fig. 13. The memory-hierarchy
half of that argument plausibly transfers to a CPU; the massive parallelism
over elements, which is what hides the latency in the first place, does not.
So "free" is verified as published and **unverified for us** — exactly the
kind of headline number the mass-ratio note insists on re-measuring rather
than inheriting.

One row transfers better than the rope row does, and it is the one that
matches slice 1. The **Analytic** example — parameterized shapes, no SDF
grid — costs 48 µs for *all three* methods identically, because, in the
authors' words, "the optimization is purely compute-based (no memory
fetches) and so total cost is small compared to the rest of the kernel and
falls below our ability to measure it". Our slice 1 is box, sphere and
plane: analytic, no fetches. For that case the "free" claim rests on
arithmetic being cheap rather than on a GPU cache being warm, which is an
argument that does survive the move to a CPU.

**Corroboration from a shipping product, independently.** Obi (Unity
asset, virtualmethodstudio.com), fetched from its own manual
(`manual/6.1/surfacecollisions.html` and `manual/7.1/whatsnew.html` —
vendor documentation, not independently verified beyond what the docs
themselves claim): ropes/rods are represented as 1-D "simplices" (edges),
and narrow phase runs "an iterative convex optimization algorithm (the
Frank-Wolfe algorithm) to determine the actual contact point" against
"either analytic or precalculated and stored into a distance field"
distance functions. This is functionally the same technique as Macklin et
al. 2020 (unsurprising: Macklin wrote both NVIDIA Flex, which Obi's
particle model descends from conceptually, and this paper), already
shipping commercially, already applied to ropes specifically. Obi's own
documented caveat: simplices sharing a particle skip mutual collision "to
avoid constraint fighting" — the same reasoning behind our own "midpoint
samples only act when at least one endpoint is contact-free" rule.

**Guidance for us:** the true segment/capsule narrow phase our own ADR
already flags as "a C++ port refinement" is not just correct-but-slow — a
1-D closest-point search (golden-section, or even a closed-form
segment-vs-plane/sphere/box solve, which we already have analytically) is
measurably free next to point sampling once you're evaluating the same
shape's distance function anyway. This converts the "tube sink" and
"two-corner ratchet" findings from accepted-known-gaps to a scheduled fix
with a published cost bound.

---

## 5. Rope vs SDF/voxel terrain

Directly answered by the same paper (§4): Macklin et al. 2020 tests SDF
collision against exactly "one dimensional objects such as hair, or rope"
(their words, their Fig. 4 caption), including sharp SDF features a
point-sampled rope visibly interpenetrates and a segment-optimized one
does not. Their broader thesis — SDF-based contact against arbitrary
(including non-convex) shapes, without needing a convex decomposition,
sometimes *cheaper* than triangle-mesh BVH contact (the 30x number above)
— is precisely the argument for treating the host's existing analytic
lunar SDF as a first-class collider type rather than doing convex
decomposition or per-substep engine queries (ADR 0006 point 9's stated
open problem). The paper's method needs: (1) the SDF value at a point,
(2) its gradient (analytic, finite-difference, or grid-interpolated) —
both of which the host's SDF module almost certainly already exposes for
its own rendering/collision needs (per project memory: the moon's is a
native analytic SDF).

I found **no other published work** targeting rod/rope collision against
an SDF or voxel terrain specifically — this is a narrow, recent (2020),
single-paper result, not an established sub-field. The robotics DLO
literature (DEFORM/DEFT, Li & Chou) works against tables, grippers, and
small rigid fixtures, never terrain-scale implicit fields. State this
gap honestly: the recommendation below rests on one paper, well-verified
and directly on-point, not on a converged literature.

Practical note on cost model for us specifically: our per-substep,
per-collider analytic evaluation already pays the "evaluate a distance
function per sample" cost for box/sphere/plane; extending the *same* code
path to "evaluate the host's SDF instead of a closed-form primitive" is
an interface change (a `distance(p) -> (d, n)` callback into host code),
not a new collision architecture — and per §4, doing it at the segment
level rather than point level costs the same again.

---

## 6. Self-collision and knots at interactive rates

**The correctness ceiling is C-IPC's Noodles scene (§2): general rod
self-contact with thickness offset is representable, but costs minutes
per timestep.** No published method claims to bring general rod-rod
self-contact + friction to 60 Hz on any hardware, GPU included. This
mirrors the mass-ratio note's conclusion about heavy payloads: nobody has
solved this at game rate, published or shipped.

**Interactive-rate self-contact for knots exists at a narrower scope.**
Andrew Choi, Dezhong Tong, M. Khalid Jawed, Jungseock Joo, *Implicit
Contact Model for Discrete Elastic Rods in Knot Tying*, J. Appl. Mech.
88(5):051010, March 2021.
https://asmedigitalcollection.asme.org/appliedmechanics/article/88/5/051010
— verified via search + abstract, reference implementation confirmed at
github.com/QuantuMope/imc-der (GPL-3.0 — copyleft, note if ever
considering reuse of code rather than technique). Penalty-based (not
IPC's barrier), fully implicit contact energy between DER segments,
purpose-built for knot-tying scenes; a 2022/2024 follow-up, Dezhong Tong,
Andrew Choi, Jungseock Joo, M. Khalid Jawed, *A Fully Implicit Method for
Robust Frictional Contact Handling in Elastic Rods*, arXiv:2205.10309
(v3, Feb 2024) — verified via fetch — reports **1.22x-1.82x faster than
IPC** at "comparable" quality while explicitly giving up IPC's
non-penetration guarantee (a soft penalty can still be pushed through
given enough force/timestep, mitigated but not eliminated by adaptive
stiffness). This is closer to game-affordable than IPC, but "faster than
IPC" starting from IPC's minutes-per-step baseline is still not a 60 Hz
number — no per-frame timing in real units was found in the fetched
excerpt.

**Spatial acceleration is a solved problem one domain over (cloth), not
in rope/rod research specifically.** GPU cloth self-collision culling has
its own active line: Min Tang et al., *PSCC: Parallel Self-Collision
Culling with Spatial Hashing on GPUs*, Proc. ACM Comput. Graph. Interact.
Tech. 1(1), 2018 (spatial hashing + normal-cone culling, 6-8x over prior
GPU work); I-Cloth (2018, spatial hashing + nonlinear impact-zone solver,
2-8 fps on a commodity GPU for hundreds of thousands of vertices — i.e.
still not 60 Hz even on GPU, for cloth); most recently a 2026 MDPI
*Mathematics* paper, *Efficient Self-Collision Culling for Real-Time
Cloth Simulation Using Discrete Curvature Analysis*
(https://doi.org/10.3390/math14091504 — verified via search/abstract),
which culls flat/low-curvature mesh regions before spatial hashing, on
the observation that most of a cloth surface is locally flat and
collision-inactive at any instant. **This transfers cleanly to ropes, and
is my own inference, not a published rope result:** a straight or
gently-curved rope segment cannot self-intersect anything nearby;
only tightly bent/coiled sections (which is to say: an incipient knot)
need a self-contact check at all. A cheap per-segment curvature or
bounding-sphere test — the same idea, and the same code shape, as the
per-collider bounding-sphere cull already measured to remove most of our
own per-substep cost (ADR 0006, "Cost is dominated by sample count")
— would be the natural entry point for general self-contact when we get
there, rather than a uniform spatial hash over every segment pair.

**Verdict:** nothing publishes a 60 Hz general rope self-contact/knot
answer. The two usable ideas are (a) IMC's penalty-based segment-segment
contact energy as a cheaper-than-IPC model *if* we ever need general
self-contact, accepting its soft non-penetration guarantee, and (b)
curvature/bounding-sphere pre-culling (inferred, not published for ropes)
to avoid ever running a self-contact check on the ~90% of a typical rope
that is locally straight.

---

## 7. What shipping engines and commercial plugins actually do today

- **Obi Rope / Obi 7 (Unity, virtualmethodstudio.com — vendor docs,
  fetched directly).** Particle XPBD; ropes/rods are 1-D "simplices."
  Narrow phase is Frank-Wolfe optimization against analytic *or*
  precomputed-distance-field colliders (§4) — this is the most
  advanced shipping implementation found in this survey, already doing
  what §4/§5 recommend. Obi 7 (current) removed the old CPU-only "Oni"
  solver in favor of a GPU compute backend for large particle counts;
  self-collision between simplices sharing a particle is explicitly
  skipped to avoid constraint fighting (our own rule, independently
  arrived at). Obi's own docs recommend against surface-collision mode
  for dense self-colliding cloth on performance grounds — no claim of
  solved general rope self-contact.
- **Unity (built-in, non-Obi).** No first-party rope solver; DOTS/Unity
  Physics ships only rigid joints. Ropes are conventionally either Obi
  (above) or hand-built joint chains.
  
- **Unreal Engine — Cable Component.** Per Epic's own docs (4.27-era,
  still the current implementation as of 5.x per marketplace listings —
  vendor docs, not independently benchmarked): Verlet integration over a
  particle chain with distance constraints, kinematic ends. This is
  **visual-only** — it is not part of Chaos and applies no two-way
  physical coupling or documented SDF/mesh narrow phase beyond simple
  sphere/capsule queries. Chaos itself (Unreal's physics engine proper)
  has no dedicated rod/rope solver found in its documentation; ropes
  built "in Chaos" in practice mean rigid-body chains of capsules joined
  by physics constraints — the same pattern as Havok, below. Treat this
  section as inferred from official docs plus absence of a documented
  Chaos rope feature, not as an exhaustive audit of Epic's source.
- **Jolt Physics.** Verified directly against GitHub release metadata
  (`api.github.com/repos/jrouwe/JoltPhysics/releases`, actual publish
  dates). Soft bodies use XPBD (same dual formulation, same mass-ratio
  problem as our own core — see the companion mass-ratio note). **v5.4.0
  (published 2025-09-27)** added Cosserat rods to soft bodies — "a stick
  constraint with an orientation... to simulate vegetation in a cheap
  way" (release-notes wording). **v5.6.0 (published 2026-07-11, i.e.
  twelve days before this survey)** extended this to strand-based hair
  simulation built on Cosserat rods with long-range attachment and
  guide/follow hair. This is the newest concrete engine feature found in
  the entire survey. No mention of SDF-based or terrain contact for
  these rods in the release notes fetched; scope reads as
  hair/vegetation-first, not load-bearing cable-first.
- **NVIDIA PhysX 5.** Ropes are conventionally built from the
  particle-constraint system PhysX 5 absorbed from the former NVIDIA
  Flex library (PBD particles) or from chains of capsule rigid bodies
  joined by spherical joints (both patterns are shown in NVIDIA's own
  Isaac Sim forum examples — vendor forum, not a spec). No dedicated
  rod/DER solver with SDF terrain contact was found in PhysX 5 docs.
- **Havok.** No dedicated rope/rod product found. Chain simulation is
  built from `hkpConstraintChainInstance` / stiff-spring or ball-socket
  chains of rigid bodies (inferred from Havok's own blog on its
  constraint solver plus third-party tutorials — not an official "Havok
  Rope" feature page, so treat as inference from adjacent docs).
- **Rapier (Dimforge, Rust).** Has a "rope joint," which per its own
  docs (rapier.rs) is a maximum-distance constraint between two rigid
  bodies — a joint primitive, not a discretized rod with its own
  bending/contact model. 2025 work (per Dimforge's own 2025-review blog
  post) was overwhelmingly a performance/API migration (nalgebra to
  glam), not new rope/rod capability.
- **Blender.** No native rope solver exists today. Community workarounds
  are rigid-body chains or cloth-solver abuse (third-party add-ons:
  Gravity Rope, Easy RB Pro). **Notably, and very recently:** Blender's
  own developer blog (developer.blender.org/docs, XPBD solver design
  doc, 2025 Geometry Nodes Workshop) shows Blender is actively designing
  an XPBD-based hair/rod solver using Cosserat rods as the base model,
  and its own design discussion explicitly weighs **SDF vs BVH-tree
  collision** for that solver — i.e., the exact architectural question
  this document is answering for us is, independently, the live design
  question in Blender's own core development right now. Not shipped;
  cited as a signal that our SDF-first instinct (§4/§5) is where the
  wider field is also converging, not a maverick choice.

**Summary: no shipping engine or commercial plugin does general rod
self-contact/knots at any rate; the most advanced production narrow phase
(Obi) already does exact segment-vs-distance-field contact, validating
§4/§5 as the highest-leverage concrete upgrade available to us; and the
newest engine feature in the whole survey (Jolt Cosserat rods, Sept 2025 /
July 2026) is aimed at cheap decorative geometry, not load-bearing ropes —
i.e. it is not a competing solution to what we are building.**

---

## 8. The capstan equation as a validation target

Confirmed form: **T2 = T1 · e^(μθ)**, where θ is the total wrap angle in
radians and μ the (Coulomb, kinetic at slip onset) friction coefficient —
the Euler-Eytelwein / capstan equation. Classical result (Euler 1769,
Eytelwein 1808); Wikipedia's summary was used only to confirm the
standard statement and historical attribution, not as a primary source
for anything novel — this equation is old enough and well-established
enough that no further verification chain is warranted.

**Confirmed as an actual validation target in current (2025) simulation
literature**, not just a textbook exercise: Li & Chou, *A Convex
Formulation of Compliant Contact between Filaments and Rigid Bodies*
(§3), wraps a simulated rope around a cylindrical post through a
controlled wrap angle, holds one end with a PD controller, pulls the
other with increasing force, and confirms the recovered T1/T2 ratio
follows e^(μθ) at μ=0.2 across multiple wrap angles. This is exactly the
kind of closed-form-vs-simulation acceptance test our own catenary/mass
tests already use — same discipline, different closed form.

**Caveat, from the mechanics-of-materials side (not simulation):** the
plain Euler-Eytelwein formula assumes a perfectly flexible, frictionless
-bending fiber. Real rods with bending stiffness deviate — the
"generalized capstan problem" literature (bending rigidity + nonlinear
friction) exists specifically because the plain formula under- or
over-predicts for stiff cables at small wrap radii; I did not fetch these
papers in full (found via search only: ScienceDirect abstracts on
"Effect of Bending Rigidity on the Capstan Equation" and the generalized
capstan problem) so they are noted as context, not cited as verified
results. Practical implication for us: the capstan test is a clean
acceptance target for a thin/flexible rope over a large-radius post
(where bending stiffness is negligible next to the wrap radius), and a
progressively worse one as rope radius approaches post radius — exactly
the regime where our own "tube sink at sharp edges" finding already lives.
**We do not currently have this test; it is a cheap, well-precedented gap
to close** (§ recommendations).

---

## Rejected, with reasons

- **Adopting IPC or C-IPC wholesale.** Minutes per timestep, verified
  from the paper's own numbers (§2). A rewrite of this scale is not a
  collision-module change; it would mean abandoning the XPBD/AVBD core
  entirely. The guarantee (never tunnels, any timestep) is real but we
  already bound tunneling by substep count (ADR 0006), which is cheaper
  and sufficient for our stated envelope.
- **GPU-only IPC descendants (GIPC, StiffGIPC, the 2025/2026
  barrier-free method) as a real-time path.** All require CUDA; none
  states a frame budget; the fastest (103x over GIPC) applied to the
  slowest verified IPC number still lands near a tenth of a second, not
  a 60 Hz slice, and would still require a GPU we cannot assume the host
  has (CPU, no engine fork is a stated constraint).
- **Daviet's GPU ADMM hair solver (2023) as a friction upgrade.**
  0.18-8 s/frame at hair scale, GPU-bound; the exact-Coulomb solve it
  performs is the right *model* but the wrong *implementation target* —
  our velocity-stage Coulomb split is already the same physical model at
  a fraction of the algorithmic weight, because we have one rope's worth
  of contacts, not thousands of hair strands.
- **Convex/Drake-style filament contact (Li & Chou 2025) as our
  solver.** Built for robotics planning/estimation inside Drake, not a
  standalone real-time core; no throughput numbers found; adopting it
  would mean adopting Drake. Its capstan validation methodology is
  worth stealing (§8); its solver is not.
- **Choi/Tong/Jawed's IMC contact energy as a wholesale self-contact
  model.** GPL-3.0 licensed reference code rules out reuse of the
  implementation in an MIT-licensed plugin without relicensing; the
  *technique* (penalty-based segment-segment contact energy) is
  reimplementable from the paper's math, but there is no published
  60 Hz number to justify prioritizing it now, ahead of the cheaper
  segment/SDF work in §4/§5.
- **GPU cloth self-collision culling (PSCC, I-Cloth) verbatim.** Aimed
  at 100K+ triangle cloth meshes on a GPU; our self-contact problem
  (one rope, up to a few hundred segments) is two to three orders of
  magnitude smaller, and the CPU-only constraint rules out the GPU
  hashing kernels directly. The curvature-culling *idea* (§6) is kept;
  the GPU implementation is not.

---

## Patent and licensing risk

- **CN102495752B, "Flexible rope simulation method," Shandong University
  (Tian Lan, Lu Xiaoshan, Qi Guoqiang, Lu Dongyu), filed 2011-12-05,
  granted 2014-06-18.** Checked via Google Patents. Claims a
  twelve-step method: capsule-per-segment collision boxes, spherical
  joints between segments, stretch correction by a specific position
  formula. **Status: expired, terminated 2020-11-13 for non-payment of
  annual fees.** China-only in any case. No action needed; recorded here
  because the claim shape (capsule collision boxes per rope segment) is
  close enough to generic rope architecture that it is worth having
  checked and dismissed rather than silently ignored, the way the AVBD
  note handles Roblox's patent.
- **IPC family code (ipc-sim/IPC, ipc-sim/ipc-toolkit, ipc-sim/C-IPC on
  GitHub): MIT-licensed** per the repos' own LICENSE files (checked via
  search, not independently re-read license text). Free to consult or
  reimplement from; no reuse is proposed here regardless (see Rejected).
- **rod-contact-sim / imc-der (Choi/Tong/Jawed group,
  github.com/QuantuMope/imc-der and github.com/StructuresComp/rod-contact-sim):
  GPL-3.0**, confirmed via the GitHub API. Copyleft — flagged in case a
  future contributor is tempted to lift code rather than reimplement the
  published algorithm; the algorithm itself (a penalty energy formula in
  a peer-reviewed paper) is not itself under that license.
- **No patent concerns found** for: golden-section/Frank-Wolfe segment
  vs. SDF closest-point search (both are generic, decades-old numerical
  optimization techniques, not novel IP in Macklin et al. 2020's own
  framing); the capstan equation (18th/19th century); Jolt's Cosserat rod
  feature (Jolt is MIT-licensed, jrouwe/JoltPhysics, and Cosserat rod
  theory itself is 1907-era continuum mechanics).

---

## Recommendations, ranked by value/effort for this project

1. **Segment-vs-analytic-shape closest-point narrow phase (§4).** Highest
   value, lowest effort. We already evaluate box/sphere/plane distance
   analytically per sample; extending the midpoint sample to a real
   1-D optimization (closed-form for plane/sphere, a handful of iterations
   of golden-section or even a direct segment-vs-box closest point, which
   has known closed forms) is measured, by an independent paper, to cost
   about the same as what we already do. Directly retires the two
   documented artifacts (tube sink, two-corner ratchet) that the project
   already spent a measurement session characterizing.
2. **Route the host's analytic SDF into the same collider interface
   (§5).** Second-highest value. This is architecturally almost free
   once (1) is done — the collider abstraction becomes "anything that
   answers `distance(p) -> (d, grad)`," and box/sphere/plane become three
   implementations of the same interface the SDF is a fourth of. Directly
   closes ADR 0006 point 9's open problem for concave/voxel terrain,
   without convex decomposition and without a per-substep engine query.
   Caveat honestly stated in §5: this rests on one paper's evidence, not
   a mature sub-field — validate the "free" cost claim on our own SDF
   before trusting it, the way the mass-ratio note insists on measuring
   rather than trusting a paper's headline number.
3. **Adopt the capstan test as an acceptance test (§8).** Cheap
   (one new spike scene, closed-form target we already know how to code
   against — see the catenary test we already ship), high diagnostic
   value: it independently exercises exactly the friction-at-a-curved
   -contact path our Coulomb model claims to get right, at a difficulty
   the mass-ratio note's discipline would call for before trusting the
   friction column the way it now trusts the tension column.
4. **Curvature/bounding-sphere pre-cull as the entry point for general
   self-contact, when that gate is opened (§6).** Not urgent (no
   in-house pile/knot requirement is stated yet), but cheap to keep in
   mind: reuses the exact per-collider bounding-sphere cull pattern
   already measured to be the dominant win in ADR 0006, applied to
   segment-pairs instead of collider-pairs, before reaching for a
   general spatial hash.
5. **Track Jolt's Cosserat rod work as a compatibility/competitive
   signal, not a dependency.** No action now — Godot's Jolt integration
   does not expose it, and its scope (cheap decorative strands) does not
   overlap our load-bearing use case — but it is the newest concrete
   fact in this survey (July 2026) and worth a glance again in six
   months.

Not recommended for adoption at any priority (see Rejected, with reasons):
IPC/C-IPC wholesale, any GPU-only IPC descendant, the GPU ADMM hair
solver, the Drake convex filament solver, IMC's GPL-licensed code, and
GPU cloth self-collision culling kernels.
