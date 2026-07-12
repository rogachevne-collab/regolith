# HUD / UI v1

Статус: UI-контракт для vertical slice item 12 (финальный UI feedback без debug
overlay).

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` — доменный контракт;
- `docs/specs/VERTICAL-SLICE-01-INDUSTRIAL-BASE.md` — milestone (item 12);
- `docs/specs/CONSTRUCTION-V1.md` — язык состояний и цвета;
- `docs/specs/PLAYER-INTERACTION-V1.md` — interaction query, tool action, toolbar.

## Цель

Дать игроку читаемый sci-fi HUD (референс — Space Engineers), достаточный для
понимания «что выбрано, куда смотрю, что с целью, что со мной и что в хранилище»
**без debug overlay**. HUD закрывает slice item 12 в части UI feedback.

HUD не вводит нового геймплея и новых доменных типов машин — он только
**отображает** authoritative state и **инициирует уже существующие команды**.

## Core principle — presentation-only

HUD является presentation-слоем в том же смысле, что physics/visual projection:

- HUD **читает** authoritative state (simulation, tool state, interaction query,
  camera, SuitState) и **никогда не владеет им и не мутирует его**;
- любое действие игрока идёт через существующие команды и
  `WorldCommandGateway` (`scripts/world_command_gateway.gd`) либо через
  `ToolController` (`scripts/tool_controller.gd`), а **не** прямой мутацией сцены
  или simulation state;
- виджеты не кэшируют state как источник истины: при рассинхроне источник —
  authoritative state, а не UI;
- принцип `docs/PHYSICAL-LANGUAGE.md` «presentation не является источником
  состояния» распространяется на HUD дословно.

Единственное состояние, которым владеет UI-слой, — **эфемерное состояние
представления** (какая панель открыта, hover, drag-in-progress). Оно не
сохраняется в snapshot и не влияет на симуляцию.

## Виджеты и привязка к состоянию

| Виджет | Читает | Инициирует |
|---|---|---|
| `HUDRoot` | — | — |
| `Reticle` + `TargetInfo` | `InteractionQuery.current_hit` | — |
| `Toolbar` | `ToolController` | slot/rotate через существующий input |
| `Vitals` | `SuitState` | — |
| `Compass` | camera yaw | — |
| `Inventory` + `StoreView` | resource stores | — |
| `BlockPalette` | `ToolController` archetypes | assign в toolbar-слот |

### HUDRoot

`CanvasLayer`-контейнер и владелец общего `Theme` (см. «Theme-токены»). Держит
дочерние виджеты, прокидывает им authoritative-источники и включает/выключает
overlay-панели (inventory, palette). Логики симуляции не содержит.

### Reticle + TargetInfo

- источник: `InteractionQuery.current_hit` (`scripts/interaction_query.gd`),
  сигнал `hit_updated`;
- `Reticle` — центральный прицел; меняет форму/цвет по `target_kind`
  (voxel / simulation_element / control_seat) и допустимости текущего действия;
- `TargetInfo` для `KIND_SIMULATION_ELEMENT` показывает из `current_hit.metadata`:
  `archetype_id`, `build_progress`, `integrity`, `status_reason`
  (frame / operational / damaged / broken → цвет из палитры состояний);
- отображаемое имя archetype берётся через
  `WorldCommandGateway.archetype_display_name()`.

### Toolbar

- источник: `ToolController` (`scripts/tool_controller.gd`):
  - `TOOLBAR_PAGES` / `TOOLBAR_SLOTS_PER_PAGE` — раскладка слотов и страниц;
  - `CONSTRUCTION_ARCHETYPES` — доступные archetypes;
  - `active_tool`, `toolbar_page`, `toolbar_slot`, `selected_archetype_id`,
    `selected_orientation_index`;
  - сигналы `active_tool_changed`, `construction_selection_changed`,
    `state_changed`;
  - подписи слотов — `toolbar_slot_label(page, slot)`;
- отображает 9 слотов текущей страницы (иконка tool/archetype), индикатор
  выбранного слота, индикатор страницы (`[` / `]`);
- индикатор **24-ориентации** (`selected_orientation_index`,
  `OrientationUtil.ORIENTATION_COUNT = 24`) в build-режиме;
- счётчик `construction_component` через
  `WorldCommandGateway.construction_resource_amount()`;
- выбор слота и поворот **не** вызываются напрямую — Toolbar только визуализирует;
  ввод обрабатывает `ToolController` (`toolbar_slot_*`, `[`/`]`, `C`/`V`/`B`).

### Vitals

- источник: **`SuitState`** (см. ниже), сигнал изменения;
- три бара: `health` (hp), `oxygen` (O₂), `hydrogen` (H₂);
- каждый бар рисуется по нормализованной доле (`value / max`); цвет по палитре:
  steel-blue при норме, amber при предупреждении, red при критическом уровне;
- Vitals **только читает** `SuitState` и никогда его не меняет.

### Compass

- источник: yaw камеры/головы — `scripts/mouse_look.gd` (`aim_transform()`,
  `_pending_yaw`) поверх yaw тела игрока (`scripts/player_controller.gd`,
  `rotate_y` / `consume_yaw_delta`);
- лента-компас с метками `N` / `В` / `Ю` / `З` и текущим курсом в градусах
  (решение: латинская `N` как узнаваемый маркер севера, кириллица для
  остальных сторон — в духе кириллического chrome);
- конвенция: `N` = `-Z`, `В` = `+X`, курс по часовой стрелке
  (`heading = atan2(forward.x, -forward.z)`);
- презентационный расчёт направления из basis камеры, без записи в трансформы.

### Inventory + StoreView

- источник: `SimulationResourceStore.amounts`
  (`scripts/simulation/runtime/simulation_resource_store.gd`) через
  `SimulationWorld.list_resource_stores()`
  (`scripts/simulation/simulation_world.gd`);
- `StoreView` (`scripts/ui/hud_store_view.gd`) — переиспользуемый read-only
  виджет одного store: заголовок + строки `resource_id → amount` через
  `HudTokens` (метки ресурсов — `HudTokens.resource_label()`). Вместимость/fill
  показываются, **только если** модель store их отдаёт; сейчас
  `SimulationResourceStore` хранит лишь `amounts` (без capacity), поэтому виджет
  показывает количества и **не фабрикует** несуществующую вместимость. Место для
  fill-бара останется единственным — этот же виджет — когда capacity появится в
  Industry v1;
- `Inventory` (`scripts/ui/hud_inventory.gd`) реализован **поверх** одного
  `StoreView` для store `player` — тем самым StoreView действительно
  переиспользуемый. Store читается через read-only accessor
  `WorldCommandGateway.resource_store(store_id)` (HUD только читает, никогда не
  мутирует); ссылка на store берётся **лениво при открытии**, т.к. `bootstrap`
  сидирует store уже после готовности HUD;
- overlay-панель в центре экрана; открытие/закрытие по input-action
  `toggle_inventory` (клавиша `I`) — эфемерное presentation-состояние HUDRoot;
  панель не перехватывает mouselook (read-only-просмотр);
- только чтение: перемещение ресурсов между store — задача доменных команд, не UI;
- **просмотр store конкретной машины отложен** (см. «Не входит»): размещённый
  элемент `cargo_store` пока не имеет связанного `SimulationResourceStore`
  (в кернеле создаётся только store `player`), поэтому StoreView оставлен готовым,
  но per-element хранилища не подключаются, пока backing-состояние не появится в
  Industry v1.

### BlockPalette

- источник: `ToolController.CONSTRUCTION_ARCHETYPES` +
  `WorldCommandGateway.archetype_display_name()`;
- сетка archetypes с drag-n-drop назначением в слот toolbar;
- drag-in-progress — эфемерное presentation-состояние; назначение слота
  применяется через существующий toolbar API `ToolController`, а не прямой записью
  в `TOOLBAR_PAGES`.

## SuitState — новое authoritative состояние игрока

Per R1 контракт вводится **до кода**. `SuitState` — минимальное, самодостаточное
authoritative состояние выживания игрока (не presentation):

- `health` — `current` + `max`, нормализованная доля `current / max`;
- `oxygen` — `current` + `max`, нормализованная доля;
- `hydrogen` — `current` + `max`, нормализованная доля;
- сигнал изменения (`changed`), по которому обновляется Vitals.

`SuitState` — источник истины для трёх баров Vitals; HUD его только читает. Это
**маленькое survival-состояние**, а не полная система атмосфер / жизнеобеспечения:
герметичные объёмы, давление, утечки (`volume_leaking`), газообмен и
пресуализация из scope slice **исключены** (см. «Не входит» slice и данного
документа). SuitState не моделирует источники расхода — только текущие значения и
их пределы; логика расхода/пополнения появится отдельной доменной системой позже.

Пара-строка контракта добавлена в `docs/PHYSICAL-LANGUAGE.md` рядом с разделом
состояния/диагностируемости.

## Палитра состояний

HUD переиспользует язык цветов состояний из `docs/specs/CONSTRUCTION-V1.md`:

- **cyan** — valid / доступно (preview valid, доступное действие/слот);
- **steel-blue** — operational / норма (готовый элемент, здоровый бар);
- **amber** — warning / damaged (частичная прочность, предупреждение);
- **red** — critical / broken (сломано, критический уровень);
- invalid preview — red translucent (как в Construction v1).

Конкретные значения — в Theme-токенах ниже (замораживаются style-proof).

## Theme-токены (заморожены style-proof)

Значения заморожены визуальным style-proof (Phase 0.5, референс-кадр
`hud_style_proof.png`). Источник истины для
кода — `resources/ui/hud_theme.tres` (StyleBox/шрифты) и
`scripts/ui/hud_tokens.gd` (цвета состояний + декларативные билдеры виджетов).
Виджеты не «зашивают» значения мимо `Theme`/`HudTokens`.

### Палитра состояний

| Ключ | Hex | `Color` |
|---|---|---|
| `state.valid` (cyan) | `#33E1FF` | `Color(0.20, 0.882, 1.0)` |
| `state.ok` (steel-blue) | `#4C9BE8` | `Color(0.298, 0.608, 0.91)` |
| `state.warning` (amber) | `#FFB13C` | `Color(1.0, 0.694, 0.235)` |
| `state.critical` (red) | `#FF4438` | `Color(1.0, 0.267, 0.22)` |

