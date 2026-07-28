# PLATFORM-WHEELS-V0 — гигантская палуба на Ø4.5 м колёсах

Статус: playtest spike (не заменяет демо-ровер).

## Зачем

Палуба из `large_frame` (2.5 м) слишком тяжела для Medium-колёс (Ø1.5 м).
Отдельная пара архетипов + отдельный spawn, без смены `Wheel_Medium_01` /
`Suspension_Medium` и без фразы RoverComposer.

## Контракт

| | Medium (демо-ровер) | Platform |
|---|---|---|
| id | `Wheel_Medium_01` / `Suspension_Medium` | `Wheel_Platform_01` / `Suspension_Platform` |
| Ø | 1.5 м | **4.5 м** |
| палуба | `frame` 0.5 м | **6×8** `large_frame` |
| колёс | 4–12 (фраза) | **4** (углы) |
| spawn | U (`spawn_debug_rover`) | **`,`** (`spawn_debug_platform`) |

Имена `*_Platform*` специально после `*_Medium*` по алфавиту —
`authored_wheel_pair()` по-прежнему выбирает Medium.

## Цифры (старт под ~30 т палубы, g=1.62, 4 колеса)

- `radius_m=2.25`, `width_m≈2.2`, `mass_kg` колеса 1000 / стойки 400
- `drive_torque_n_m=150000`, `brake_torque_n_m=200000`, `power_draw_w=600`
- ход ≈1.56 м, `k=45000` Н/м, `c=40000`, `max_force=200000` Н
- 4× `power_distributor_small` у углов (supply 6 м; центр палубы не покрывает колёса)

## Файлы

- архетипы: `resources/archetypes/authored/Wheel_Platform_01.tres`,
  `Suspension_Platform.tres`
- визуал ×3: `scenes/presentation/wheel_platform_visual.tscn`,
  `suspension_platform_visual.tscn`
- compose/spawn: `scripts/authoring/platform_composer.gd`
- hotkey: `spawn_debug_platform` → `,` в `project.godot`, опрос в `bootstrap.gd`
