# Map UI v1 — карта луны

Статус: UI-контракт для overlay-карты планеты (клавиша `M`).

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` — presentation не владеет simulation state;
- `docs/specs/HUD-UI-01.md` — HUD framework / theme / presentation-only;
- `docs/specs/MOON-EXPERIMENT-V0.md` — геометрия Ø1 km;
- `docs/specs/INDUSTRY-V1.md` — world loot piles, resource ids;
- `docs/specs/TERRAIN-MATERIALS-V1.md` — залежи / TerrainMaterial / MoonMaterialField.

## Цель

Дать игроку **карту луны**: текущие координаты, курс, свои метки,
**зоны залежей** (ильменит, анортозит, …), известные кучи ресурсов на грунте
и заметные построенные объекты — без debug overlay и без новых доменных типов
машин.

## Core principle

Карта — presentation-слой (как остальной HUD):

- **читает** позицию игрока, heading камеры, `list_world_loot_piles()`,
  позиции элементов через `WorldCommandGateway`, и **детерминированное поле
  материалов** `MoonMaterialField` (тот же источник, что и yield бура);
- **не мутирует** simulation / voxel / stores;
- единственное собственное состояние — эфемерное «открыта/закрыта» и
  **пользовательские метки** (аннотации игрока, не kernel snapshot).

Пользовательские метки сохраняются в `WorldPersistence` (`map_markers` в
`world_save.json`), рядом с player pose, **вне** `simulation` snapshot.
Сброс сейва (`clear_moon_progress`) удаляет и их.

## Виджет `MapPanel`

| | |
|---|---|
| Сцена | узел `MapPanel` в `scenes/ui/hud_root.tscn` |
| Скрипт | `scripts/ui/hud_map_panel.gd` |
| Input | `toggle_map` (клавиша `M`); закрытие также `release_mouse` (Esc) |
| Тема | `HudTokens` / `hud_theme.tres` |

### Проекция (planetoid / `main.tscn`)

- Экваториальная развёртка, совпадающая с panorama UV heightmap
  (`MoonHeightmapUtil.node_uv_from_direction` /
  `direction_from_node_uv`).
- Фон — downsample heightmap → grayscale texture (если файл есть);
  иначе тёмная сетка.
- Поверх фона — полупрозрачный слой **залежей** (`MoonMapDepositOverlay`,
  ~192×96), если включён чекбокс «Залежи».
- Компасная конвенция как у HUD Compass: `N`/`С` = `-Z`, `В` = `+X`.

### Проекция (legacy `flat_moon`)

- Локальная XZ-карта вокруг игрока (не сфера), тот же chrome.
- Слой залежей на flat v1 не рисуется (поле материалов — сферическое).

### Координаты (readout)

Пока карта открыта, панель показывает:

- world `X Y Z` (м);
- широта / долгота (градусы) на сфере; на flat — только XZ;
- высота над номинальной поверхностью `\|p\| − R` (planetoid);
- курс (градусы), как у Compass.

Курсор над картой дополнительно показывает **имя залежи** под точкой
(если слой «Залежи» включён и в ближней коре есть линза).

### Слои маркеров

| Слой | Источник | Цвет (язык HUD) |
|---|---|---|
| Игрок | `player.global_position` + camera yaw | cyan (`valid`) |
| Залежи | `MoonMaterialField` через `MoonMapDepositOverlay` | tint по материалу (легенда в сайдбаре) |
| Ресурсы | world loot piles через gateway | amber (`warning`) |
| Объекты | выбранные archetypes (бур, склад, питание, …) | steel (`ok`) |
| Метки | пользовательские, `WorldPersistence.map_markers` | cyan outline |

**Залежи:** на развёртке отмечаются линзы (ильменит, анортозит, оливин,
пироксен, лёд), сэмплированные на нескольких глубинах у поверхности
(2…14 м). Фон mare/highland не заливает карту — только «цветные пятна»
руд. Starting-area overlay от seed игрока учитывается (как у добычи).

Кучи `WorldLootPile` остаются отдельным слоем (добытое/сброшенное на
поверхности), не путать с нетронутыми залежами в коре.

### Взаимодействие с метками

- ЛКМ по пустому месту карты → добавить метку на поверхности в этой
  точке (автоимя `МЕТКА N`);
- ЛКМ по своей метке → выбрать; `Delete` / ПКМ → удалить;
- курсор над картой → readout координат + залежь под курсором.

Пока карта открыта: курсор видим, gameplay input паузится
(`set_gameplay_input_enabled(false)`), как у BlockPalette.

## Gateway read API

`WorldCommandGateway.map_overlay_entries() -> Array[Dictionary]` —
read-only список `{ kind, id, label_key, position, … }` для loot и
structures. HUD только читает.

Слой залежей **не** идёт через gateway: это чистая функция поля материалов
(`MoonMapDepositOverlay`), без simulation mutation.

## Не входит

- fog of war / разведка (залежи видны сразу — sandbox);
- GPS-навигация / автопилот к метке;
- запись `CHANNEL_INDICES` в voxel (визуал в мире — отдельный follow-up);
- 3D globe spinner (только 2D развёртка v1);
- меню вне игрового HUD.
