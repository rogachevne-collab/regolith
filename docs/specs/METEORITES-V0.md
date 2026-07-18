# Meteorites v0

Статус: world ambience / environment event на `main` (planetoid).

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` («Метеориты v0», «Граница владения», Impact);
- `docs/specs/IMPACT-DESTRUCTION-V0.md` (terrain carve path);
- `docs/specs/MOON-EXPERIMENT-V0.md`;
- `docs/cheatsheets/voxel-tools.md`.

## Цель

Изредка на луну падают метеориты: видимое тело с неба → удар о voxel terrain →
кратер через мировую операцию `terrain_carve` + impact VFX. Процесс настраивается
в инспекторе (`MeteoriteSystem`). Debug-кнопка / hotkey устраивает удар рядом с
игроком для проверки.

## Граница владения

```text
MeteoriteSystem (scheduler + spawn)
        |
        v
RigidBody3D meteor (Jolt dynamics + Area3D gravity)
        |
        v  first terrain contact
WorldCommandGateway.apply_terrain_carve (sphere stamp)
        +
kinetic_impact_burst VFX
```

- Планировщик и презентация метеорита — presentation/world ambience.
- Terrain мутируется **только** через `WorldCommandGateway` / excavation
  (как бур и impact), не прямой записью SDF.
- Метеорит **не** Assembly и не проходит через `ImpactResolverService`
  (нет `element_id`); это environment event с прямым carve.
- Material yield: как kinetic impact — грунт исчезает (лут нет в v0).

## Настройки (`MeteoriteSystem` @export)

| Параметр | Назначение | Старт |
|---|---|---|
| `enabled` | периодические падения | `true` |
| `min_interval_s` / `max_interval_s` | случайный интервал между падениями | 180 / 480 |
| `spawn_offset_min_m` / `spawn_offset_max_m` | горизонтальный offset от игрока (tangent) | 40 / 120 |
| `spawn_height_m` | высота спавна над поверхностью вдоль local up | 140 |
| `impact_speed_m_s` | начальная скорость к грунту | 55 |
| `meteor_radius_m` | визуал + collider | 1.2 |
| `meteor_mass_kg` | масса RigidBody | 600 |
| `crater_radius_m` | радиус sphere carve | 3.2 |
| `crater_sdf_scale` | глубина SDF stamp (0..1) | 1.0 |
| `volume_budget_m3` | бюджет carve за удар | 80 |
| `max_active` | одновременно в полёте | 1 |
| `lifetime_s` | safety timeout без контакта | 25 |
| `damage_player` | урон SuitState при попадании в игрока | `true` |
| `show_debug_button` | UI-кнопка на CanvasLayer | `true` |
| `debug_spawn_enabled` | hotkey / кнопка / console | `true` |
| `debug_offset_m` | offset от игрока для debug-удара (вперёд по камере) | 18 |
| `debug_spawn_height_m` | высота debug-спавна над поверхностью | 48 |

Интервалы и радиусы — tunable в инспекторе на `Main/MeteoriteSystem`; не magic
в других скриптах.

## Lifecycle

1. Ждать `bootstrap.is_world_ready()`.
2. Если `enabled` — накопить случайный интервал `[min, max]`.
3. Спавн: точка у игрока + tangent offset → local up × `spawn_height_m`;
   `linear_velocity = −up · impact_speed_m_s`.
4. Первый контакт с terrain / world surface → один carve + VFX → `queue_free`.
5. Контакт с игроком (опционально) → `SuitState.apply_damage` → затем тоже
   разрушение метеорита (без второго carve, если уже ударил terrain).

## Debug

- Input action `debug_spawn_meteor` (F9) → `debug_spawn_near_player()`.
  Не F8: в редакторе Godot F8 = Stop Running Scene.
- Кнопка «Метеорит (F9)» на `CanvasLayer` (если `show_debug_button`).
- LimboConsole: `meteor` → тот же путь.

Debug-удар всегда рядом с игроком (`debug_offset_m`), независимо от
`enabled` / интервала (при `debug_spawn_enabled`).

## Вне скоупа v0

- Урон Assembly / элементы через ImpactResolver;
- цепочка осколков с физикой debris;
- loot из кратера;
- орбитальная баллистика / атмосферный вход;
- headless-тест (геймплей — проверка в main, R2).

## Файлы

| Роль | Путь |
|---|---|
| Система | `scripts/meteorite_system.gd` |
| Сцена | `scenes/main.tscn` → `MeteoriteSystem` |
| VFX | `scenes/vfx/kinetic_impact_burst.tscn` |
| Carve | `scripts/world_command_gateway.gd` |
| Input | `project.godot` → `debug_spawn_meteor` |
