# Bootstrap — куда смотреть

`scripts/bootstrap.gd` — корневая сцена `scenes/main.tscn`: voxel terrain,
persistence, spawn/settle (R5), streaming, demo-spawn, coop terrain bulk,
perf overlay.

## Монолит vs сервисы

| Слой | Файл | Что лежит |
|---|---|---|
| узел | `scripts/bootstrap.gd` | `@export` / `@onready` / state vars, `_ready` / `_process` / `_physics_process`, perf overlay (~120 строк), override-хуки, публичный coop API (тонкие обёртки), signal connects |
| persistence | `scripts/bootstrap/bootstrap_persistence_service.gd` | dig stream, autosave, terrain-modified handlers, coop terrain bulk |
| terrain | `scripts/bootstrap/bootstrap_terrain_setup_service.gd` | planet shell config, streaming budget, far impostor, boulder instancer |
| demo | `scripts/bootstrap/bootstrap_demo_spawn_service.gd` | demo rover/hopper, lamp poles, debug rover spawn |
| spawn | `scripts/bootstrap/bootstrap_spawn_settle_service.gd` | world entry, spawn/settle (R5), landing pad |

Паттерн сервиса: `class_name … extends RefCounted`, только `static func`, первый
аргумент нетипизированный `bootstrap` (без цикла `class_name`). Значения с
`bootstrap` / его полей — **явный тип**, не `:=`.

## Override-хуки (остаются на узле)

| Метод | Почему |
|---|---|
| `_make_planet_generator()` | `bench_park_freeze.gd`, `test_moon_5km_flat_bootstrap.gd` extends override |
| `_configure_boulder_instancer()` | bench extends может переопределять |

## Публичный API (тонкие обёртки на узле)

| Метод | сервис |
|---|---|
| `is_world_ready()` | поле `_world_ready` на узле |
| `set_coop_persistence_inhibited` | поле `_coop_persistence_inhibited` |
| `save_now_then_inhibit_persistence` | `BootstrapPersistenceService` |
| `flush_digs_for_coop_join` | `BootstrapPersistenceService` |
| `capture_coop_terrain_bulk` | `BootstrapPersistenceService` |
| `apply_coop_terrain_bulk` | `BootstrapPersistenceService` |
| `reseat_player_near` | `BootstrapSpawnSettleService` |

## R5 spawn order (`_ready`)

```
auto_accept_quit / save_path / loading UI
→ terrain setup          # BootstrapTerrainSetupService
→ dig stream             # BootstrapPersistenceService
→ boulder instancer      # BootstrapTerrainSetupService (via node hook)
→ far impostor           # BootstrapTerrainSetupService
→ archetype registry
→ gateway signal connects
→ spawn hint + MoonMaterialField
→ player lock + hold point
→ _place_when_ground_exists()   # BootstrapSpawnSettleService
```

## Что остаётся в монолите

| Блок | Почему |
|---|---|
| Perf overlay (~120 строк) | debug-only, изолирован |
| `_ready` / `_process` / `_physics_process` | orchestration |
| `@export` / `@onready` / state vars | subclass/bench access contract |
| `_make_planet_generator` hook | bench extends |

## Верификация

```powershell
# coop contract (commit 1 / 4)
& "C:\Program Files\Git\bin\bash.exe" ./tests/run_one.sh test_coop_bug_regressions

# headless smoke (~45s, world_ready)
& "C:\Program Files\Git\bin\bash.exe" ./run.sh --headless res://scenes/main.tscn
```

## Line counts (после волны)

| Файл | строк |
|---|---:|
| `bootstrap.gd` | 805 |
| `bootstrap_persistence_service.gd` | 245 |
| `bootstrap_terrain_setup_service.gd` | 306 |
| `bootstrap_demo_spawn_service.gd` | 327 |
| `bootstrap_spawn_settle_service.gd` | 569 |
