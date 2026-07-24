# Interaction Read-Model — шпаргалка

Контракт: `docs/specs/PLAYER-INTERACTION-V1.md` § **Interaction Read-Model**.
Не путать с construction preview (`docs/cheatsheets/construction-perf.md`).

## Суть

Сборка владеет карточкой элемента. Прицел только читает.

```text
ray → element_id
  → world.get_interaction_card(element_id)   # O(1)
  → HUD / tools
```

Structural index патчится/инвалидируется на place/dismantle/split/restore.
Actuator сам пушит позу (change + max 10 Hz). Industry пишет `display_*` на
своём тике. Aim не сканирует joints и не ходит в cargo graph.

## Карта файлов (целевая)

| Роль | Путь |
|---|---|
| Контракт | `docs/specs/PLAYER-INTERACTION-V1.md` § Interaction Read-Model |
| Index (Phase 1+) | `scripts/simulation/runtime/interaction_index.gd` |
| API / restore | `scripts/simulation/simulation_world.gd` |
| Thin query (Phase 2+) | `scripts/interaction_query.gd` |
| Actuator pose push (Phase 2c+) | `scripts/simulation/runtime/actuator_simulation_service.gd` |
| Industry display (Phase 2b+) | industry runtime + `recipe_runner_service.gd` |
| HUD readers | `scripts/ui/hud_*.gd` |
| Kernel test | `scripts/test_interaction_index.gd` |

До внедрения index: сегодняшний hotspot — `InteractionQuery._target_metadata`
→ `*PlacementUtil.enrich_*` → `world.list_joints()`.

## Triage

| Симптом | Куда смотреть |
|---|---|
| В seat / без build: небо OK, прицел в блок ровера → FPS падает | Этот read-model / `_target_metadata` / `list_joints`, **не** ConstructionPreview |
| Лаг только в build mode с превью-призраком | `docs/cheatsheets/construction-perf.md` §49 |
| Aim в head поршня «нет actuator» | dual-endpoint `driven_joint` index |
| После load кривые joint/поза | `clear_interaction_index` на restore |
| Лаг только на processor/fabricator | industry `display_*`, не joint scan |

## Запреты на aim path

- `world.list_joints()`
- linear `find_*_joint_for_element`
- `connected_supply_amount` / cargo graph в `IndustryStatusUtil` на aim

## Константы

- `DISPLAY_POSE_HZ = 10` (pose write cap while moving; stop/status — сразу)
