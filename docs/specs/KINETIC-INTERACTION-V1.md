# Kinetic Interaction v1

Статус: PoC-расширение Impact Destruction v0. Tier 1 (единый импульс + устойчивое
усилие актуатора). Продолжение (carve-бюджет, grind, VFX, лут, Tier 2
давление/yield, урон игроку) — `KINETIC-INTERACTION-V2.md`.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` («Граница владения», «Кинетический удар»);
- `docs/specs/IMPACT-DESTRUCTION-V0.md` — базовый контракт удара;
- `docs/specs/POC-ACTUATORS-V1.md` — piston / motor / overload;
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/CONSTRUCTION-V1.md`.

## Цель

Единая, предсказуемая кинетическая система: **любой** достаточно сильный контакт
динамической части конструкции с миром или другой конструкцией даёт `damage` и/или
`terrain_carve`, независимо от того, откуда взялось усилие — падение, таран или
**упор приводимого актуатора** (пистон, бур на пистоне).

v0 уже покрывает падение целой `Assembly`. v1 закрывает три разрыва:

- **carriage пистона** (голова + приваренная ветвь) не участвовал в impact —
  голова упиралась в грунт без carve и damage;
- **устойчивое усилие** актуатора (медленный мощный упор, `v ≈ 0`) не давало
  никакой реакции — только collision impulse;
- **бур на пистоне** резко опускался на грунт и не пробивал — тот же carriage-gap
  плюс stationary drill работал отдельным industry-tick, не кинетикой.

Это не FEM и не материаловедение. Это единый скаляр `J` (Н·с) на контакт и
монотонная реакция от него, как в v0.

## Дизайн-принцип: разрушение — это фича

Reckless-поведение **наказывается и не смягчается искусственно** (сознательный
выбор, как в Space Engineers):

- пистон + бур на скорости в грунт → carve + damage → возможен lethal → split →
  падающий фрагмент бьёт базу (уже **другая** assembly) → каскад;
- sustained-упор долбит грунт и ломает **свой** drill/head, пока актуатор давит;
- `speed_limit_mps` игрока **без искусственного потолка** в v1.

**Не входит в v1** (против design intent): safe-speed порог, clamp скорости,
неприкосновенность базы, ослабляющие коэффициенты sustained.

Единственная защита — **subgrid immunity**: контакты внутри **одного**
`body_group` одной assembly не наносят damage/carve (один physics body /
внутренности группы). Контакты **разных body groups** одной assembly
(rotor/piston base ↔ top, стрела ↔ корпус) бьют на общих правах — как
subgrid collision в Space Engineers. Отвалившийся после split фрагмент —
уже другая assembly и бьёт на общих правах.

## Граница владения

```text
Jolt contact snapshot (impulse|velocity, point, normal, collider)
Actuator tick (applied_force_n, contact probe)
        |
        v
ImpactResolver / KineticSource (physics boundary, read-only)
        |
        +-- terrain partner --> terrain_carve (voxel-edit op)
        |
        +-- assembly partner --> DamageElementCommand (×2)
        |
        v
SimulationWorld (integrity) + VoxelTerrain (SDF)
```

- Jolt авторитетен за импульс и геометрию контакта.
- Actuator-канал авторитетен только за `applied_force_n` (уже вычислен в motor
  tick); он **не** пишет transform, velocity или voxel напрямую.
- `SimulationWorld` авторитетен за `integrity` — только через `DamageElementCommand`.
- Terrain мутируется общей операцией `voxel_edit` (как бур и v0 carve), не прямой
  записью из solver.
- Presentation не владеет ни damage, ни carve.

## Единый масштаб силы

Константы v0 сохраняются без смены баланса
(`scripts/simulation/runtime/impact_resolver.gd`):

| Константа | Назначение | Значение |
|---|---|---|
| `I_MIN` | минимальный импульс для любой реакции | 4.0 Н·с |
| `I_REF` | импульс «типичного» заметного удара | 24.0 Н·с |
| `K_DAMAGE` | коэффициент урона | 0.35 |
| `V_MAX_M3` | бюджет carve на assembly за кадр | 2.0 м³ |

Три источника `J`, объединяются максимумом (не усредняются — Jolt-импульс неточен
при множественных контактах, поэтому берём сильнейшую оценку):

```text
J_collision  = |get_contact_impulse()|          // приоритет, из _integrate_forces
J_fallback   = m_eff · |v_rel · n|               // если impulse недоступен / carriage
J_sustained  = applied_force_n · Δt_physics      // актуатор упёрся

J_effective  = max(J_collision, J_fallback, J_sustained)
```

`m_eff` — приведённая масса пары: `m1·m2/(m1+m2)`; для terrain `m2 → ∞`, значит
`m_eff ≈ m1`. `n` — нормаль контакта; `v_rel · n` — скорость сближения вдоль
нормали (аналог separating velocity в SE).

**Урон элемента** (на одну сторону контакта, как v0):

```text
strength = clamp(J_effective / I_REF, 0.0, 1.0)   // 0 при J < I_MIN
damage   = strength² · max_integrity · K_DAMAGE
```

