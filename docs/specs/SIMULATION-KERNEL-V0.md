# Simulation Kernel v0

Статус: Phase 1 — typed definitions, orientation, Blueprint bake/validation.
Phase 2 — authoritative `SimulationWorld` runtime, structural commands, snapshot.
Родительские документы: `docs/PHYSICAL-LANGUAGE.md`, `docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md`.

## Цель

Единая authoritative модель для anchored base и mobile machine:

- data-driven `ElementArchetype` и `Blueprint`;
- стабильные доменные идентичности, не зависящие от Godot Node/RID;
- детерминированная выпечка Blueprint из visual authoring;
- подготовка к runtime `SimulationWorld`, structural commands и Jolt projection
  (следующие фазы).

## Граница Phase 1

Входит:

- typed Resource definitions;
- 24 ортогональные ориентации, multi-cell footprint, поворот structural face;
- validator и headless-safe baker;
- minimal `@tool` authoring (`BlueprintAuthoringRoot`, `ElementMarker`);
- Slice-01 archetype fixtures и baked Blueprint assets;
- focused headless tests.

Не входит:

- `SimulationWorld`, occupancy solver, split/merge runtime;
- physics projection и snapshot roundtrip;
- rover migration и интеграция в `main.tscn`;
- Construction v1 commands и Industry Flow behavior.

## Граница Phase 2

Входит:

- scene-owned `SimulationWorld` (`scripts/simulation/simulation_world.gd`);
- typed `RefCounted` runtime state: `SimulationAssembly`, `SimulationElement`,
  `SimulationJoint`, `SimulationIdAllocator`;
- integer `GridTransform` (translation + `orientation_index` 0–23) с
  `compose` / `inverse` / `map_cell` / `map_element_pose`;
- spawn Blueprint → deterministic materialize `Rigid` и `Anchor` joints;
- typed `StructuralCommand` transactions, authority command IDs, ordered queue и
  typed `StructuralCommandResult`;
- split на `break_rigid_joint`, merge с survivor policy и tombstone redirect;
- versioned snapshot capture/restore (DTO dictionaries только на serialization boundary).

Не входит:

- Jolt projection и momentum-safe body rebuild;
- rover migration, `main.tscn` / `bootstrap.gd` integration;
- Construction v1 commands и Industry Flow behavior.

### Structural commands (Phase 2 schema)

Публичный command API не принимает dictionaries. Команды — typed `RefCounted`:
`SpawnBlueprintCommand`, `BreakRigidJointCommand`, `MergeAssembliesCommand`.
Authority всегда назначает `command_id`; для deferred queue завершение публикуется
сигналом `structural_command_completed(command_id, result)`.
`submit_structural_command()` помещает в queue typed execution-copy: caller object
не мутируется и последующие изменения его полей не меняют уже queued payload.
`GridTransform` копируется, immutable Blueprint Resource может разделяться.

Все команды возвращают typed `StructuralCommandResult`:

```gdscript
result.status: StringName
result.reason: StringName
result.data: Dictionary
```

Причины отказа: `stale_revision`, `invalid_reference`, `invalid_target`,
`overlap`, `incompatible_connection`, `invalid_transform`, `invalid_blueprint`.

| Тип | Обязательные поля |
|---|---|
| `SpawnBlueprintCommand` | `blueprint`, `grid_frame` |
| `BreakRigidJointCommand` | `joint_id`, `expected_assembly_revision` |
| `MergeAssembliesCommand` | `assembly_a_id`, `assembly_b_id`,
  `expected_revision_a`, `expected_revision_b`, A-side и B-side element/port |

Merge endpoints всегда относятся к Assembly A и B соответственно и не зависят
от будущего survivor. Relative transform не передаётся вызывающим кодом:
`SimulationWorld` выводит его из authoritative `assembly_a.grid_frame` и
`assembly_b.grid_frame`, затем после survivor selection применяет нужное
направление/inverse.

