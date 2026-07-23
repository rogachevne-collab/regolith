# 0002: GDScript reference core precedes the C++ port

Date: 2026-07-23. Status: accepted.

## Context

ADR 0001 commits the production core to a C++ GDExtension. But the
GDExtension build pipeline for this engine setup (custom double-precision
4.8-dev build + stock Godot) is unproven — the pipeline spike was consciously
skipped — and solver math is far cheaper to get right where iteration is
instant and results are visible in a demo scene the same hour.

## Decision

Land the solver math first as a reference implementation in GDScript
(`core/xpbd_rope.gd`) with the exact data contract the C++ core will have:
packed arrays in, packed arrays out, no scene-tree or physics-server access.
Analytic tests (catenary, then others) pin its behavior. The C++ port is then
a mechanical translation that must pass the same tests and beat it in bench.

## Consequences

- Rope count and resolution are CPU-limited until the port; fine for demos
  and for Regolith's current needs.
- The reference stays in the repo after the port as documentation and as a
  cross-check for the native backend.
- Risk accepted: the pipeline surprise (if any) is deferred to the port.