**Terrain carve** (только partner = `VoxelTerrain`, как v0): `strength` →
`sdf_strength`; бюджет `V_MAX_M3`, cooldown на пару. Форма стампа:

- **`mesh` (carve v2, приоритет)** — box-коллайдер ударника штампуется
  `VoxelTool.do_mesh` с его **мировой ориентацией**: единичный куб один раз
  запекается в `VoxelMeshSDF` (`TerrainImpactCarver.unit_box_mesh_sdf`),
  transform = базис коллайдера × размер шейпы; центр — грань «целует» contact
  point и утапливается на bite depth вдоль carve direction. Куб, упавший под
  углом, выгрызает наклонный отпечаток, а не вертикальную квадратную яму.
  `do_mesh` доступен на `VoxelToolTerrain` с Voxel Tools 1.5; transform
  передаётся в excavation **в terrain-local** (контракт `do_mesh_chunked`).
- **`sphere` / `path`** — fallback (не-box шейпа, неудачный bake) и прежние
  каналы (sustained grind, hand drill).

## Actuator sustained channel

Новый источник `J_sustained` для приводимых актуаторов (пистон в v1).

В piston actuator tick (`simulation_physics_projection.gd:_tick_piston_actuators`),
после расчёта `applied_force_n` и `force_saturated`:

- если элемент(ы) головы/carriage в контакте с terrain (contact probe по element_id,
  как у stationary drill) **и** `applied_force_n > 0`:
  - `J_sustained = applied_force_n · Δt`;
  - эмитить entry в тот же batch `ImpactResolver` с `striker_element_id` = элемент
    на carriage в контакте (drill / frame / head), `partner = terrain`.

**Окно carve = фаза насыщения до overload.** При достижении `OVERLOADED`
(`OVERLOAD_SATURATION_S ≈ 0.5 с` насыщения) мотор переходит в STOP и
`applied_force_n → 0` (`compute_motor_force_scalar` возвращает 0 в статусе
`OVERLOADED`). Значит `J_sustained` естественно затихает: пистон «поднажал, вырыл
немного, сдался». v1 **не** держит reference-force и **не** продолжает carve после
overload — это честно к текущей физике мотора.

Sustained эмитится только пока `applied_force_n > 0` и есть контакт (т.е. в
saturation-окне, до перехода в STOP).

## Impact bodies: custom integrator ЗАПРЕЩЁН

Семантика встроенного Jolt-модуля Godot 4.5 (проверено по
`modules/jolt_physics/objects/jolt_body_3d.cpp` и `scene/3d/physics/rigid_body_3d.cpp`):

- при `custom_integrator = true` Jolt **молча дропает**
  `apply_force` / `apply_central_force` / `apply_torque` (early-return) и не
  интегрирует гравитацию/демпфирование — ломаются пистон, реакция базы и
  колёсные силы ровера;
- виртуальный `_integrate_forces` вызывается **всегда** (state-sync callback),
  независимо от `custom_integrator`;
- контактные импульсы Jolt — оценка `EstimateCollisionResponse` во время шага:
  доступны уже в **первый** кадр контакта, но приблизительны при множественных
  контактах/joint (потому J объединяется максимумом с fallback);
- `state.integrate_forces()` внутри callback при `custom_integrator = false`
  добавляет гравитацию **второй раз** — вызывать нельзя.

Поэтому impact-конфигурация (`ImpactResolverService.configure_impact_body`)
никогда не включает `custom_integrator`; оба режима ставят `contact_monitor`,
`max_contacts_reported`, `continuous_cd`:

| Режим | Источник J | Кому |
|---|---|---|
| `FULL` | contact impulse из `_integrate_forces` (оценка Jolt) ∨ `J_fallback` | динамические assembly, роверы, группы пистона |
| `MONITOR_ONLY` | `J_fallback` (`body_shape_entered`) и `J_sustained` | carriage пистона |

**Скорости для `J_fallback`.** К моменту `body_shape_entered` столкновение уже
разрешено — `linear_velocity` погашена (известная грабля Godot). Сервис кэширует
pre-step скорости отслеживаемых тел в `_physics_process`; в `_integrate_forces`
используется `get_contact_local_velocity_at_position` (pre-solve скорость из
Jolt contact listener).

## Классификация партнёра

| Partner | Действие |
|---|---|
| `VoxelTerrain` / `StaticBody3D` без `assembly_id` (world surface) | carve + damage ударяющего `element_id` |
| Другой `PhysicsBody3D` с `assembly_id` meta (**иной** assembly) | damage обоим `element_id` (каждая сторона эмитит свой entry) |
| Тот же `assembly_id` и тот же `body_group_id` | **игнор** (subgrid immunity) |
| Тот же driven joint: hub endpoints (`base`↔`top`/`head`) | **игнор** (стык шарнира) |
| Тот же `assembly_id`, **другой** `body_group_id` (иначе) | damage (стрела↔корпус и т.п.) |
| Игрок (`CharacterBody3D`) / rigid-пропсы без `assembly_id` / прочие тела | игнор в v1 |

