# Анти-godobject — контракт заморозки

Механическая нарезка монолитов на сервисы **без изменения поведения**.
Любой behavioral fix — отдельный тикет **после** зелёного прогона волны.

## 1. Правило волн

| | |
|---|---|
| Волна | Набор механических extract'ов |
| Разрешено | Перенос кода, тонкие обёртки на монолите, новые `class_name` сервисы |
| Запрещено | «Заодно чинить» поведение, рефакторить логику, менять порядок side-effects |
| Behavioral change | Отдельный тикет, только после зелёного прогона волны |

## 2. Замороженные поверхности

### Gateway `kind` (`scripts/world_command_gateway.gd` → `_execute`)

Строки `kind` в `match` — не добавлять/не переименовывать/не менять семантику в волне:

| kind |
|---|
| `voxel_remove` |
| `dig_terrain_debris` |
| `scoop_spoil` |
| `dump_scoop` |
| `debug_spawn_spoil` |
| `damage_element` |
| `place_block` |
| `toggle_control_seat` |
| `construction_apply` |
| `weld_element` |
| `dismantle_element` |
| `transfer_resource` |
| `assign_hotbar_instance` |
| `connect_network` |
| `disconnect_network` |
| `set_machine_enabled` |
| `oxygen_refill` |
| `set_element_name` |
| `enqueue_recipe` |
| `dequeue_recipe` |
| `collect_world_loot` |
| `set_actuator_target` |
| `configure_actuator` |
| `configure_wheel` |
| `configure_suspension` |
| `configure_action_slot` |
| `configure_seat_controls` |

Неизвестный `kind` → `_result(&"invalid_target")`.

### Result-словарь (`_result`)

```
{ "status": &"ok" | &"failed", "reason": StringName, "data": Dictionary }
```

`status == &"ok"` только при `reason == &"ok"`. Поля и семантика `reason` заморожены.

### Physics projection — публичный API

`scripts/simulation/projection/simulation_physics_projection.gd` — сигнатуры и смысл:

| Метод |
|---|
| `sync_body_motion_now` |
| `align_body_motion` |
| `wake_assembly_bodies` |
| `wake_frozen_near` |
| `is_rope_frozen` |
| `rope_path` |
| `get_last_tick_breakdown_us` |
| `rebuild_all` |

Также заморожены: **порядок structural events** и решение **incremental append vs full reproject**.

### SimulationWorld

`scripts/simulation/simulation_world.gd` — **вне скоупа операции полностью**. Не трогать.

### R5 (spawn)

SDF → physics collider → settle → телепорт игрока. См. **R5** в `AGENTS.md` /
[`docs/cheatsheets/bootstrap.md`](../cheatsheets/bootstrap.md).

### Coop

Заморожены: `replay_remote_dig`, `submit_as`, кадры seat-input.

### Bootstrap (`scripts/bootstrap.gd`)

Публичный API для [`coop_session.gd`](scripts/coop/coop_session.gd) и внешних
читателей — сигнатуры и семантика:

| Метод |
|---|
| `is_world_ready` |
| `set_coop_persistence_inhibited` |
| `save_now_then_inhibit_persistence` |
| `flush_digs_for_coop_join` |
| `capture_coop_terrain_bulk` |
| `apply_coop_terrain_bulk` |
| `reseat_player_near` |

Override-хуки для bench/test extends — **instance-методы узла**, не static:

| Метод |
|---|
| `_make_planet_generator` |
| `_configure_boulder_instancer` |

**R5 spawn/settle** — порядок side-effects в `_place_when_ground_exists` и
комментарии-инварианты (VT #677, `PHYSICS_GROUND_TIMEOUT_MS` 8000) не менять.

**Orchestration `_ready`** — порядок вызовов заморожен (см.
[`docs/cheatsheets/bootstrap.md`](../cheatsheets/bootstrap.md)).

## 3. Паттерн extract'а

Эталон: `scripts/simulation/runtime/construction_command_service.gd`.

| Правило | |
|---|---|
| Тип | `RefCounted` + `static func` |
| Первый аргумент | владелец (`world` / `gateway` / `projection`) |
| Имя | уникальный `class_name` |
| Комментарии-инварианты | переносить **дословно** |
| Монолит | одноимённые тонкие обёртки → публичные сигнатуры не меняются |
| Cross-service | мутации только через обёртки владельца; **не** service→service (циклы `class_name`) |

## 4. Владение файлами

Extract'ы — по волнам; внутри волны полосы **не пересекаются**.

### Волна 1

| Полоса | Файлы / каталоги |
|---|---|
| **G** | `scripts/world_command_gateway.gd` + `scripts/gateway/` + `docs/cheatsheets/world-command-gateway.md` |
| **P** | `scripts/simulation/projection/simulation_physics_projection.gd` + координаторы/утилиты в той же папке + `docs/cheatsheets/physics-projection.md` |
| **U** | `scripts/ui/hud_control_terminal.gd` + `scripts/ui/control_terminal/` + `docs/cheatsheets/control-terminal.md` |

### Волна 2 — Construction

| Полоса | Файлы / каталоги |
|---|---|
| **C** | `scripts/simulation/runtime/construction_command_service.gd` + `construction_*_service.gd` / `construction_occupancy_util.gd` в той же папке + `docs/cheatsheets/construction-service.md` |

### Волна 3 — ToolController + Bootstrap

| Полоса | Файлы / каталоги |
|---|---|
| **T** | `scripts/tool_controller.gd` + `scripts/tool_control/` + `docs/cheatsheets/tool-controller.md` |
| **B** | `scripts/bootstrap.gd` + `scripts/bootstrap/` + `docs/cheatsheets/bootstrap.md` (perf overlay ~120 строк остаётся в монолите) |

**ToolController:** extract'ы **не** класть в `scripts/tools/` — там уже dev-скрипты (`environment_tuner.gd`, `bake_moon_boulder_assets.gd`).

## 5. Верификация (Windows / PowerShell)

Bash не в PATH — вызывать явно:

```powershell
# один тест
& "C:\Program Files\Git\bin\bash.exe" ./tests/run_one.sh test_<name>

# полный гейт (только если трогали ядро — см. AGENTS.md)
& "C:\Program Files\Git\bin\bash.exe" ./tests/run_tests.sh

# игра
.\run.ps1 res://scenes/main.tscn

# синтаксис одного файла
Y:\godot-engine\bin\godot.windows.editor.double.x86_64.console.exe --headless --path Y:\regolith --check-only res://scripts/<file>.gd
```

| Правило | |
|---|---|
| Параллельные Godot | **запрещены** — `run_one.sh` убивает сцену через 20 с → ложные FAIL |
| Кто гоняет | только **оркестратор**, одна сцена за раз |
| Агенты полос | Godot / тесты **не запускают** |
| Движок | только кастомный **double-precision** билд; Voxel GDExtension собран под него — стоковый Godot ломает всё с `VoxelTool` |

## 6. Откат

| | |
|---|---|
| Гранулярность | один extract = один коммит |
| Красный прогон | `git revert` **этого** коммита |
| Запрещено | коллективная починка поверх красного extract'а |
