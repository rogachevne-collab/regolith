# Piston debug instrumentation

Тестовая карта и overlay для отладки поршней под radial gravity.

## Тестовая карта

```bash
./run.sh res://scenes/test_moon_5km_flat.tscn
```

| Параметр | Значение |
|---|---|
| Диаметр | 5000 м (override через `MoonGeometry.set_test_diameter`) |
| Рельеф | нет — `MoonSpherePlainGenerator`, `sdf = \|p\| − R` |
| Гравитация | radial 1.62 m/s² (как `main`) |
| Сейв | изолирован: `user://moon_experiment/test_5km_flat_sphere/` |
| Демо | буровой манипулятор (`MachineComposer`) + piston overlay |

Файлы: `scenes/test_moon_5km_flat.tscn`, `scripts/test_moon_5km_flat_bootstrap.gd`.

## Горячие клавиши

| Клавиша | Действие |
|---|---|
| F10 | вкл/выкл overlay |
| F11 | dump всех поршней в Output |
| F12 | cycle focus assembly (несколько сборок) |

## Инструментация (`PistonDebugInstrumentation`)

Скрипт: `scripts/debug/piston_debug_instrumentation.gd`.  
На тест-карте создаётся автоматически; можно повесить на любую moon-сцену.

### Что собирает (каждый physics tick)

| Поле | Зачем |
|---|---|
| `extension_m`, `velocity_mps` | факт vs команда — залипание, drift Jolt |
| `mass_kg` (carriage) | нагрузка на мотор; расхождение dry mass vs `RigidBody.mass` |
| `hold_n` | сила удержания вдоль оси: `-m · g · axis` — главный бюджет под radial g |
| `gravity_dot_axis` | компонента g на ось; на горизонтальном поршне ≈ 0 на полюсе, ≠ 0 на склоне |
| `force_limit_n`, `applied_force_n`, `motion_budget_n` | `motion_budget = limit − hold` — если ≤ 0, поршень **не может** двигаться против g |
| `force_saturated` | мотор упёрся в limit (overload / stuck pipeline) |
| `status` | idle / moving / stuck / overloaded |
| `piston_count`, `base_group_id → head_group_id` | несколько поршней на одной сборке — кто тащит какую группу |
| `root_group_id`, `compile_valid`, `compile_reason` | ошибки body-group graph (циклы, invalid_piston_groups, chain>4) |
| `carriage_elements` | размер карriage — лишняя масса на head |

### Логи

1. **Overlay** — live-строка на каждый joint focus-сборки; подсветка `NO MOTION BUDGET` и `SAT`.
2. **Status transitions** — `print` при смене `idle→stuck→overloaded` с hold/budget.
3. **F11 dump** — полная строка в консоль для copy/paste / diff между кадрами.

### Типичные паттерны багов

| Симптом в overlay | Вероятная причина |
|---|---|
| `NO MOTION BUDGET`, hold ≈ force_limit | масса карriage / g·axis съедает весь limit |
| `SAT` + stuck, v≈0 | Jolt constraint vs applied force; nested piston groups |
| `compile≠ok` | invalid body groups / цикл piston graph / 5-й piston |
| несколько J* на asm, разные hold | поршни на разных ориентациях под radial g |
| mass скачет | carriage compiler включил лишние элементы |

## Включение на других сценах

```gdscript
var dbg := PistonDebugInstrumentation.new()
dbg.session_path = NodePath("../SimulationSession")
dbg.player_path = NodePath("../Player")
add_child(dbg)
```

Экспорты: `log_to_console`, `log_interval_s`, `focus_assembly_id`.
