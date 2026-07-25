# WorldCommandGateway — куда смотреть

`WorldCommandGateway` — **роутер** шины команд и тонкие обёртки публичного API.
Мутации симуляции — только через `submit` / `submit_as` → `_flush` → `_execute`
(match по `kind` остаётся на gateway; тела обработчиков — в сервисах).
Read-model не мутирует state (кроме существующих ensure-* side-effects в inventory).

## Роутер vs сервисы

| Слой | Файл | Что лежит |
|---|---|---|
| шина | `scripts/world_command_gateway.gd` | `submit` / `submit_as` / `_flush` / `_execute` (27 kind), `complete_remote`, `replay_remote_dig`, сигналы, seat-**состояние** + evict-хук, `_result` / `_structural_result`, тонкие обёртки |
| dig / terrain | `scripts/gateway/gateway_terrain_dig_service.gd` | carve/scoop/dump, hand drill, stationary drill, dozer blade, floating chunks |
| machine | `scripts/gateway/gateway_machine_command_service.gd` | network/transfer/recipes/actuators/wheels/hotbar/oxygen/damage |
| construction | `scripts/gateway/gateway_construction_service.gd` | preview/place/weld/dismantle/snap/ground seat |
| read-model | `scripts/gateway/gateway_read_model_service.gd` | carry, stores, power, control terminal, inventory, map overlay |
| seat / locomotion | `scripts/gateway/gateway_seat_locomotion_service.gd` | вход/выход в ControlSeat, per-tick driver input, coop remote-driver поток, client seat attach, PB, wake, power-prep |

Паттерн сервиса: `class_name … extends RefCounted`, только `static func`, первый
аргумент нетипизированный `gateway` (без цикла `class_name`). Значения с
`gateway` / его полей — **явный тип**, не `:=`.

## kind → сервис → функция

| kind | gateway-обёртка | сервис | функция |
|---|---|---|---|
| `voxel_remove` | `_remove_voxel` | `GatewayTerrainDigService` | `_remove_voxel` |
| `dig_terrain_debris` | `_dig_terrain_debris` | `GatewayTerrainDigService` | `_dig_terrain_debris` |
| `scoop_spoil` | `_scoop_spoil` | `GatewayTerrainDigService` | `_scoop_spoil` |
| `dump_scoop` | `_dump_scoop` | `GatewayTerrainDigService` | `_dump_scoop` |
| `debug_spawn_spoil` | `_debug_spawn_spoil` | `GatewayTerrainDigService` | `_debug_spawn_spoil` |
| `damage_element` | `_damage_element` | `GatewayMachineCommandService` | `_damage_element` |
| `place_block` | `_place_block` | `GatewayConstructionService` | `_place_block` |
| `toggle_control_seat` | `_toggle_control_seat` | `GatewaySeatLocomotionService` | `_toggle_control_seat` |
| `construction_apply` | `_construction_apply` | `GatewayConstructionService` | `_construction_apply` |
| `weld_element` | `_weld_element` | `GatewayConstructionService` | `_weld_element` |
| `dismantle_element` | `_dismantle_element` | `GatewayConstructionService` | `_dismantle_element` |
| `transfer_resource` | `_transfer_resource` | `GatewayMachineCommandService` | `_transfer_resource` |
| `assign_hotbar_instance` | `_assign_hotbar_instance` | `GatewayMachineCommandService` | `_assign_hotbar_instance` |
| `connect_network` | `_connect_network` | `GatewayMachineCommandService` | `_connect_network` |
| `disconnect_network` | `_disconnect_network` | `GatewayMachineCommandService` | `_disconnect_network` |
| `set_machine_enabled` | `_set_machine_enabled` | `GatewayMachineCommandService` | `_set_machine_enabled` |
| `oxygen_refill` | `_oxygen_refill` | `GatewayMachineCommandService` | `_oxygen_refill` |
| `set_element_name` | `_set_element_name` | `GatewayMachineCommandService` | `_set_element_name` |
| `enqueue_recipe` | `_enqueue_recipe` | `GatewayMachineCommandService` | `_enqueue_recipe` |
| `dequeue_recipe` | `_dequeue_recipe` | `GatewayMachineCommandService` | `_dequeue_recipe` |
| `collect_world_loot` | `_collect_world_loot` | `GatewayMachineCommandService` | `_collect_world_loot` |
| `set_actuator_target` | `_set_actuator_target` | `GatewayMachineCommandService` | `_set_actuator_target` |
| `configure_actuator` | `_configure_actuator` | `GatewayMachineCommandService` | `_configure_actuator` |
| `configure_wheel` | `_configure_wheel` | `GatewayMachineCommandService` | `_configure_wheel` |
| `configure_suspension` | `_configure_suspension` | `GatewayMachineCommandService` | `_configure_suspension` |
| `configure_action_slot` | `_configure_action_slot` | `GatewayMachineCommandService` | `_configure_action_slot` |
| `configure_seat_controls` | `_configure_seat_controls` | `GatewayMachineCommandService` | `_configure_seat_controls` |

