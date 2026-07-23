# 0003: Internal damping and drag are separate physical models

Date: 2026-07-23. Status: accepted.

## Context

The first core damped absolute velocity globally:
`v = (x - x_prev)/h * (1 - damping*h)`. That models a world filled with
molasses. Its steady state is a terminal speed of `|gravity| / damping` —
at the shipped default (0.3) under lunar gravity, 5.4 m/s. A rope dropped
from nine meters already hit the cap, and swinging payloads moved through
syrup. The static catenary test could not see any of it: at equilibrium
every damping model is silent.

## Decision

Two knobs, two different physical claims.

- `damping` (1/s) — **internal**: exponentially decays the RELATIVE velocity
  of neighboring particles, applied as a momentum-conserving impulse pair.
  This is the rope's own fiber friction. It is Galilean invariant, so it
  cannot slow a rope that falls or flies as a whole; it only resists
  stretching, bending and vibration. Default 0.5.
- `drag` (1/s) — **aerodynamic**: exponentially decays ABSOLUTE velocity.
  It does impose a terminal speed of `|gravity| / drag`, which is what air
  actually does. Default 0, because vacuum is the host project's setting
  and because a wrong terminal velocity should never be a silent default.

## Consequences

- Free fall is exact regardless of internal damping — pinned by
  `tests/test_free_fall.gd`, which drops an unanchored, 1.5x-stretched rope
  with a heavy end mass and requires the center of mass to match the
  analytic fall to 1e-6 m. Measured: 2e-10 m over a 44 m drop.
- Drag is falsifiable too: the same test checks a dragged fall against the
  analytic linear-drag solution (measured 0.108% error).
- Neither model can bias a static comparison: both vanish at equilibrium.
  That is what makes it legitimate for the catenary test to use them purely
  to settle the rope faster.
- Known and accepted: neighbor-relative damping is weak on long-wavelength
  modes (adjacent particles barely move relative to each other in the
  fundamental swing). A rope in vacuum therefore rings for a long time —
  physically right, occasionally inconvenient. Measured on a 20 kg weight
  hanging from a 3.5 m rope, `damping` 0.5 and `drag` 0: the peak-velocity
  envelope decays with a half-life of about eleven seconds, at the SAME
  rate under lunar and Earth gravity. Only the amplitude differs (6x), so
  the identical behavior reads as "settles fine" on the Moon and "never
  settles" on Earth. The honest remedy is `drag`: Earth gravity comes with
  air, and air is what actually stops a swinging rope. A demo that offers
  Earth gravity should offer air with it. If a "swing damping" knob is
  ever wanted, add it as a third, explicitly-named model; do not silently
  strengthen either of these two.
