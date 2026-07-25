# Physics projection — куда смотреть

`SimulationPhysicsProjection` — Node3D-проекция kernel → Jolt: тела, joints,
колёса, актуаторы, канаты, parking freeze, read-back motion. Логика режется
на координаторы/утилиты; публичные сигнатуры монолита заморожены
(`docs/plans/ANTIGOD-CONTRACT-FREEZE.md`).

## Порядок под-тиков `_physics_process`

Только authoritative world (`_world.authoritative`). Порядок заморожен:

1. `_ensure_tick_key_caches()` — PERF-H03 ключи `_bodies` / `_wheel_constraints`
2. `_tick_rotor_actuators(delta)` → `ActuatorPhysicsTickCoordinator`
3. `_tick_piston_actuators(delta)` → `ActuatorPhysicsTickCoordinator`
4. `_tick_wheel_bodies(delta)` → `WheelPhysicsTickCoordinator`
   (внутри: parking freeze scan → `AssemblyParkingFreezeCoordinator`, затем per-wheel)
5. `_tick_thrusters(delta)` → `ActuatorPhysicsTickCoordinator`
6. `_tick_cable_ropes(delta)` → `_tick_cable_tension(delta)` → `_tick_cable_anchors(delta)`
7. `PhysicsMotionSyncCoordinator.sync_live_assembly_motions` — Jolt → kernel
   motion read-back (скип frozen assemblies)
8. запись `_last_tick_breakdown_us` (+ `tick_seq`, `native_gap_since_prev_tick`)

## Куда идти

| Задача | Файл |
|---|---|
| facade: bind/rebuild, проекция тел, публичный API, канаты | `scripts/simulation/projection/simulation_physics_projection.gd` |
| structural events: place / dismantle / split / merge | `scripts/simulation/projection/structural_event_coordinator.gd` |
| motion capture / sync (live read-back, pre-teardown snapshot) | `scripts/simulation/projection/physics_motion_sync_coordinator.gd` |
| parking freeze / wake | `scripts/simulation/projection/assembly_parking_freeze_coordinator.gd` |
| wheel tick / loco tuning / wheel joint build | `scripts/simulation/projection/wheel_physics_tick_coordinator.gd` |
| piston / rotor / thruster / gyro tick | `scripts/simulation/projection/actuator_physics_tick_coordinator.gd` |
| тела / mass / COM / inertia math | `scripts/simulation/projection/assembly_physics_math.gd` |
| коллайдеры / dry mass | `scripts/simulation/projection/collider_projection_util.gd` |
| колёса (6DOF helpers, steer PD, drive) | `scripts/simulation/projection/wheel_body_projection_util.gd` |
| поршень / ротор / шарнир / thruster utils | `piston_projection_util.gd`, `rotor_projection_util.gd`, `hinge_projection_util.gd`, `thruster_projection_util.gd` |
| канаты (XPBD / legacy / tension / curve) | `xpbd_cable_rope_solver.gd`, `cable_rope_solver.gd`, `cable_tension_util.gd`, `cable_curve_util.gd` |
| merge pose gateway | `scripts/simulation/projection/simulation_merge_gateway.gd` |
| grid pose | `scripts/simulation/projection/grid_pose_util.gd` |
| visuals (element / piston / industry) | `element_visual_projection.gd`, `piston_visual_projection.gd`, `industry_*_projection.gd` |
| world loot bodies | `scripts/simulation/projection/world_loot_projection.gd` |
| projected body script | `scripts/simulation/projection/projected_assembly_body.gd` |

## Structural events → `StructuralEventCoordinator`

Кластер реакции на `SimulationWorld.structural_event` вынесен в
`structural_event_coordinator.gd` (`RefCounted` + `static func`, первый
аргумент — `projection`).

**В координаторе:** диспетчер `on_structural_event`; инкрементальный append
(`try_append_placed_element`, `try_append_multibody_element`,
`multibody_topology_matches`, `refresh_group_body_mass_com`,
`append_element_to_carriage_records`); инкрементальный remove
(`try_remove_projected_element`, `try_remove_multibody_element`,
`remove_element_from_carriage_records`, `free_element_colliders`,
`refresh_single_body_mass_com`); полная перепроекция `reproject_assembly`;
split (`handle_split`, `project_split_child`, `seed_motion_for_split_child`) и
merge (`handle_merge`, `compute_merged_motion` — бывший `_merged_motion`,
переименован чтобы не затеняться локальной `merged_motion`).

