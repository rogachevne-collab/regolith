# Game Balance v0

Статус: authoritative edit surface для экономики и тюнинга сущностей Regolith.

## Цель

Один файл задаёт калибруемые числа игры: стоимость/массу блоков, item catalog,
рецепты, буры, электрику, refund/weld economy, стартовый cargo и motor-тюнинг
актуаторов. Геометрия, порты и structural identity остаются в
`resources/archetypes/slice01/*.tres`.

## Файл

```text
res://resources/balance/game_balance.json
```

Загрузчик: `scripts/simulation/balance/game_balance.gd` (`GameBalance`).

Шпаргалка: `docs/cheatsheets/game-balance.md`.

## Владение

| Слой | Где править | Что |
|---|---|---|
| Balance numbers | `game_balance.json` | mass, BOM, actuator motor limits, items, recipes, drill, power, economy |
| Structural identity | `resources/archetypes/slice01/*.tres` | footprint, ports, colliders, roles, head/top archetype ids, axes |
| Presentation | scenes / tool scripts | визуалы, toolbar layout, spin VFX |

Инвариант: **balance JSON побеждает** совпадающие поля archetype `.tres` при
load/register (`GameBalance.apply_element`). Менять mass/BOM/force поршня в
`.tres` без правки JSON бесполезно — значение перезапишется.

## Схема (version = 1)

```text
GameBalance {
  version                     # 1
  items{item_id → ItemType}
  recipes{recipe_id → Recipe}
  industry{…}                 # capacities, stationary/hand drill
  electric{defaults, archetypes}
  construction{…}             # weld/dismantle/grinder/block-drill economy
  starter{…}                  # fresh-world + playtest cargo
  elements{archetype_id → ElementBalance}
}

ElementBalance {
  mass_kg
  max_integrity?              # только если ≠ дефолта archetype
  build_requirements[]        # {resource_id, amount}
  piston? | rotor? | hinge? | wheel? | suspension? | thruster? | gyro?
}
```

Актуator-оверлеи содержат только **motor/tuning** поля (force, velocity, torque,
damping, power_draw, travel…). Structural fields (`head_archetype_id`,
`axis_face`, socket tags, nozzle offset) остаются в archetype `.tres`.

## Runtime

1. Catalogs (`ResourceCatalog`, `RecipeCatalog`, `IndustryArchetypeProfile`,
   `IndustryElectricProfile`) читают JSON через `GameBalance`.
2. `Slice01Archetypes.load_required` и `ArchetypeRegistry.register` вызывают
   `GameBalance.apply_element` (idempotent per archetype_id).
3. `GameBalance.validate()` проверяет cross-refs (BOM/recipe → items, mass > 0).

## Совместимость

- Команды и snapshot schema не меняются.
- Fingerprint archetype считается **после** apply — изменение balance numbers,
  входящих в fingerprint (mass, BOM, actuator defs), меняет save fingerprint
  так же, как правка `.tres` раньше.
- INDUSTRY-V1 ItemCatalog / capacities остаются контрактом; значения v1 fixtures
  переехали в JSON без смены item_id / recipe_id.

## Вне scope v0

- Editor UI / inspector dock для balance.
- Автогенерация JSON из `.tres`.
- Per-save balance overrides.
- Presentation-only константы (VFX spin, HUD tokens), кроме block-drill/grinder
  DPS, которые уже были gameplay economy.
