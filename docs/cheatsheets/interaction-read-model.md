# Interaction Read-Model — шпаргалка

Контракт: `docs/specs/PLAYER-INTERACTION-V1.md` § **Interaction Read-Model**.
Не путать с construction preview (`docs/cheatsheets/construction-perf.md`).

**Статус: landed / closed** (Phases 0–4).

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

## Карта файлов

| Роль | Путь |
|---|---|
| Контракт | `docs/specs/PLAYER-INTERACTION-V1.md` § Interaction Read-Model |
| Index | `scripts/simulation/runtime/interaction_index.gd` |
| Structure POD | `scripts/simulation/runtime/interaction_structure.gd` |
| Card | `scripts/simulation/runtime/interaction_card.gd` |
| API / restore | `scripts/simulation/simulation_world.gd` (`get_interaction_card`, `driven_joint_for_element`, …) |
| Thin query | `scripts/interaction_query.gd` |
| Actuator pose push | `scripts/simulation/runtime/actuator_simulation_service.gd` |
| Industry display | industry runtime + `recipe_runner_service.gd` |
| HUD readers | `scripts/ui/hud_*.gd` (`hit.card_keys(world)`, not Hit flatten) |
| Kernel test | `scripts/test_interaction_index.gd` / `scenes/test_interaction_index.tscn` |

Landed: index + card + thin Query/Hit; industry `display_*`; actuator DisplayPose
push; HUD/terminal dirty-signature; Hit typed fields + card-only readers.

## Invariant

### Forbidden on aim / HUD / terminal / card read path

- `world.list_joints()`
- linear `find_*_joint_for_element` (use `driven_joint_for_element`)
- `enrich_interaction_metadata` / placement-util enrich (API removed)
- `connected_supply_amount` / cargo graph walks in `IndustryStatusUtil` on aim

### Allowed `list_joints` owners (out of this rework)

- impact / physics projection helpers
- `SimulationSnapshot` / restore authoring
- kernel tests, machine validators, one-shot authoring tools

Assembly-scoped scans → `iter_joints_for_assembly`, not full sorted `list_joints`.

Code anchors: `InteractionQuery`, `ControlTerminalSnapshotBuilder`,
`SimulationWorld.list_joints()` doc comment.

## Triage

| Симптом | Куда смотреть |
|---|---|
| В seat / без build: небо OK, прицел в блок ровера → FPS падает | Регрессия thin Query / card. **Не** ConstructionPreview |
| Лаг только в build mode с превью-призраком | `docs/cheatsheets/construction-perf.md` §49 |
| Aim в head поршня «нет actuator» / кривая поза | dual-endpoint `driven_joint` + DisplayPose push |
| После load кривые joint/поза | `clear_interaction_index` на restore |
| Лаг только на processor/fabricator | industry `display_*` writer на тике, не graph в card |
| K-пульт открыт → FPS падает | `hud_control_terminal` dirty-signature / full audit; не aim card |

## Константы

- `DISPLAY_POSE_HZ = 10` (pose write cap while moving; stop/status — сразу)
