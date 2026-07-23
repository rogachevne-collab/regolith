# 0005: Red-black constraint sweeps

Date: 2026-07-23. Status: accepted.

## Context

Gauss-Seidel results depend on traversal order, which makes sweep order part
of observable behavior, not an implementation detail. The first core swept
forward and backward on alternate iterations — but every shipped default
uses `iterations = 1`, so the alternation never happened and every sweep ran
head-to-tail with a systematic bias.

The obvious repair (alternate on substep index instead) restores the intent
in one line, and locks in sequential Gauss-Seidel — which does not
parallelize. The C++ port wants SIMD and threads.

## Decision

Color the chain red-black: segment `j` connects particles `j` and `j+1`, so
even-indexed segments share no particle with each other, and likewise odd.
Solve all even segments, then all odd. Within a color the result cannot
depend on order, so each color is a parallel batch.

## Consequences

- Deterministic by construction; pinned by a bit-identity check in
  `tests/test_free_fall.gd` (measured drift: exactly 0.0).
- The GDScript reference and the future C++ core can produce identical
  numbers, which is the entire reason the reference stays in the repo
  (ADR 0002). A sequential-Gauss-Seidel choice would have made the reference
  useless as a cross-check the moment the port went parallel.
- Convergence per iteration is slightly worse than sequential Gauss-Seidel.
  Accepted: substeps are the primary quality dial (Small Steps, and Obi's
  own tuning guidance), not iterations.
- The same coloring generalizes to nets and cloth (graph coloring), which is
  where the solver is headed.
