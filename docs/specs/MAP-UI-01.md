# Map UI v1 — карта луны

Статус: UI-контракт для overlay-карты планеты (клавиша `M`).

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` — presentation не владеет simulation state;
- `docs/specs/HUD-UI-01.md` — HUD framework / theme / presentation-only;
- `docs/specs/MOON-EXPERIMENT-V0.md` — геометрия Ø1 km;
- `docs/specs/INDUSTRY-V1.md` — world loot piles, resource ids.

## Цель

Дать игроку **карту луны**: текущие координаты, курс, свои метки,
известные кучи ресурсов на грунте и заметные построенные объекты — без
debug overlay и без новых доменных типов машин.

## Core principle

Карта — presentation-слой (как остальной HUD):

- **читает** позицию игрока, heading камеры, `list_world_loot_piles()`,
  позиции элементов через `WorldCommandGateway`;
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
- Компасная конвенция как у HUD Compass: `N`/`С` = `-Z`, `В` = `+X`.

### Проекция (legacy `flat_moon`)

- Локальная XZ-карта вокруг игрока (не сфера), тот же chrome.

### Координаты (readout)

Пока карта открыта, панель показывает:

- world `X Y Z` (м);
- широта / долгота (градусы) на сфере; на flat — только XZ;
- высота над номинальной поверхностью `\|p\| − R` (planetoid);
- курс (градусы), как у Compass.

### Слои маркеров

| Слой | Источник | Цвет (язык HUD) |
|---|---|---|
| Игрок | `player.global_position` + camera yaw | cyan (`valid`) |
| Ресурсы | world loot piles через gateway | amber (`warning`) |
| Объекты | выбранные archetypes (бур, склад, питание, …) | steel (`ok`) |
| Метки | пользовательские, `WorldPersistence.map_markers` | cyan outline |

В v1 **нет** процедурных «жил» в коре: «залежи» на карте = известные
кучи `WorldLootPile` (добытый/сброшенный ресурс на поверхности). Когда
появится доменная модель месторождений — отдельная спека + слой.

### Взаимодействие с метками

- ЛКМ по пустому месту карты → добавить метку на поверхности в этой
  точке (автоимя `МЕТКА N`);
- ЛКМ по своей метке → выбрать; `Delete` / ПКМ → удалить;
- курсор над картой → readout координат точки под курсором.

Пока карта открыта: курсор видим, gameplay input паузится
(`set_gameplay_input_enabled(false)`), как у BlockPalette.

## Gateway read API

`WorldCommandGateway.map_overlay_entries() -> Array[Dictionary]` —
read-only список `{ kind, id, label_key, position, … }` для loot и
structures. HUD только читает.

## Не входит

- procedural ore veins / deposit generation;
- GPS-навигация / автопилот к метке;
- fog of war / разведка;
- 3D globe spinner (только 2D развёртка v1);
- меню вне игрового HUD.