**Осталось в монолите:** `bind_world`/`unbind_world`, `rebuild_all`,
`_project_assembly` и обе ветки (`_project_assembly_single`,
`_project_assembly_multibody`), `_remove_body`, `_restore_evacuated_drivers`,
`_capture_*`, `_body_mass`, `_body_center_of_mass_world`,
`_estimate_body_inertia`, `_compile_assembly_groups`,
`_attach_colliders_to_body`, `_sync_wheel_loco_body_physics`, всё состояние
(`_bodies`, `_element_records`, `_assembly_group_bodies`, `_*_constraints`,
`_root_group_ids`, `_projected_revision`, `_mounted_bodies`) и весь канатный
код. Координатор читает и мутирует поля владельца напрямую
(`projection._element_records.erase(...)`).

**Правило обёртки сигнала.** `_on_structural_event(event)` обязана остаться
обычным (не `static`) методом узла и той же самой `Callable`, что в
`connect` / `is_connected` / `disconnect`. Нельзя
`StructuralEventCoordinator.on_structural_event.bind(self)`: `Callable.bind`
дописывает аргументы **после** аргументов сигнала, вызов получится
`on_structural_event(event, projection)` вместо `(projection, event)`.
`static` на обёртке тоже нельзя — в статике нет `self`, в сервис уедет `null`.

**Заморожено (§2 контракта):** порядок веток `match` по `kind`; цепочка
`try_append_placed_element` → `try_remove_projected_element` → иначе
`reproject_assembly`; имена ранних `fail_reason` (`wheel_specs`,
`driven_specs`, `mounted`, …); `_restore_evacuated_drivers()` строго **после**
проекции в reproject / split / merge (иначе игрока выбрасывает из кресла).
`_tick_key_structure_rev` координатор не бампит — бампы живут в монолите.

## Публичный API (заморожен)

| Метод | Назначение |
|---|---|
| `sync_body_motion_now(assembly_id)` | форс read-back одного тела → kernel |
| `align_body_motion(target, reference)` | скопировать pose/vel reference → target + sync |
| `get_last_tick_breakdown_us()` | диагностический словарь sub-tick usec |
| `wake_assembly_bodies(assembly_id)` | снять freeze со всех тел сборки |
| `wake_frozen_near(center, radius)` | разбудить parked у dig |
| `is_rope_frozen(link_id)` | статус freeze каната |
| `rope_path(link_id)` | полилиния каната |
| `rebuild_all()` | полная перепроекция всех сборок |

## Правила

- **R9** — в `_physics_process` без лишних аллокаций и полных пересчётов.
  Ключи `_bodies` / `_wheel_constraints` кэшируются (PERF-H03); bump
  `_tick_key_structure_rev` только на structural mutation. Координаторы
  ходят по кешам владельца, не зовут `_bodies.keys()` заново.
- **Порядок вызовов** в `_physics_process` заморожен — не переставлять
  actuators / wheels / cables / motion sync.
- **Граница владения:** sim владеет смыслом (topology, motion state, commands);
  Jolt владеет динамикой (integrate, contacts). Projection — мост: пишет
  constraints/bodies и читает pose обратно в kernel.
- Координаторы — `RefCounted` + `static func`; первый аргумент `projection`
  (нетипизирован — защита от цикла `class_name`). Значения от `projection`
  объявлять с явным типом (`var body: PhysicsBody3D = ...`), не `:=`.
  Мутации state — через поля/методы projection, не service→service.
- Публичные сигнатуры монолита не ломать (обёртки → координатор).
- `_last_tick_breakdown_us` живёт в монолите; колёса пишут в него через
  `projection._last_tick_breakdown_us`.

## Спеки

- Граница владения: `docs/PHYSICAL-LANGUAGE.md` (индекс → «Граница владения»)
- Контракт extract: `docs/plans/ANTIGOD-CONTRACT-FREEZE.md`
- Jolt: [Using Jolt Physics](https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html)