## Публичные API-обёртки (не kind)

| Метод на gateway | сервис |
|---|---|
| `apply_terrain_carve`, `mark_terrain_deposited`, `stationary_drill_*`, `carve_stationary_drill`, `dozer_blade_*` | `GatewayTerrainDigService` |
| `apply_damage`, `apply_transfer_resource`, `apply_connect_network`, `apply_connect_rope` | `GatewayMachineCommandService` |
| `preview_construction`, `baseline_ground_pivot`, `resolve_construction_placement`, `snap_*`, `reset_construction_snap` | `GatewayConstructionService` |
| `player_carry_load`, `resource_store`, `store_snapshot`, `vehicle_power_snapshot`, `control_terminal_*`, `player_inventory*`, `construction_archetype`, `archetype_display_name`, `map_overlay_entries` | `GatewayReadModelService` |
| `force_eject_seat_occupant`, `is_rover_seated`, `get_local_seat_element_id`, `is_local_seat_driver`, `tick_rover_locomotion_input`, `collect_seat_raw_input`, `apply_remote_driver_input`, `clear_remote_driver_input`, `apply_local_seat_attach`, `ensure_local_seat_binding`, `release_local_seat_attach` | `GatewaySeatLocomotionService` |

`replay_remote_dig` остаётся на gateway (coop-вход); внутри зовёт dig-обёртки
(`_remove_voxel` / `_scoop_spoil` / `_dump_scoop`).

## Seat / locomotion — что осталось на узле

Сервис — `GatewaySeatLocomotionService`, но узел держит всё, что нельзя
переносить:

| На gateway | Почему |
|---|---|
| `_rover_seat_player`, `_rover_seat_assembly_id`, `_rover_seat_element_id`, `_rover_seat_passenger`, `_rover_seat_policy` | состояние; `GatewayMachineCommandService` и `GatewayReadModelService` читают/пишут поля напрямую. Сервис присваивает через `gateway._rover_seat_*` |
| `_seat_force_release_notify`, `set_seat_force_release_notify`, `_seat_evict_hook_connected` | coop-хук, ставится снаружи |
| `_bind_seat_evict_hook`, `_on_seat_occupant_evicted` | `call_deferred` из `_ready` + цель `world.seat_occupant_evicted.connect` — identity Callable ломать нельзя |
| `is_passenger_seat_archetype` | единственная реально статическая функция кластера; сервис зовёт её по имени на `gateway` (ссылка на `WorldCommandGateway` из сервиса дала бы цикл `class_name`) |
| `_execute` (`toggle_control_seat`), `_result`, `_target_card_keys` | роутер |

`_rover_seat_policy` — **разделяемая ссылка** на `SeatControlState` (R9, без
per-tick дублирования): сервис не держит локальную копию.

`FLIGHT_LOOK_SENSITIVITY` переехала в сервис вместе с `_consume_flight_look_delta`
(внешних читателей константы нет).

Порядок в coop-потоке 20 Гц (`apply_remote_driver_input`) заморожен:
edges → `SeatInputRouter.route` → `apply_driver_frame` → `_seat_frame_should_wake`.

## Правила

- Публичные сигнатуры методов gateway не ломать: HUD, `tool_controller`, coop зовут их по имени.
- Порядок и набор 27 `kind` в `_execute` заморожены (`ANTIGOD-CONTRACT-FREEZE.md`).
- Форма результата: `{ status: &"ok"|&"failed", reason, data }` — не трогать.
- Мутации — только через команды (`submit` / `submit_as`), не из read-model.
- Обёртки на узле — **никогда** не `static`: в статической функции нет `self`,
  в сервис уедет `null`.
- Подписки на сигналы — только методами узла, не `Service.method.bind(gateway)`:
  `Callable.bind` дописывает аргументы ПОСЛЕ аргументов сигнала.
