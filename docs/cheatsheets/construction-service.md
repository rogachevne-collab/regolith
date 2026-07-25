# Construction service — куда смотреть

`ConstructionCommandService` — фасад строительных команд мира. Владелец
состояния — `SimulationWorld`, приходит первым аргументом `world`. Все функции
`static`, тип `RefCounted`.

## Куда идти

| Задача | Файл / `class_name` |
|---|---|
| фасад: `place_element`, `place_driven_element`, `preview_place_element` + обёртки | `construction_command_service.gd` / `ConstructionCommandService` |
| проверки постановки (обычный блок, колесо, piston/rotor/hinge), кэш валидации архетипа, «driven path at home» | `construction_place_validation_service.gd` / `ConstructionPlaceValidationService` |
| `weld` / `damage` / `repair` / `dismantle` элемента | `construction_element_lifecycle_service.gd` / `ConstructionElementLifecycleService` |
| terrain-контакт и якоря: reconcile, probe, `construction_attach_allowed` | `construction_terrain_anchor_service.gd` / `ConstructionTerrainAnchorService` |
| occupancy index, соседние клетки, joint∈component | `construction_occupancy_util.gd` |
| где тормозит строительство (прицел → постановка → снос) | `docs/cheatsheets/construction-perf.md` |

## Граф вызовов (односторонний)

```
facade → validation → anchors
facade → anchors
facade → lifecycle
```

`ConstructionPlaceValidationService` зовёт `ConstructionTerrainAnchorService`
**напрямую**, а не через фасад — иначе получается цикл `class_name`
facade ↔ validation. Обратных рёбер быть не должно.

## Правила

- `SimulationWorld` зовёт сервис только по путям `ConstructionCommandServiceScript.*`
  (`simulation_world.gd:10` — `preload` по пути файла). Путь фасада и имена его
  публичных функций менять нельзя.
- Внешний вызывающий помимо мира: `scripts/construction_snap_resolver.gd` →
  `ConstructionCommandService.is_driven_path_at_home`.
- В фасаде на каждое вынесенное имя есть тонкая `static`-обёртка. Обёртки
  `static` — владелец приходит аргументом, `self` не нужен.
- Порядок side-effects при постановке заморожен:
  `_register_joint` → `sync_element_storage` → `bump_revision` →
  `_notify_topology_changed` → `_emit_structural_event`.
- `validate_construction_archetype` пишет кэш `world._archetype_validation_cache`
  (ключ — `get_instance_id()`, инвалидация по fingerprint) — это состояние.
- Сервисы читают приватные поля мира (`_joints`, `_allocator`,
  `_terrain_contact_probe`, `_archetype_validation_cache`, `_register_joint`,
  `_emit_element_state_changed`, `_remove_element_from_topology`) — так и задумано,
  «инкапсулировать» их в рамках нарезки нельзя.
- `world` не типизирован, поэтому `:=` для значений от него не компилируется —
  писать явный тип: `var store: SimulationResourceStore = world.get_resource_store(...)`.

## Инварианты поведения

- Блоки на транспорте никогда не якорятся к земле
  (`should_reconcile_assembly` / `record_placement_terrain_contact`), иначе ровер
  приваривается к грунту и якоря дёргаются на каждую правку террейна.
- Probe контакта может промахнуться — при пустом результате якоря не срезаются
  массово, а восстанавливаются из существующих ANCHOR-joint'ов.
- Каждый блок, поставленный на грунт, якорится сразу; факт контакта хранится на
  блоке и перепроверяется на split.
