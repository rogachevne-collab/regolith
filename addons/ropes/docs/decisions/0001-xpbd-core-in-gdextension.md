# 0001: XPBD core in a C++ GDExtension

Date: 2026-07-23. Status: accepted.

## Context

A GDScript Verlet rope shipped in the host game and hit a wall. Measured root
causes: collision resolved in a separate phase after relaxation with no
re-convergence, and tension *estimated* from the geometric length of that
inflated polyline — a constant phantom stretch turned into large phantom
forces on attached vehicles. 16 relaxation passes was the GDScript budget.

Engine-side alternatives exist in Jolt (DistanceConstraint, soft-body ropes)
but are not exposed through stock Godot; using them requires an engine fork,
which disqualifies them for a distributable addon.

## Decision

Write the solver as XPBD in C++ via GDExtension:

- stretch, contact and attachment constraints iterate in one solver loop;
- tension is read from Lagrange multipliers, never estimated from geometry;
- constraint stiffness is compliance-based, independent of iteration count
  and timestep;
- the world is reached only through public physics API.

Prior art: Obi Rope (Unity) lives the same way on top of PhysX.

## Consequences

- Runs on stock Godot; distributable to the community.
- C++ affords 20–50 iterations plus substeps where GDScript afforded 16 passes.
- Hardest known case is heavy two-way loading (a motor pulling against the
  rope): mitigations are substeps, correct effective mass at attachment
  points, warm starting.
- GDScript remains only in thin node wrappers and editor tooling.
