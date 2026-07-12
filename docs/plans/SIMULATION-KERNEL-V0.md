# Simulation Kernel v0 — план реализации

**Обзор:** scene-independent authoritative Kernel для anchored base и rover:
typed archetypes/Blueprint, стабильные IDs, ordered structural commands,
deterministic split/merge, momentum-safe Jolt projection и snapshot roundtrip.
Миграция сохранит физику ровера через adapter; launch vehicle вне scope.

**Спека:** [`docs/specs/SIMULATION-KERNEL-V0.md`](../specs/SIMULATION-KERNEL-V0.md)

## Статус (2026-07-12)

| Этап | Статус |
|---|---|
| Доменный контракт, identity, split/merge | ✓ |
| Typed definitions + visual Blueprint baker | ✓ |
| Authoritative runtime (`SimulationWorld`) | ✓ |
| Snapshot v2 + momentum-safe Jolt projection | ✓ |
| Rover migration через locomotion adapter | pending |
| Anchored base + обе Assembly в `main` | pending |
| Focused regressions + smoke `main` | partial |

**Закрыто headless:** `KERNEL-V0`, `KERNEL-RUNTIME-V0`, `KERNEL-PROJECTION-V0`; полный
`./tests/run_tests.sh` — 12/12.

**Следующий шаг:** rover migration (§5) без переноса PoC-костылей в Kernel.

---

## 1. Зафиксировать доменный контракт ✓

- [`docs/specs/SIMULATION-KERNEL-V0.md`](../specs/SIMULATION-KERNEL-V0.md) и
  [`docs/PHYSICAL-LANGUAGE.md`](../PHYSICAL-LANGUAGE.md) — identity, grid, connectivity,
  split/merge, две истины авторитетного состояния.
- Три identity: persistent `ElementId`, persistent `AssemblyId`, transient
  projection/body id; Godot `NodePath`/`RID`/`instance_id` не доменные ссылки.
- Grid — 1 m, 24 ортогональные ориентации, multi-cell footprint. Rigid edge — только
  при совместимых structural faces/ports.
- Split survivor: `Anchor → element count → dry mass → lowest ElementId` (tie внутри
  одной Assembly); merge survivor: `Anchor → count → mass → lowest AssemblyId`.
- Merge endpoints A/B-stable; snapped `b_to_a_grid` выводится из continuous motion
  (tolerance 0.125 m / 7.5°), валидируется authority до мутации; survivor selection
  не меняет alignment. Dual-anchor merge удаляет loser anchor.
- v0: только `Rigid` и `Anchor`.

## 2. Typed definitions и visual Blueprint authoring ✓

- Resources в [`scripts/simulation/resources/`](../../scripts/simulation/resources/):
  `ElementArchetype`, `PortDefinition`, `ColliderDefinition`, `Blueprint`,
  `BlueprintElementPlacement`, `BuildRequirement`.
- Orientation utility, footprint rotation, deterministic baker/validator в
  [`scripts/authoring/`](../../scripts/authoring/).
- Authoring: [`scenes/blueprint_authoring/`](../../scenes/blueprint_authoring/);
  baked: [`resources/blueprints/baked/`](../../resources/blueprints/baked/).
- Slice-01 archetypes в [`resources/archetypes/slice01/`](../../resources/archetypes/slice01/).

## 3. Чистый authoritative runtime ✓

- [`scripts/simulation/simulation_world.gd`](../../scripts/simulation/simulation_world.gd):
  typed `RefCounted` state, authority ID allocator, typed structural commands
  (`SpawnBlueprintCommand`, `BreakRigidJointCommand`, `MergeAssembliesCommand`),
  `StructuralCommandResult`, deferred queue с immutable execution copies.
- Archetype registry, occupancy, rigid connectivity, atomic split/merge, tombstone
  redirects, snapshot v2 validation (topology semantics + referential integrity).
- `get_assembly` / `get_assembly_raw`; единственный motion writeback —
  `sync_assembly_motion(...)`.
- **Не сделано:** wiring structural commands через
  [`scripts/world_command_gateway.gd`](../../scripts/world_command_gateway.gd)
  (остаётся interaction/voxel path).

## 4. Snapshot и physics projection ✓

- Snapshot v2: assemblies + `motion`, elements (`build_progress`, `integrity`,
  `condition`), joints, redirects, archetype fingerprints.
- Projection: [`scripts/simulation/projection/`](../../scripts/simulation/projection/)
  — event-driven `SimulationPhysicsProjection`, `AssemblyId → body`,
  `ElementId → collider metadata`, `StaticBody3D` / `RigidBody3D`.
- Split: `v_child = v_parent + ω × (com_child − com_parent)`, ω inherited.
- Merge: linear + orbital angular momentum; spin — approximate (diagonal inertia
  estimate, ограничение Godot high-level API).
- Alignment gate: `GridAlignment` + `REASON_MISALIGNED_CONNECTION`.
- Focused test: [`scenes/test_simulation_projection.tscn`](../../scenes/test_simulation_projection.tscn).

## 5. Мигрировать rover без переноса PoC-костылей — pending

- Испечь `cart_rover` Blueprint со стабильными element/port bindings.
- Разделить [`scripts/cart.gd`](../../scripts/cart.gd): Kernel — topology/mass/split/merge;
  `CartLocomotion` — suspension, steering, tire forces, wheel visuals; adapter сохраняет
  API тестов.
- Заменить ad-hoc fragment consumption на kernel merge; detached wheel/bridge — generic
  assembly projection.
- После parity удалить authority из legacy `structure_model` / `assembly` (если ещё
  используются), оставив временные adapters.

## 6. Anchored base и интеграция main — pending

- Visual authoring: prebuilt industrial base (foundation/Anchor, frame, Slice-01 stubs).
- `SimulationWorld` + rover + base Blueprint в [`scenes/main.tscn`](../../scenes/main.tscn);
  [`scripts/bootstrap.gd`](../../scripts/bootstrap.gd) — R5 settle перед Anchor/projection.
- `launch_vehicle` и compatibility `PlacedBlocks` вне Kernel v0.

## 7. Проверить границы milestone — partial

**Сделано:** blueprint bake/validation, orientation+multi-cell, split/merge policy,
dual-anchor merge, snapshot roundtrip, projection colliders/momentum/anchor/cleanup,
malformed snapshot rejection, queued command immutability.

**Осталось:** rover parity regressions на kernel topology, anchored base в main,
ручной smoke (base неподвижна, rover feel, split/merge без телепорта, diagnostics).
