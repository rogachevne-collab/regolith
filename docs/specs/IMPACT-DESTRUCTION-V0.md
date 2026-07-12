# Impact Destruction v0

Статус: PoC после Construction v1.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/PLAYER-INTERACTION-V1.md`.

## Цель

Кинетический удар динамической `Assembly` разрушает **и ударник, и цель**:

- удар о **voxel terrain** вырезает грунт по форме контакта; объём зависит от
  импульса, не от дискретной «клетки за удар»;
- удар **assembly ↔ assembly** наносит `damage` обоим элементам по импульсу
  контакта; terrain не меняется.

Механика не срабатывает при расширении базы (`place`, weld, snap) и не заменяет
ручной бур. Anchored `StaticBody3D` сама не падает — удар возможен только у
`RigidBody3D` компонент (split, потеря anchor, фрагмент, ровер).

## Граница владения

```text
Jolt contact snapshot (impulse, point, normal, collider)
        |
        v
ImpactResolver (physics boundary, read-only)
        |
        +-- terrain partner --> TerrainCarveOp (voxel-edit)
        |
        +-- assembly partner --> DamageElementCommand (×2)
        |
        v
SimulationWorld + VoxelTerrain
```

- Jolt авторитетен за импульс и геометрию контакта.
- `SimulationWorld` авторитетен за `integrity` — только через `DamageElementCommand`.
- Terrain мутируется **операцией** `voxel_edit` (как бур и `voxel_remove`), не
  прямой записью из solver.
- Presentation не владеет ни damage, ни carve.

## Триггер

`ImpactResolver` подключается к projected `RigidBody3D` (`ProjectedAssemblyBody`,
mounted bodies). На каждый physics frame:

1. `contact_monitor = true`, `max_contacts_reported >= 8`.
2. В `_integrate_forces(state)` или `body_state_changed` собрать контакты.
3. Отфильтровать пары с `impulse_length >= I_min` (порог отсекает трение/мелкие
   касания).
4. Аккумулировать импульс по `(body, partner, element_id, collider_index)` за
   кадр; один batch apply в `call_deferred` после шага физики.
5. Cooldown `τ_cooldown` (≈ 0.05–0.1 с) на пару collider↔partner, чтобы не
   дублировать один удар на sub-steps.

Партнёр классифицируется:

| Partner | Действие |
|---|---|
| `VoxelTerrain` | carve + damage ударяющего `element_id` |
| Другой `PhysicsBody3D` с `assembly_id` meta | damage обоим `element_id` |
| Игрок / прочие тела | игнор в v0 |

`StaticBody3D` anchored assembly — не источник удара в v0 (frozen, без integrate).

## Масштаб от силы

Единая опорная величина на контакт:

```text
J = |impulse|   // Н·с, из PhysicsDirectBodyState3D
E = J² / (2 · m_eff)   // Дж, m_eff = mass участника удара
```

Пороги (tunable constants, не magic в коде):

| Константа | Назначение | Стартовое значение |
|---|---|---|
| `I_min` | минимальный импульс для любой реакции | 4.0 Н·с |
| `I_ref` | импульс «типичного» заметного удара | 24.0 Н·с |
| `E_ref` | энергия для lethal damage лёгкого frame | archetype-specific |

**Урон элемента** (на одну сторону контакта):

```text
strength = clamp(J / I_ref, 0.0, 1.0)
damage = strength² · max_integrity · k_damage
```

`k_damage` ≈ 0.35 для v0 (сильный удар ≈ треть max_integrity; очень сильный —
lethal через существующий путь `DamageElementCommand`). Lethal damage, split и
survivor policy — без изменений Construction v1.

Для assembly ↔ assembly обе стороны получают независимый `damage` от своего
`J` (импульс на этом теле; в идеале близки по модулю, но не усредняются).

## Terrain carve

Только при partner = `VoxelTerrain`. Carve **не** плоский footprint placement.

Приоритет формы (от точного к дешёвому):

1. **`do_mesh`** — SDF collider shape ударяющего элемента в world transform
   контакта; `isolevel` и `sdf_strength` от силы.
2. **`do_path`** — полилиния contact points с `radii[i] = r_base · strength`.
3. **`do_sphere`** — fallback на contact point.

Непрерывность от силы:

```text
strength = clamp(J / I_ref, 0.0, 1.0)
voxel_tool.sdf_strength = strength
voxel_tool.mode = MODE_REMOVE
```

Слабый удар — мягкое вдавливание SDF; сильный — полное удаление. Скольжение с
достаточным `J` оставляет борозду (несколько кадров `do_path`), а не один щелчок.

Глубина/объём не дискретны: один physics frame может дать `strength < 1`;
повторные контакты накапливают эрозию.

Бюджет: не более `V_max` м³ carve на assembly за кадр (v0: 2.0 м³); избыток
обрезается по убыванию `J`.

## Материал грунта

| Фаза | Поведение |
|---|---|
| **v0** | Вырезанный regolith **исчезает** (как бур и `voxel_remove`). Inventory не
  меняется. |
| **v1 (Industry)** | Опционально: при `J >= I_loot` и наличии cargo-порта поблизости
  начислять `raw_regolith` пропорционально `excavated_volume · η`. Отдельная
  спека; v0 не блокирует. |

Debris-физика (RigidBody куски грунта) — вне scope v0.

## Команды и доставка

### Structural (существующие)

`DamageElementCommand` — единственный путь уменьшения `integrity` от удара.
Batch resolver эмитит команды через `SimulationWorld.apply_structural_command_now`
или очередь gateway с `source = impact_resolver`.

### World (новые операции, не structural)

`TerrainCarveOp` — сериализуемая voxel-edit операция:

```text
TerrainCarveOp {
  kind: "terrain_carve"
  stamp_kind: mesh | path | sphere
  transform: Transform3D
  strength: float
  mesh_sdf_ref?: String   // для stamp_kind = mesh
  points?: PackedVector3Array
  radii?: PackedFloat32Array
}
```

Доставка: `WorldCommandGateway.submit` (рядом с `voxel_remove`). Для single-player
допустим прямой вызов carver из deferred batch; для коопа — журнал `voxel_edit`.

## Идентификация элементов

Источник `element_id` — meta на `CollisionShape3D` из
`SimulationPhysicsProjection` (уже есть). Resolver читает meta с обеих сторон
assembly ↔ assembly. Если meta отсутствует — контакт игнорируется (диагностика
`impact/no_element_id`).

## Player-visible поведение

- Падающий отвалившийся `frame` после split оставляет кратер формы угла/грани и
  получает `damaged` или исчезает при lethal.
- Удар балки о стену базы повреждает оба элемента; anchored часть остаётся, если
  не разорвана topology.
- Слабое касание при качении — без carve и без damage.
- Ручной бур и placement не меняются.

## Модули (целевая раскладка)

| Модуль | Роль |
|---|---|
| `scripts/simulation/runtime/impact_resolver.gd` | сбор контактов, batch, cooldown |
| `scripts/simulation/runtime/terrain_impact_carver.gd` | collider → VoxelTool op |
| `scripts/world_command_gateway.gd` | `terrain_carve` kind |
| `scripts/simulation/projection/projected_assembly_body.gd` | hook integrate / monitor |

## Acceptance

1. Dynamic assembly с `apply_central_impulse` вниз на terrain: SDF под контактом
   уменьшается; `integrity` ударяющего элемента падает.
2. Сила carve и damage монотонно растут с `J` (слабый < сильный).
3. Форма кратера коррелирует с ориентацией box-collider (не axis-aligned куб
   фиксированного размера).
4. Assembly ↔ assembly: оба `element_id` получают `damage`; terrain не меняется.
5. Anchored static assembly не генерирует impact events.
6. `place` / preview / `_seat_ground_plan` не вызывают carve.
7. Headless-тест `scenes/test_impact_destruction.tscn` + строка в
   `tests/run_tests.sh`.

## Не входит

- FEM, fatigue graph, усталость от повторных ударов;
- debris-тела из грунта;
- начисление `raw_regolith` в store (v1 Industry);
- урон игроку от удара конструкции;
- impact VFX/SFX и финальный баланс;
- копание при строительстве и «площадка под footprint».