`get_assembly(id)` — canonical lookup с разрешением tombstone redirect.
`get_assembly_raw(id)` — точная запись, включая retired/tombstoned Assembly.

### Snapshot (version 1)

```gdscript
{
  "version": 1,
  "allocator": { next_element_id, next_assembly_id, next_joint_id, next_command_id },
  "archetypes": [ { archetype_id, resource_path, fingerprint } ],
  "assemblies": [ { assembly_id, topology_revision, grid_frame, element_ids,
    tombstoned, redirect_to } ],
  "elements": [ { element_id, assembly_id, archetype_id, origin_cell,
    orientation_index, build_progress, integrity, condition } ],
  "joints": [ { joint_id, assembly_id, kind, element_a_id, port_a_id,
    element_b_id, port_b_id } ],
  "redirects": [ { from_assembly_id, to_assembly_id } ],
}
```

Канонический порядок: sorted по id. Без `NodePath`, `RID`, `instance_id`.
Restore сначала валидирует definitions, IDs, membership, joints, redirects,
allocator bounds, transforms и runtime ranges во временном world; malformed
snapshot не мутирует текущий `SimulationWorld`. Дополнительно проверяются unique
occupancy, геометрия/совместимость каждого Rigid, настоящий anchor-tag port,
отсутствие duplicate joints и связность rigid graph каждой active Assembly.

## Identity

Три уровня идентичности:

| ID | Постоянство | Назначение |
|---|---|---|
| `ElementId` | persistent per runtime element | глобальная ссылка на элемент в SimulationWorld |
| `AssemblyId` | persistent per assembly | владеет элементами и joints |
| Body/projection id | transient | Jolt/presentation; пересоздаётся из snapshot |

Godot `NodePath`, `RID`, `instance_id` и scene node names **не** являются доменными
ссылками.

`BlueprintElementPlacement.local_id` — локальный authoring ID, уникальный только
внутри одного Blueprint. При каждом spawn `SimulationWorld` authority выделяет
новые globally unique persistent `ElementId` и записывает mapping
`local_id → ElementId`. Поэтому два spawn одного Blueprint не могут столкнуться
по runtime identity.

## Grid и ориентация

- Базовая сетка: **1 m** integer cells (`Vector3i`).
- Элемент занимает один или несколько cells (`footprint_cells` archetype).
- Допустимы **24** ортогональные ориентации куба (`orientation_index` 0–23).
- В baked Blueprint хранится только integer index, не float-матрица.
- Индекс `0` — точный `Basis.IDENTITY`.
- Стабильный порядок задаётся integer axes: local X перебирается
  `+X, -X, +Y, -Y, +Z, -Z`, local Y — `+Y, -Y, +X, -X, +Z, -Z` с пропуском
  неортогональных пар; local Z всегда `X × Y`. Все Basis right-handed,
  determinant `+1`.

Поворот применяется к:

- footprint cells относительно `origin_cell`;
- structural face direction (`OrientationUtil.Face`) и face slot портов.

## Connectivity (контракт v0)

Жёсткое ребро (`Rigid`) возникает только при совпадении **совместимых**
mechanical structural faces на соседних cells двух элементов. Совместимость
задаётся `PortDefinition.compatibility_tags` и face slot на archetype.

Validator проверяет unique port IDs, принадлежность `local_cell` footprint,
валидные face/slot/tags, compound collider coverage каждого footprint cell и
typed BOM (`resource_id`, positive `amount`). Production Blueprint по умолчанию
обязан образовать одну rigid connected component; schema-флаг
`allow_disconnected` должен быть включён явно для специальных fixtures.

`Anchor` крепит Assembly к миру; в v0 компилируются только `Rigid` и `Anchor`.
Остальные joint kinds допускаются как schema placeholders без поведения.

## Split / merge (контракт runtime)

При разрыве связности каждая компонента становится отдельной `Assembly`.
Survivor выбирается по правилу:

1. наличие `Anchor`;
2. больше элементов;
3. больше immutable dry mass;
4. для split: меньший `ElementId` внутри компоненты.

Для merge первые три критерия те же, финальный tie-break — меньший `AssemblyId`.
Loser получает
tombstone/redirect. При двух anchored Assembly Anchor проигравшей стороны
автоматически удаляется.

## Authoring workflow

`resources/archetypes/slice01/*.tres` — hand-authored committed source assets и
единственный источник истины для Slice-01 archetypes. Они не генерируются из
GDScript factory и не являются результатом bake.

Только Blueprint использует source/generated workflow:

```text
scenes/blueprint_authoring/*.tscn   (source, committed)
        |
        v
BlueprintBaker + BlueprintValidator
        |
        v
resources/blueprints/baked/*.tres   (deterministic output, committed)
```

- Runtime **никогда** не читает authoring nodes.
- Baked Blueprint `.tres` не редактируются вручную; изменения только через
  re-bake. Это правило не относится к archetype `.tres`, которые являются
  hand-authored source definitions.
- `BlueprintAuthoringRoot.blueprint_id` задаёт имя baked asset:
  `res://resources/blueprints/baked/{blueprint_id}.tres`.

## Typed definitions

| Resource | Путь | Назначение |
|---|---|---|
| `ElementArchetype` | `scripts/simulation/resources/element_archetype.gd` | immutable тип элемента |
| `PortDefinition` | `scripts/simulation/resources/port_definition.gd` | structural/network interface |
| `ColliderDefinition` | `scripts/simulation/resources/collider_definition.gd` | compound collider piece |
| `BuildRequirement` | `scripts/simulation/resources/build_requirement.gd` | typed BOM entry |
| `BlueprintElementPlacement` | `scripts/simulation/resources/blueprint_element_placement.gd` | один элемент в Blueprint |
| `Blueprint` | `scripts/simulation/resources/blueprint.gd` | sorted placements + metadata |

## Slice-01 archetypes (fixtures)

Минимальный набор для Phase 1:

- `foundation` — Anchor и structural mechanical ports;
- `frame`, `power_source`, `stationary_drill`, `cargo_store`, `processor`,
  `fabricator` — structural ports плюс минимальные functional ports;
- `frame_beam` — multi-cell fixture с collider piece на каждый footprint cell.

Функциональные Industry-роли остаются data/status stubs до Industry v1.

## Acceptance (Phase 1)

1. `docs/specs/SIMULATION-KERNEL-V0.md` и identity/topology в `PHYSICAL-LANGUAGE.md`.
2. Baker валидирует overlap, duplicate local IDs, orientation, collider/BOM/port
   schema и rigid connectivity.
3. Повторная выпечка даёт идентичный sorted Blueprint.
4. Multi-cell footprint корректно вращается всеми 24 ориентациями.
5. `scenes/test_simulation_kernel.tscn` печатает `KERNEL-V0: PASS`.
6. Существующие PoC/Player тесты остаются зелёными.

## Headless test

```bash
./run.sh --headless res://scenes/test_simulation_kernel.tscn
```

Критерий: stdout содержит `KERNEL-V0: PASS`, exit 0.

## Acceptance (Phase 2)

1. `SimulationWorld` владеет typed runtime state и authority allocator.
2. Повторный spawn одного Blueprint даёт disjoint `ElementId` / `AssemblyId`.
3. `break_rigid_joint` и `merge_assemblies` применяют survivor policy и revision checks.
4. Snapshot roundtrip семантически эквивалентен; allocator продолжает выдачу id.
5. `scenes/test_simulation_runtime.tscn` печатает `KERNEL-RUNTIME-V0: PASS`.

## Headless test (Phase 2)

```bash
./run.sh --headless res://scenes/test_simulation_runtime.tscn
```

Критерий: stdout содержит `KERNEL-RUNTIME-V0: PASS`, exit 0.
