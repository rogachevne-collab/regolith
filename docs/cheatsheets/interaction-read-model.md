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
| Index (Phase 1) | `scripts/simulation/runtime/interaction_index.gd` |
| Structure POD | `scripts/simulation/runtime/interaction_structure.gd` |
| Card (Phase 2) | `scripts/simulation/runtime/interaction_card.gd` |
| API / restore | `scripts/simulation/simulation_world.gd` (`get_interaction_card`, `driven_joint_for_element`, …) |
| Thin query (Phase 2) | `scripts/interaction_query.gd` |
| Actuator pose push (Phase 2c+) | `scripts/simulation/runtime/actuator_simulation_service.gd` |
| Industry display (Phase 2b+) | industry runtime + `recipe_runner_service.gd` |
| HUD readers | `scripts/ui/hud_*.gd` (keys from card flatten; cargo HUD → 2b) |
| Kernel test | `scripts/test_interaction_index.gd` / `scenes/test_interaction_index.tscn` |

Phase 1–2c landed: index + card + thin Query; industry writes `display_*`
on tick; actuators push DisplayPose (≤ `DISPLAY_POSE_HZ`, stop/status flush).
Aim/card only read. K-terminal full snapshot → Phase 3 dirty-signature.

## Triage

| Симптом | Куда смотреть |
|---|---|
| В seat / без build: небо OK, прицел в блок ровера → FPS падает | Регрессия thin Query / card. **Не** ConstructionPreview |
| Лаг только в build mode с превью-призраком | `docs/cheatsheets/construction-perf.md` §49 |
| Aim в head поршня «нет actuator» / кривая поза | dual-endpoint `driven_joint` + DisplayPose push |
| После load кривые joint/поза | `clear_interaction_index` на restore |
| Лаг только на processor/fabricator | industry `display_*` writer на тике, не graph в card |
| K-пульт открыт → FPS падает | `control_terminal_snapshot` / Phase 3, не aim card |

## Запреты на aim path

- `world.list_joints()`
- linear `find_*_joint_for_element`
- `connected_supply_amount` / cargo graph в `IndustryStatusUtil` на aim

## Константы

- `DISPLAY_POSE_HZ = 10` (pose write cap while moving; stop/status — сразу)