`preview.valid` = cyan, `preview.invalid` = red translucent (Construction v1).

### Нейтрали

| Ключ | Hex / alpha |
|---|---|
| `bg_screen` | `#05080C` |
| `panel_bg` | `#070B0F` @ 0.80 |
| `panel_border` (hairline) | `#212E3C` |
| `slot_bg` | `#070B0F` @ 0.72 |
| `slot_border` | `#1E2935` |
| `slot_selected_bg` | `#091217` @ 0.80 |
| `slot_selected_border` | `#28677F` |
| `bar_track` | `#0D141B` |
| `divider` | `#212E3C` @ 0.50 |
| `text_primary` | `#C7DEEC` |
| `text_title` | `#B3D8E9` |
| `text_dim` | `#6E8494` |

### Шрифт и размеры

Проектный шрифт по умолчанию (Open Sans, рендерит кириллицу). Размеры:
`title` 16, `body`/`value` 14, `small`/`label` 11.

### Геометрия / отступы

- скругление углов 3 px; рамка 1 px везде; контент-маргины панели L/R 18, T/B 16;
- отступ панель↔экран 48–52 px; gap строки/секции 11; pre-bars 6; внутренний
  gap строки-бара 10; колонка ключа info-строки 96;
- toolbar: слот 52×52, gap слотов 10, нижний отступ 48; индикатор выбранного
  слота — голубая (cyan) подчёркивающая линия шириной (слот−12)×2 px, инсет 6.

