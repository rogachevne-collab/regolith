# Control Terminal (K-пульт) — куда смотреть

K-пульт — **view**: читает снапшоты у `WorldCommandGateway` и шлёт команды
через `submit`. Логики симуляции в UI нет и не добавлять.

## Куда идти

| Задача | Файл |
|---|---|
| низкоуровневые виджеты (метки, панели, иконки, `_cmd`, layout) | `scripts/ui/control_terminal/terminal_widget_kit.gd` |
| список оборудования и фильтры (all/actuator/machine/alarm, поиск) | `scripts/ui/control_terminal/terminal_equipment_list.gd` |
| фейсплейт и уставки (ParameterCatalog / SETPOINTS, слайдеры, rename) | `scripts/ui/control_terminal/terminal_faceplate_builder.gd` |
| панель аварий | `scripts/ui/control_terminal/terminal_alarms_panel.gd` |
| слоты быстрых действий (бар 9×9, bind/fire, компактная лента) | `scripts/ui/hud_control_terminal.gd`; лента — `hud_compact_action_bar.gd` |
| цикл снапшотов (10 Гц poll, dirty-сигнатура, live-patch узла) | `scripts/ui/control_terminal/terminal_snapshot_controller.gd` |
| построение снапшота (read-model) | `scripts/presentation/control_terminal_snapshot_builder.gd` через gateway |
| жизненный цикл / публичный API узла | `scripts/ui/hud_control_terminal.gd` |

## Данные и команды

**Читает у gateway:**

- `control_terminal_snapshot(assembly_id, host_hint)` — полное окно
- `control_terminal_bar_snapshot(assembly_id, host_hint)` — закрытое окно / компактная лента
- `get_world()` — live-patch выбранного узла / topology_revision
- `get_local_seat_element_id` / `is_local_seat_driver` — `controls_permitted()`

**Шлёт через `gateway.submit` (kind):**

- `set_actuator_target`, `configure_actuator`
- `configure_wheel`, `configure_suspension`
- `configure_seat_controls`, `set_machine_enabled`
- `set_element_name`, `configure_action_slot`

## Правила

- View-only: не звать симуляцию напрямую; только gateway read-model + `submit`.
- Обновление по dirty-сигнатуре (`structure_key` / `structure_sig` / `live_sig` /
  `bar_sig`): полный rebuild списка — только structural dirty или audit 1 с;
  иначе O(1) live-patch выбранного узла. Не упрощать и не опрашивать мир
  каждый кадр (R9).
- Публичные методы терминала (`setup`, `is_open`, `blocks_world_interact`,
  `toggle`, `open`/`close`, `try_open_on_target`, `controls_permitted`,
  `active_page_*`, `fire_slot`, `select_element`, …) — заморожены по имени.
- Сервисы: `class_name` + `static func`, первый аргумент `terminal` (без типа).
  Значения с `terminal` / его полей — только с явным типом (`var x: int = …`),
  не `:=` (цикл `class_name` ломает вывод типа).
- Обёртки на узле — только для внешних вызывающих; обёртка передаёт `self`,
  не `null`. Внутри сервиса своя логика зовётся напрямую
  (`TerminalAlarmsPanel.fill_alarms(terminal, …)`), а не через `terminal._fill_*`.
  Чужой сервис / owner — через обёртку узла (без service→service).

## Сигналы и `Callable.bind`

`Callable.bind` дописывает аргументы **после** аргументов сигнала. Поэтому
`Service.foo.bind(terminal, id)` + `gui_input(event)` вызывает
`foo(event, terminal, id)`, а не `foo(terminal, event, id)` — отсюда
`Cannot convert argument 2 from Object to Object` и мёртвые клики/поиск.

Подписываться только через методы узла с дорефакторными сигнатурами:
`terminal._on_row_input.bind(id)`, `text_changed.connect(terminal._on_search_changed)`,
`_on_click.bind(terminal._set_filter.bind(id))`. Не `Service.method.bind(terminal, …)`.

## Клик фейсплейта и пересборка

`_on_click` стреляет на **отпускание** (отличить клик от drag). Пока ЛКМ зажата
(`_faceplate_press_active`) или идёт drag/протяг слайдера — дерево фейсплейта
не пересобирать: иначе `queue_free` убивает контрол до release.

Точки входа в пересборку:

- `terminal._fill_faceplate()` ← `refresh_open` / `refresh_open_live_only`,
  `rebuild_list`, rename, optimistic patch
- `TerminalFaceplateBuilder.fill_faceplate(terminal)` ← прямые static-вызовы

Проверка жеста (`_faceplate_press_active` / `_slider_drag_active` /
`gui_is_dragging`) — в **обеих** точках, не только в `refresh()`.
`refresh` дополнительно снимает застрявший `_faceplate_press_active`, если ЛКМ
уже отпущена.

± уставок: `DragSource.click_action` на короткий клик; DnD на клавишу
сохраняется. Чипы «КОМАНДЫ» — только drag (`CONTROL-ACTIONS-V0`). «Авто/Ручн» —
декорация без обработчика.

## Обратная связь после команды

После `submit` тумблера/± нужно **оптимистично** патчить `detail` выбранного
узла (`_patch_selected_detail`) и пересобрать фейсплейт. Иначе экран держит
старое значение — кнопка выглядит мёртвой, хотя команда ушла (диагноз сессии
починки кликов).

Ловушка имён: interaction card несёт `wheel_steerable`, фейсплейт читает
`detail.steerable`. Live-patch обязан синкать из `WheelInstanceState` (или
явно маппить ключи), а не надеяться на совпадение имён.

`live_sig` включает дискретные тумблеры/уставки колеса (`steerable`,
`drive_inverted`, torque/grip/…), не только status/power.

## Долг (R9)

Сузить `live_sig` (убрать дрейф вроде `demand_w` / `battery_fraction` из
структурной пересборки) и обновлять показания точечным патчем лейблов/шкал
без `queue_free` всего фейсплейта 10 Гц.
