# Icon System v0 — иконки HUD (действия, категории, статусы, узлы)

Статус: design contract (спека до кода). Поддерживает `CONTROL-ACTIONS-V0` и
терминал/тулбар; заменяет текстовые коды (`TOOL_CODES`/`ITEM_CODES`) на глифы.

Родительские документы:

- `docs/specs/HUD-UI-01.md` (тема, `HudTokens`, цветовой язык);
- `docs/specs/CONTROL-ACTIONS-V0.md` (пульт действий, инспектор);
- `docs/PHYSICAL-LANGUAGE.md` → «Диагностируемость» (статусы).

## Цель

Один связный иконочный набор вместо текстовых кодов: игрок читает интерфейс
глифами, а не `PST / RTR / DRL`. Действия становятся language-free (стрелки/стоп
понятны без кириллицы → меньше локализации).

## Нормативные решения

1. **Источник — Lucide, лицензия ISC.** Чистый monoline-набор (1997 иконок),
   подходит под сдержанный «пультовый» стиль. Пак загружен в репозиторий:
   `resources/ui/icons/lucide/` (`icons/*.svg` + готовый шрифт `font/lucide.ttf`
   + `font/codepoints.json`). Ничего рисовать не нужно — направленные стрелки
   (`arrow-*-to-line`) тоже есть в Lucide.
2. **Атрибуция не обязательна (ISC).** Достаточно сохранить `lucide/LICENSE` в
   проекте. Ведём лёгкий манифест `resources/ui/icons/ATTRIBUTION.md`
   (`id → имя lucide`) как справочник маппинга, не как юридическое требование.
3. **Монохром, тон = цветовой язык.** Иконка рисуется одним цветом и тонируется
   `HudTokens.color_for_status()` (`COL_OK/WARNING/CRITICAL/DIM/VALID`). Цвет несёт
   статус; сама иконка — форму. Многотоновых пиктограмм в v0 нет.
4. **Смешанный формат:**
   - **Иконочный шрифт (.ttf)** — моно UI-набор: действия, категории, статусы.
     Тонируется как текст (`font_color`), масштабируется, ложится в существующий
     Label-пайплайн (`HudSmall`/`HudValue`). Замена «текстовый код → глиф».
   - **SVG → `Texture2D`** — крупные машинные иконки узлов: `TextureRect` +
     `modulate = статус-цвет`. Богаче по детали, где силуэт важен.
5. **Индирекция код→иконка сохраняется.** Реестры `ACTION_GLYPHS`,
   `CATEGORY_GLYPHS`, `STATUS_GLYPHS`, `ARCHETYPE_ICONS` — по образцу
   `TOOL_CODES`. Логика ссылается на `id`, арт меняется без правок логики (шов уже
   заложен в `HudTokens.make_item_icon` — «bound to id so future art can replace»).
6. **Приоритет v0:** действия → категории → статусы. Иконки узлов (машинные) —
   следующим шагом; до них узлы держат текстовый код.

## Пайплайн

### Моно-набор (шрифт) — уже готов

1. Шрифт **не генерируем** — Lucide поставляется с готовым `font/lucide.ttf` и
   `font/codepoints.json` (имя иконки → кодпоинт). Оба уже в репозитории.
2. Импорт `lucide.ttf` в Godot; тема `res://resources/ui/hud_theme.tres` получает
   вариацию `HudIcon` (размер/выравнивание).
3. Реестры `ACTION_GLYPHS`/`CATEGORY_GLYPHS`/`STATUS_GLYPHS` мапят `id → имя lucide`;
   код-поинт берётся из `codepoints.json` (или зашивается сгенерённой константой).
4. `HudTokens`: `make_action_icon(action_id, color)` → Label с глифом и
   `font_color = color`. Аналогично категории/статусы.

### Машинные иконки (SVG-текстуры) — шаг 2

1. SVG узлов → `res://resources/ui/icons/nodes/<id>.svg`, запись в `ATTRIBUTION.md`.
2. Godot импортит как `Texture2D` (крупный import scale для чёткости).
3. `HudTokens.make_archetype_icon(archetype_id, color)` → `TextureRect` +
   `modulate = color`, реестр `ARCHETYPE_ICONS`.

## Маппинг v0 (id → имя Lucide)

Все имена — файлы `resources/ui/icons/lucide/icons/<имя>.svg` и кодпоинты в
`font/codepoints.json`. Полная таблица (+ узлы) — `resources/ui/icons/ATTRIBUTION.md`.

### Действия (`ACTION_GLYPHS`)

| action_id | lucide |
|---|---|
| `piston.extend` | `arrow-up-to-line` |
| `piston.retract` | `arrow-down-to-line` |
| `actuator.stop` | `square` |
| `actuator.reverse` | `repeat-2` |
| `actuator.motor_toggle` / `machine.*` | `power` |
| `actuator.set_target` | `target` |
| `rotor.spin_cw` / `spin_ccw` | `rotate-cw` / `rotate-ccw` |
| `actuator.set_speed` | `gauge` |

### Категории навигатора (`CATEGORY_GLYPHS`)

| категория | lucide |
|---|---|
| Приводы | `move-vertical` |
| Машины | `cog` |
| Питание | `zap` |
| Склад | `package` |
| Датчики | `radar` |
| Отказы | `triangle-alert` |

### Статусы (`STATUS_GLYPHS`) — тон из `color_for_status`

| status | lucide | тон |
|---|---|---|
| `ok` | `circle-check` | `COL_OK` |
| `moving` | `play` | `COL_OK` |
| `standby` / `idle` / `disabled` | `circle-pause` | `COL_DIM` |
| `joint_limit` / `overloaded` / `storage_full` | `triangle-alert` | `COL_WARNING` |
| `no_power` / `port_disconnected` | `unplug` | `COL_WARNING` |
| `element_broken` / `actuator_broken` | `circle-x` | `COL_CRITICAL` |

### Узлы (`ARCHETYPE_ICONS`) — шаг 2

Поршень, ротор, шарнир, бур, гироскоп, двигатель, процессор, батарея, склад,
распределитель, труба, колесо, подвеска, кокпит, фундамент/каркас.

## Внедрение

1. Спека (этот документ) + пак Lucide в репозитории (сделано).
2. Импорт `lucide/font/lucide.ttf` в Godot + тема-вариация `HudIcon`.
3. Реестры `ACTION/CATEGORY/STATUS_GLYPHS` (`id → имя lucide → кодпоинт`).
4. `HudTokens.make_action_icon/…` + подмена текста/кодов в пульте, инспекторе и
   навигаторе `CONTROL-ACTIONS-V0` (убрать `TOOL_CODES` из HUD-строк).
5. Шаг 2: SVG-текстуры машинных узлов + `make_archetype_icon`.

Замена кодов на глифы не трогает доменные контракты: `id` те же, меняется только
слой отрисовки в `HudTokens`.