### Параметры шейдеров (`.gdshader`, только текст — R3)

- `hud_panel` (blend_add): `border_width 1.0`, `glow_width 6`, `glow_strength 0.14`,
  `corner_len 14`, `corner_strength 0.4`, `scanline_strength 0.02`,
  `sweep_strength 0.0`;
- `hud_bar`: `segments 24`, `gap_ratio 0.16`, `glow_strength 0.22`,
  `lead_strength 0.35` (статичный), размер 232×10;
- `hud_reticle` (blend_add): `gap 6`, `len 9`, `thick 1.0`, `dot_size 1.0`,
  `bracket_strength 0.0`, `glow_strength 0.15`, размер 64×64;
- `hud_emblem`: `radius 0.58`, `line_w 0.06`, `color = state.valid`;
- `national_tick`: 3 сегмента 9×3 px @ 0.5 alpha (white `#DBE5EF` / blue
  `Color(0.20,0.36,0.66)` / red `#C73D3D`).

Соглашение: у каждого шейдера есть uniform `rect_size`, выставляемый из кода
по пиксельному размеру ноды.

## Флейвор / нейминг (советско-космический дух, без брендинга)

- chrome-подписи кириллицей; латиница только для коротких tool-кодов;
- формат callsign заголовка цели: `ОБЪЕКТ <NN> · ИНДЕКС <NN-Х>`
  (`NN` — assembly/element id по модулю 100, `Х` — детерминированная кир. буква);
