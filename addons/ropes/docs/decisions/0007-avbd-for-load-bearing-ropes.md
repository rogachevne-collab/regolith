# 0007: AVBD for load-bearing ropes, with a length bound

Date: 2026-07-23. Status: proposed.

## Context

ADR 0001 chose XPBD and named the hardest case it would face: "heavy two-way
loading (a motor pulling against the rope)". Spike B then found the shape that
failure actually takes — a coupled body that never sleeps, 0 sleeping ticks out
of 840, because position-based correction converts constraint error into
momentum every frame and hands it back.

`docs/research/mass-ratio-state-of-the-art.md` establishes why this is
structural rather than a tuning failure: dual methods (XPBD, sequential
impulse) are ill-conditioned in *mass* ratio, primal methods are not. It also
shows plain XPBD is adequate for Regolith's own 100:1 case if it is given
32–64 substeps. So this decision is not forced by the game. It is forced by
what the addon promises its users.

We ported AVBD to a chain of particles (`core/avbd_rope.gd`) and measured it
against the shipping core on identical scenarios. Numbers and method in the
research note; the two that decide this are:

- On a 250 kg payload, AVBD at 8 iterations costs less than XPBD at 32
  substeps (755 vs 912 us), holds 3.5x less stretch (0.92% vs 3.28%), and
  moves 13x less on a settled rope (0.41 vs 5.39 mm per tick).
- Past some size AVBD's reported tension collapses while its stretch stays
  excellent. Free hanging: +1.0% at 80 segments, +14% at 200, +947% at 400.
  **Under load it arrives far sooner** — with 250 kg, 25 segments still reads
  +3.3% but 80 segments already reads +60%. XPBD stays within a few percent at
  every length tested.
- That bound has since been measured properly and it is **not** a segment
  count: it is fineness, `M = segments / segment_length`, and the requirement
  is `iterations >= 0.85 * M^0.5` free hanging, `1.15 * M^0.6` loaded (research
  note, `spikes/spike_g_length_guard.gd`). Segment count enters only as a
  weaker second term. The practical consequence is the opposite of the obvious
  one: refining a rope is more dangerous than lengthening it.

## Decision

Adopt AVBD as the solver for **load-bearing** ropes, bounded by a measured rule
rather than an assumed one, with the budget raised to meet it automatically and
a warning when the rule outruns the ceiling — and keep XPBD.

- `max_stretch` is the public stiffness knob; the penalty ramp beta is derived
  per segment from it and from the segment's own multiplier. A fixed beta is
  not exposed, because no constant survives a change of scale and the failure
  is invisible in every metric except tension.
- Never fewer than 8 iterations. Below that the rope still holds its length
  while the multiplier has not converged, and the tension readout — the
  quantity ADR 0001 exists to protect — is off by orders of magnitude.
- Substeps stay at 1. Warm starting decays the multiplier once per step, so
  substepping multiplies that decay and discards the state the method runs on.
  This inverts XPBD's tuning advice, deliberately.
- XPBD stays in the repository as the cross-check reference (ADR 0002) and as
  the solver for ropes past the segment bound. It is **not** exposed as a
  user-facing choice: two solvers means every feature — collision, winch,
  tearing, attachments, breaking — must exist twice or the setting silently
  changes which features work.
- The solver is never switched at runtime. AVBD's state includes the
  multiplier and penalty accumulated over frames; entering it cold reproduces
  the free-fall-and-bounce failure, and it would do so exactly when the rope
  becomes loaded, which is when the transient is most visible. It would also
  make behaviour depend on history, discarding the determinism ADR 0005 was
  written to buy.

## Consequences

- Blocked on collision. ADR 0006's contact architecture exists for XPBD only;
  AVBD has no contacts yet. Contacts and Coulomb friction are native to the
  formulation — bounds on the multiplier per row, exactly as the paper does
  them — but that is unwritten code, and until it lands AVBD cannot replace
  XPBD for anything that touches the world. This is why the status here is
  *proposed*.
- `tests/test_catenary.gd` now runs against both cores — resolved, not left
  ambiguous. The 2.3% sag reading was never a shape error: AVBD is a soft
  constraint by construction (`max_stretch`), so its rope settles genuinely
  longer than the nominal 12 m — measured 12.081 m, +0.68% stretch, in this
  scenario. A shallow catenary's sag is sensitive enough to length that
  solving the same analytic formulas for the length AVBD actually produced,
  instead of the nominal 12 m, turns the +2.3% reading into +0.05% — shape is
  right for the rope it actually built. XPBD shows the same effect at a
  smaller scale (+0.04% stretch, sag error +0.1% to +0.01%) because it too is
  not perfectly rigid, just far stiffer. The test now solves the catenary
  per-core, from each core's own settled length, for the sag and tension
  checks, and separately bounds the settled length itself against what that
  core is designed to hold — near-zero for XPBD, 1.5x `max_stretch` for AVBD
  — so a real regression in either core's shape or its stretch behavior still
  fails it. Numbers and method: `spikes/spike_f_catenary_and_length.gd`,
  `docs/research/mass-ratio-state-of-the-art.md`.
- The bound is a guard, not a doc line — done. `AVBDRope.required_iterations`
  is clamped inside the core so the core cannot be used outside its envelope
  even by a caller who never read this, and `Rope3D` applies it where the
  segment count is decided, warning in the editor and at runtime when the
  requirement runs past the ceiling of 96. What that costs is in the core's own
  comment, in numbers: 100 m free hanging at 4 segments per metre goes from 16
  iterations to 36, and the same rope carrying 250 kg wants 98, which is the
  first configuration the guard refuses to buy silently.
- Long ropes want a different method, and the research note already names it:
  Deul et al. 2018, direct O(N) solve of the chain by the Thomas algorithm,
  which removes propagation error entirely rather than iterating against it.
  The length wall is what promotes that from a curiosity to the plan.
- Two solvers is a maintenance cost we take on knowingly, on the bet that
  AVBD's collision work lands and XPBD's role shrinks to reference and to
  ropes past the bound.
