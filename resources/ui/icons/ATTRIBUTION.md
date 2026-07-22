# Icon set — Lucide

Иконки HUD взяты из **Lucide** (https://lucide.dev), лицензия **ISC**.
Полный пак лежит здесь: `lucide/icons/*.svg` (1997 шт.) + готовый шрифт
`lucide/font/lucide.ttf` (+ `codepoints.json`). Текст лицензии — `lucide/LICENSE`.

ISC **не требует** указания авторства в игре (в отличие от CC BY): достаточно
сохранить файл лицензии в проекте. Кредит-строку можно добавить по желанию:

> UI icons from Lucide (lucide.dev), ISC License.

См. `docs/specs/ICON-SYSTEM-V0.md`.

## Набор v0 (id в игре → имя иконки Lucide)

Точные направленные стрелки берём **тоже из Lucide** (`arrow-*-to-line`) —
рисовать ничего не нужно.

### Действия

| id | lucide |
|---|---|
| `piston.extend` | `arrow-up-to-line` |
| `piston.retract` | `arrow-down-to-line` |
| `actuator.stop` | `square` |
| `actuator.reverse` | `repeat-2` |
| `actuator.motor_toggle` / `machine.*` | `power` |
| `actuator.set_target` | `target` |
| `rotor.spin_cw` | `rotate-cw` |
| `rotor.spin_ccw` | `rotate-ccw` |
| `actuator.set_speed` | `gauge` |
| `machine.toggle` (тумблер) | `toggle-left` |

### Категории навигатора

| категория | lucide |
|---|---|
| Приводы | `move-vertical` |
| Машины | `cog` |
| Питание | `zap` |
| Склад | `package` |
| Датчики | `radar` |
| Отказы | `triangle-alert` |

### Статусы

| status | lucide |
|---|---|
| `ok` | `circle-check` |
| `moving` | `play` |
| `standby` / `idle` / `disabled` | `circle-pause` |
| `joint_limit` / `overloaded` / `storage_full` | `triangle-alert` |
| `no_power` / `port_disconnected` | `unplug` |
| `element_broken` / `actuator_broken` | `circle-x` |

### Узлы

| узел | lucide |
|---|---|
| поршень | `move-vertical` |
| ротор | `rotate-cw` |
| шарнир | `spline` |
| бур | `drill` |
| процессор | `cpu` |
| батарея | `battery-medium` |
| склад | `box` |
| распределитель | `plug-zap` |

Все имена соответствуют файлам `lucide/icons/<имя>.svg` и кодпоинтам в
`lucide/font/codepoints.json`.