- tool-коды остаются латинскими аббревиатурами: `DRL` (бур), `WLD` (сварка),
  `FRM` (frame), `BEM` (frame_beam), `PWR` (power_source), `SDR`
  (stationary_drill), `CRG` (cargo_store), `PRC` (processor), `FAB` (fabricator);
- абстрактная эмблема (`hud_emblem`) + приглушённый триколор-tick — только chrome,
  не флаг и не логотип;
- статусы цели (`status_reason`) локализуются: `ok → РАБОТА`,
  `element_incomplete → МОНТАЖ`, `damaged → ПОВРЕЖДЕНИЕ`, `element_broken → СЛОМАН`.

## Фазы

- **Phase 0 — спецификация.** Данный документ + строка про SuitState в
  `docs/PHYSICAL-LANGUAGE.md` (закрыто этим PR).
- **Phase 0.5 — style proof.** Визуальный прогон, заморозка конкретных значений
  Theme-токенов (палитра, панели, шрифт, отступы, шейдеры).
- **Phase 1 — framework + toolbar + compass. (реализовано)** `HUDRoot`
  (`scenes/ui/hud_root.tscn` + `scripts/ui/hud_root.gd`, layer 5) на общем
  `Theme`, вживлён в `scenes/player.tscn` вместо старых raw-лейблов
  `InteractionFeedback`. Виджеты: `Reticle` + `TargetInfo` (styled target-панель
  слева-сверху + приглушённая строка под прицелом), `Toolbar` (реальные слоты
  `TOOLBAR_PAGES`, cyan-подчёркивание выбранного, индикатор 24-ориентаций,
  счётчик `construction_component`), `Compass`, а также перенесённые из старого
  feedback контекстный prompt и таймерный result-toast с локализацией reason.
  Debug-лейблы `main.tscn` (координаты/подсказка) убраны за флаг
  `bootstrap.debug_overlay` (по умолчанию off). Бары Vitals **не входят** в
  Phase 1 — они появятся в Phase 2 вместе с authoritative `SuitState` (показывать
  «фейковые» доли без источника нельзя, presentation-only).
- **Phase 2 — SuitState + Vitals. (реализовано)** Authoritative `SuitState`
  (`scripts/suit_state.gd`) — узел на игроке в `scenes/player.tscn` (не autoload:
  состояние принадлежит конкретному игроку рядом с `InteractionQuery`/
  `ToolController`/`Drill`). Три канала `health`/`oxygen`/`hydrogen` (`current` +
  `max` + доля `*_fraction()`), сигнал `changed`, плюс минимальный tunable
  drain/regen-стаб (`tick()`), явно помеченный как заглушка до доменной системы
  баланса. Виджет `Vitals` (`scripts/ui/hud_vitals.gd`) — панель «СИСТЕМЫ
  СКАФАНДРА» слева-снизу: три бара на шейдере `hud_bar` + `HudTokens`, подписи
  `ЗДР` (health), `О₂` (oxygen), `Н₂` (hydrogen). Цвет по доле: steel-blue при
  норме (`> 0.5`), amber при предупреждении (`≤ 0.5`), red при критическом уровне
  (`≤ 0.25`). Vitals только читает `SuitState` через `changed`, никогда не пишет.
  Покрыт headless-тестом `scenes/test_suit_state.tscn` (доли/клэмп/сигнал/дрейн).
- **Phase 3 — inventory + StoreView. (реализовано)** Переиспользуемый read-only
  `StoreView` (`scripts/ui/hud_store_view.gd`): заголовок + строки
  `resource_id → amount` через `HudTokens` (кириллический chrome), место под
  fill-бар зарезервировано на случай появления capacity в модели store.
  `Inventory` (`scripts/ui/hud_inventory.gd`) — центральная overlay-панель
  «ИНВЕНТАРЬ», построенная **поверх** одного `StoreView` для store `player`;
  toggle по input-action `toggle_inventory` (`I`), store читается лениво через
  read-only `WorldCommandGateway.resource_store()`. Виджеты только читают
  authoritative store, не мутируют его. Per-machine store viewing для
  `cargo_store` **отложен в Industry v1**: у размещённого элемента ещё нет
  связанного `SimulationResourceStore` (в кернеле создаётся лишь store `player`),
  фабриковать хранилище нельзя (presentation-only) — StoreView оставлен готовым к
  подключению.
