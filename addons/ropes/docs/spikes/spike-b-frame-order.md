# Spike B: frame ordering and impulse coupling with Jolt

Date: 2026-07-23. Setup: Godot 4.8-dev double build, Jolt, 60 Hz, project
gravity 1.62 (moon). Scene: 10 kg cube hanging from a 3-segment GDScript XPBD
chain (rest 1.5 m), coupled via `apply_central_impulse`, 900 ticks headless.
Code: `spikes/spike_b.gd` (throwaway, keep only while useful).

## Findings

1. **Solver slot confirmed.** In `_physics_process(N)` we observe the fully
   post-step state of tick N-1; an impulse applied there integrates during
   tick N's step at full strength (measured dv = 0.4992 of expected 0.5,
   dx = dv·dt exactly). So: read state → solve → apply impulses, all in
   `_physics_process`. Total transport delay one tick — the standard external
   solver setup, workable.
2. **`_integrate_forces` is not our hook.** It fires inside the server step,
   per body — no place for a multi-body constraint loop, no advantage over
   `_physics_process`. Ignore it.
3. **Space queries from `_physics_process` work and are cheap.** 1000 raycasts
   = 1.7 ms, 1000 sphere overlaps = 0.5 ms, from GDScript on a dev machine.
   Per-particle collision via shape queries is viable even before C++.
4. **A coupled body never sleeps (T3: 0 sleeping ticks of 840).** Pure
   positional correction is elastic: the chain and body traded energy for the
   whole 14 s run (impulses fired on 190 ticks, velocity never stayed low).
   Consequence for the core: damping must live inside the constraint
   (compliance + velocity-level damping), and the addon needs its own
   quiescence policy for coupled bodies — Jolt's sleep will not save us.
   This reproduces the old rope's disease in miniature, by construction.
5. **Read gravity from the world** (`ProjectSettings` / space state), never
   hardcode: this project runs 1.62 m/s².

## Stability observed

No explosion, no drift: body oscillated calmly around the analytic hang point
(mean y ≈ 2.4 vs expected 2.3 with a stretchy 20-iteration chain), bounded
chain length 1.29–1.57 m. Undamped but sane — with compliance-based damping
this becomes a rope.
