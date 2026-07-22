# Obi Rope 7.0 — public API notes (precedent study)

Date: 2026-07-23. Source: official manual at obi.virtualmethodstudio.com
(pages cited inline). What Unity's de-facto standard rope product exposes to
end users, and what it hides.

## Exposed

- **Per rope**: thickness (m); *resolution* — normalized particle density
  relative to thickness (`count = length / thickness * resolution`; 1 =
  particles overlap fully, 0.5 = barely touch; below 0.5 hurts collision
  robustness). Mass is authored per path control point, interpolated — no
  mass-per-meter knob. (ropesetup.html)
- **Stiffness**: always physical compliance in **m/N**, never normalized
  0..1; 0 = "as stiff as the budget allows" with an explicit disclaimer that
  achieved stiffness depends on substeps/iterations. Ropes get stretch
  compliance + stretching scale + max compression, and bend compliance +
  max-bending dead zone (0–0.04 world units recommended).
  (distanceconstraints.html, bendingconstraints.html)
- **Damping**: solver-global only (recommended ~0.15); no per-rope damping
  anywhere. (obisolver.html)
- **Quality dial**: substeps, solver-global. Official tuning: iterations = 1,
  raise substeps ("going over 10 is seldom needed"), touch iterations only as
  a targeted exception, lower resolution as last resort.
  (performancetips.html) — matches the "Small Steps" paper.
- **Attachments**: static (kinematic, one-way, cheap) vs dynamic (pin
  constraints, two-way). Dynamic ones expose exactly two knobs: compliance
  (m/N) and **break threshold (N)**. Mid-rope attachments work via particle
  groups from path control points. Docs warn to keep particle/rigidbody mass
  ratios small. (attachments.html)
- **Winch** (ObiRopeCursor): `ChangeLength(delta)` at a normalized position
  on the rope; requires particles preallocated for the max intended length
  ("pooled particles"). (ropecursor.html)
- **Tearing**: ropes only; tear resistance (N), tear rate (particles/frame,
  default 1); scripted `Tear(element)` + one `RebuildConstraintsFromElements()`
  per frame. (ropetearing.html)

## Hidden

- Per-rope substeps/iterations/damping — budget is global, a rope cannot ask
  for more solver effort than its siblings.
- Direct particle count — only the normalized resolution knob.
- Any promise of absolute rigidity — stiffness is compliance plus a budget
  disclaimer, by design.
- XPBD internals: batching, ordering, warm starting — zero user surface.

## Consequences for Ropes!

1. Stiffness knob, if public, is compliance in m/N with default 0 — no fake
   0..1 units. Damping and substeps live at a solver-budget level shared by
   all ropes, not per rope.
2. Core design: substeps are the primary quality dial, iterations secondary.
3. Attachment contract worth copying: {target, compliance, break_force} —
   break_force also answers our breaking question for v0.
4. Winch: preallocate particles for max length; our `length`-property design
   holds (simpler surface than a cursor component).
5. Watch particle spacing vs radius for collision robustness before choosing
   `segments_per_meter` defaults; Obi ties spacing to thickness for a reason.