- **Phase 4 — block palette drag-n-drop. (реализовано)** Overlay-палитра
  `BlockPalette` (`scripts/ui/hud_palette.gd`, узел `Palette` в
  `scenes/ui/hud_root.tscn`) — сетка всех `CONSTRUCTION_ARCHETYPES` с латинским
  tool-кодом (`FRM`/`BEM`/`PWR`/`SDR`/`CRG`/`PRC`/`FAB`) и кириллическим именем
  через `WorldCommandGateway.archetype_display_name()`, стилизована `HudTokens`
  (frozen). Открытие/закрытие по input-action `toggle_palette` (клавиша `G`) —
  эфемерное presentation-состояние; на время открытия курсор становится видимым
  и gameplay-ввод паузится (как в settings overlay). Godot Control drag-n-drop:
  запись palette-entry (`_get_drag_data` → payload `{"kind":"hud_block",
  "archetype_id":…}` + чистое drag-preview), toolbar-слоты — drop-таргеты
  (`_can_drop_data`/`_drop_data` в `scripts/ui/hud_toolbar.gd`, cyan-подсветка
  валидного дропа). Назначение слота идёт через **новый** presentation/config
  API `ToolController.assign_slot_archetype(page, slot, archetype_id)`, который
  мутирует **рантайм-копию** раскладки (deep-copy `TOOLBAR_PAGES`, не const),
  отказывает для drill/weld-слотов и неизвестных archetypes (paging и два
  tool-слота остаются), бампит `toolbar_layout_revision` и эмитит
  `toolbar_layout_changed`. Toolbar перечитывает раскладку через
  `toolbar_slot_archetype_id()` и перестраивается по ревизии. Выбор
  переназначенного слота ведёт `selected_archetype_id` через **тот же** путь
  (`_apply_toolbar_slot` → `construction_selection_changed`), путь
  `construction_apply` / issue команд не меняется. Логика remap покрыта
  headless-тестом `scenes/test_construction_toolbar_remap.tscn`
  (`CONSTRUCTION-REMAP: PASS`; сам drag-жест проверяется вручную в игре, MCP Lite
  ввод не эмулирует).

## Acceptance

1. Состояние читается без debug overlay: выбранный tool/archetype/ориентация,
   цель (archetype/build_progress/integrity/status_reason), vitals, курс,
   содержимое store.
2. Ни один виджет не мутирует simulation/tool state; все действия идут через
   существующие команды / `WorldCommandGateway` / `ToolController`.
3. Каждый виджет привязан к **именованному** authoritative-источнику из раздела
   «Виджеты и привязка к состоянию».
4. Цвета состояний соответствуют языку `CONSTRUCTION-V1.md`.
5. `SuitState` покрыт headless-тестом (`scenes/test_*.tscn` + строка в
   `tests/run_tests.sh`, R2): значения/доли/сигнал изменения корректны и
   ограничены пределами.
6. Theme-токены заданы через общий `Theme`; финальные значения — из style-proof.

## Не входит

- runtime-диагностика машин (`no_power`, `storage_full`, `port_disconnected` и
  прочие reason из раздела «Диагностируемость») — переносится в Industry v1;
  сейчас в HUD только docs-level упоминание, без runtime-виджета;
- просмотр store отдельной машины (targeted `cargo_store` → `StoreView`) —
  отложен в Industry v1 по той же причине, что и диагностика: у размещённого
  элемента `cargo_store` пока нет собственного `SimulationResourceStore` (кернел
  создаёт только store `player`). StoreView переиспользуемый и готов, но per-machine
  хранилища не фабрикуются, пока не появится backing-состояние;
- симуляция `condition` (долговременный износ);
- атмосферы, герметичные объёмы, давление и жизнеобеспечение сверх минимального
  `SuitState`;
- кооператив и сетевой replication UI;
- финальные значения Theme-токенов (заморозка — отдельный style-proof шаг);
- меню/настройки/экраны вне игрового HUD.