`StaticBody3D` anchored assembly не источник удара (frozen, без integrate) — v0.

## Бур на пистоне

Элемент `stationary_drill`, приваренный к carriage, получает **кинетические**
entries от carriage-контактов независимо от `machine_enabled` (slam режет грунт
даже у выключенного бура). Industry-tick (`stationary_drill_service`) добавляет
штатную добычу `raw_regolith`, **когда** бур включён, запитан и в контакте — это
отдельный операционный канал, он **не** блокирует кинетику и не дублирует её carve.

## Материал грунта

| Фаза | Поведение |
|---|---|
| **v1** | Кинетически вырезанный regolith **исчезает** (как v0 impact и `voxel_remove`). Inventory не меняется. Лут — только hand/stationary drill. |
| **позже** | Yield при `J ≥ I_LOOT` — см. `KINETIC-INTERACTION-V2.md` (V2-4). |

## Команды и доставка

Без новых типов команд относительно v0:

- **Structural:** `DamageElementCommand` — единственный путь снижения `integrity`.
- **World:** `terrain_carve` op через `WorldCommandGateway` (как v0). Actuator- и
  carriage-источники эмитят те же entry в batch `ImpactResolver`; один flush в
  `call_deferred` после шага физики, cooldown на пару.

## Player-visible поведение

- Пистон с буром вниз на грунт: быстрый ход → кратер + damage головы (slam);
  медленный мощный упор → эрозия за ~0.5 с до overload, затем мотор стопается.
- Пистон в стену базы: оба элемента получают damage; при lethal — split/удаление
  по правилам Construction v1.
- Падающий frame — как v0 (не регрессировать).
- Base ↔ head одной сборки — без self-damage.
- Слабое касание / качение ниже `I_MIN` — тишина.
- Resting на terrain: `get_contact_impulse` ≈ m·g·Δt **не** считается ударом;
  terrain-реакция из `_integrate_forces` требует ещё `J_fallback ≥ I_MIN` и
  `|v_rel · n| ≥ V_SEP_MIN` (иначе тяжёлые assembly копают шахту сидя).
- Каскад: lethal drill → split → падающий обломок бьёт базу как чужая assembly.

## Модули (целевая раскладка)

| Модуль | Роль в v1 |
|---|---|
| `scripts/simulation/runtime/impact_resolver.gd` | формулы `J`, `strength`, `damage`; subgrid-фильтр; классификация партнёров; shape index ↔ element |
| `scripts/simulation/runtime/impact_resolver_service.gd` | `configure_impact_body` (без custom integrator); pre-step velocity cache; `J_fallback` в `body_shape_entered` и `_integrate_forces`; batch/cooldown (merge по max J) |
| `scripts/simulation/projection/simulation_physics_projection.gd` | carriage → `MONITOR_ONLY`; actuator sustained emit в `_tick_piston_actuators` |
| `scripts/simulation/runtime/terrain_impact_carver.gd` | форма carve (как v0) |
| `scripts/world_command_gateway.gd` | `terrain_carve` доставка (как v0) |

## Acceptance

1. Carriage пистона slam в грунт: carve под контактом + `integrity` головы падает
   при `J ≥ I_MIN`.
2. Пистон saturated, `v ≈ 0`, упёрся в грунт: carve/damage в окне насыщения,
   монотонно с `applied_force_n`; при `OVERLOADED` мотор STOP, `F → 0`, carve
   затихает.
3. Бур на пистоне slam при выключенном моторе бура: кинетический carve есть;
   включённый бур добавляет industry-добычу.
4. Assembly ↔ assembly (разные): оба `element_id` получают damage; terrain не
   меняется.
5. Base ↔ head одной assembly: нет self-damage/carve.
6. Падение frame (регрессия v0): carve + integrity, без изменения поведения.
7. Слабое касание ниже `I_MIN`: без carve и damage.
8. Каскад: пистон+бур на макс. → drill lethal → split → обломок в базу наносит
   full kinetic damage.
9. Headless: `test_impact_destruction` расширен (piston slam, slow saturated push,
   регрессия fall); зелёный в `tests/run_tests.sh`.
10. Playground `scenes/test_kinetic_playground.tscn`: 5 стендов, проверка в игре.

## Верификация

- **Ядро** (формулы `J`, subgrid-фильтр, sustained окно): headless
  `./tests/run_one.sh test_impact_destruction`.
- **Геймплей / carriage / carve при scale 0.65** (R2, R7, R8): запущенная игра
  через playground — Beckett `play_scene` → `screenshot`, `game_logs`. Человек
  подтверждает feel. «Тест зелёный» не доказывает, что пистон реально режет грунт.

## Не входит в v1

- Tier 2: давление `P = F/A_contact`, yield regolith/элементов, глубина от энергии;
- safe-speed порог, clamp скорости, ослабление sustained — против design intent;
- ~~`do_mesh` collider-stamp~~ — реализовано (carve v2, см. «Terrain carve»);
- loot от кинетики, debris-тела грунта, урон игроку;
- миграция пистона на joint linear motor вместо `apply_central_force`;
- FEM, усталость, fracture-меши в стиле SE2.
