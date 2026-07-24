# SimulationWorld — куда смотреть

`SimulationWorld` — единственная authority (словари topology/stores, очередь
structural commands, kinematic sync). Логика разнесена по сервисам; мутации
снаружи — только через public API / typed commands, не в dicts напрямую.

## Куда идти

| Задача | Файл |
|---|---|
| place / validate / weld / damage / repair / dismantle, terrain attach | `scripts/simulation/runtime/construction_command_service.gd` |
| карта кода строительства и где тормозит (прицел → постановка → снос) | `docs/cheatsheets/construction-perf.md` |
| occupancy index, cell neighbours, joint∈component | `scripts/simulation/runtime/construction_occupancy_util.gd` |
| remove element, break rigid joint, merge assemblies | `scripts/simulation/runtime/topology_mutation_service.gd` |
| world loot piles (add/merge/collect/expire) | `scripts/simulation/runtime/world_loot_service.gd` |
| electric connect/disconnect | `scripts/simulation/runtime/industry_network_commands.gd` |
| facade: queries, command queue, motion, snapshot hooks | `scripts/simulation/simulation_world.gd` |
| snapshot capture/restore | `scripts/simulation/simulation_snapshot.gd` |
| industry tick / cargo / recipes | `scripts/simulation/industry/` |
| баланс (cost/mass/drill/actuators) | `resources/balance/game_balance.json`; `GameBalance` |
| actuators / wheels (уже вынесены) | `actuator_simulation_service.gd`, `wheel_simulation_service.gd` |

## Правила

- Сервисы — `RefCounted` + static methods; первый аргумент `world` (facade).
- Cross-service мутации topology/terrain — через `world._…` wrappers, не напрямую
  service→service (избегаем циклов class_name).
- `_notify_topology_changed(assembly_id=0)` и emit structural events остаются на
  facade. Локальный place/dismantle передаёт `assembly_id`, чтобы не сбрасывать
  body-group/occupancy/preview кэши чужих роверов.
- Store sync на place — только затронутый element (`sync_element_storage`);
  `sync_all_elements` только restore/bind.
- `CargoConnectivity` — neighbor-cell probe с каждого cargo-порта, не pairwise
  all×all. `CargoGraph.sync` пропускает edge-scan, если dirty assembly без
  cargo-портов.
- Topology flush: `clear_world_face_lookup_cache` (не immutable descriptor tables).
- Публичный API `SimulationWorld` для callers не ломать.

## Спеки

- Контракт authority: `docs/PHYSICAL-LANGUAGE.md` («Граница владения»)
- Kernel: `docs/specs/SIMULATION-KERNEL-V0.md`
