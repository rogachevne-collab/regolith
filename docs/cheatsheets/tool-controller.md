# ToolController — куда смотреть

`ToolController` (`scripts/tool_controller.gd`) — **узел игрока**: стейт-машина
действия (`_physics_process` → `_pressed_action` → `_transition`), сборка
команды (`_emit_command_for_action`) и роутинг ввода. Мутации мира — только
через `command_requested` → `WorldCommandGateway.submit`.

Тулбар и контекстные взаимодействия вынесены в сервисы; узел держит тонкие
одноимённые обёртки, публичные сигнатуры не менялись.

## Узел vs сервисы

| Слой | Файл | Что лежит |
|---|---|---|
| узел | `scripts/tool_controller.gd` | `ACTIONS`, `CONSTRUCTION_ARCHETYPES`, `TOOLBAR_PAGES`, `TOOLBAR_SLOTS_PER_PAGE`, `SUSPENSION_SLOT`/`WHEEL_SLOT`, `construction_archetype_ids()`, сигналы, стейт-машина, `_emit_command_for_action`, `_update_toolbar_input`, `_target_for_action`, `_on_gateway_command_completed`, scoop, тросовый кластер |
| тулбар | `scripts/tool_control/tool_toolbar_service.gd` | рантайм-раскладка слотов, выбор страницы/слота, sync с инвентарём, remap API |
| контекст | `scripts/tool_control/tool_context_interaction_service.gd` | `_aim_keys`, курсор рецептов, E-контекст (лут / панели / терминалы), актуаторные нажатия |

Паттерн сервиса: `class_name … extends RefCounted`, только `static func`,
первый аргумент — нетипизированный `tool` (владелец).

## ToolToolbarService

| Обёртка на узле | Что делает |
|---|---|
| `toolbar_page_count`, `toolbar_slot_label`, `toolbar_slot_archetype_id` | read-model для HUD |
| `toolbar_slot_accepts_block`, `toolbar_slot_accepts_tool_instance` | правила drag-drop |
| `assign_slot_archetype`, `assign_slot_tool_instance` | рантайм-remap слота |
| `_change_toolbar_page`, `_apply_toolbar_slot`, `_apply_toolbar_slot_or_first_nonempty` | выбор страницы/слота |
| `_toolbar_entry`, `_canonical_toolbar_entry`, `_ensure_runtime_state`, `_resolve_rover_pair_slots` | рантайм-копия раскладки |
| `_sync_inventory_toolbar_if_needed`, `_sync_toolbar_from_inventory`, `_active_slot_resolved`, `_active_tool_is_equipped` | связка с `PlayerInventoryRegistry` |
| `_player_inventory`, `_default_orientation_for` | доступ к gateway |

- `assign_slot_archetype` мутирует **рантайм-копию** `_toolbar_layout`;
 `TOOLBAR_PAGES` — const и не мутируется (`test_construction_toolbar_remap`).
- `_sync_inventory_toolbar_if_needed` зовётся каждый физический тик и рано
 выходит по `_inventory_revision` (R9) — ранний выход не убирать.

## ToolContextInteractionService

| Обёртка на узле | Что делает |
|---|---|
| `_aim_keys` | `hit.card_keys(_simulation_world())` — база всех проверок цели |
| `selected_recipe_for_element`, `next_recipe_for_target`, `recipe_ids_for_target`, `_ensure_recipe_cursor`, `_cycle_target_recipe`, `_is_recipe_machine_hit` | курсор рецепта на элемент |
| `_try_emit_context_interaction`, `_try_open_actuator_panel`, `_try_open_wheel_panel`, `_try_open_terminal`, `_try_open_control_terminal`, `_ui_modal_blocks_world_interact`, `_is_terminal_target_hit` | что делает E по цели |
| `_try_collect_world_loot`, `_try_enqueue_target_recipe`, `_try_dequeue_target_recipe` | команды `collect_world_loot` / `enqueue_recipe` / `dequeue_recipe` |
| `_is_actuator_target_hit`, `_actuator_hit_joint_id`, `_actuator_hit_forward_velocity`, `_actuator_hit_reverse_velocity`, `_try_actuator_extend`, `_try_actuator_retract`, `_try_actuator_stop`, `_emit_actuator_target`, `toggle_actuator_motor` | +/-/Y по актуатору, `actuator_chain_sync` |

Порядок в `_try_emit_context_interaction` заморожен: лут → колесо → актуатор →
терминал → control terminal, и `control_terminal` перехватывается **до**
`toggle_control_seat` (иначе E на пульте сажает игрока в консоль).

## Тросы — вне операции

Тросовый кластер (`_handle_rope_click`, `_rope_*`, `_reset_connect_route`,
`_unhandled_input`, `rope_*`, `connect_pending_element_id`, `CONNECT_*`) живёт
в монолите и **не режется**: человек переводит его в отдельный репозиторий.
Сервисы только спрашивают владельца — `tool._is_rope_tool(tool.active_tool)`,
`tool._reset_connect_route()`.

## Правила

- Узел объявляет `class_name ToolController`, поэтому сервис **не** пишет
 `ToolController.TOOLBAR_PAGES` / `ToolController.construction_archetype_ids()`
 — только через владельца (`tool.TOOLBAR_PAGES`,
 `tool.construction_archetype_ids()`). Иначе цикл `class_name`.
- Обёртки на узле — **не** `static`: в статической функции нет `self`.
- Значения от нетипизированного `tool` — явный тип, не `:=`
 (`var registry: PlayerInventoryRegistry = ...`).
- Сигналы эмитятся через владельца: `tool.command_requested.emit(...)`,
 `tool.construction_selection_changed.emit(...)`, `tool.active_tool_changed`,
 `tool.toolbar_layout_changed`. Подписки (`command_requested.connect`,
 `command_completed.connect`) остаются в `_ready` узла.
- Внешние вызывающие, которые ломать нельзя: `construction_archetype_ids()` —
 `world_command_gateway.gd`, `terrain_anchor_probe.gd`, `hud_palette.gd`;
 `TOOLBAR_SLOTS_PER_PAGE` — `hud_toolbar.gd`; `TOOLBAR_PAGES[0][3]` —
 `test_construction_toolbar_remap.gd`.
