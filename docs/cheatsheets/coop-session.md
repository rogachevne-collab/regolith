# CoopSession — куда смотреть

`scripts/coop/coop_session.gd` — ENet transport, peer registry, pose relay,
snapshot re-broadcast, console `host`/`join`/`leave`, gateway client hook.
Спека: `docs/specs/COOP-HOST-V0.md`.

## Монолит vs сервисы

| Слой | Файл | Что лежит |
|---|---|---|
| узел | `scripts/coop/coop_session.gd` | `@export` / state vars, `@rpc` (тонкие обёртки), join/leave, command routing, assembly ingest/blend, avatars/teardown |
| state sync | `scripts/coop/coop_state_sync_util.gd` | suit + store broadcast/apply, wire cache (`_last_store_revision`, buffers, inventories, industry runtimes) |
| pose relay | `scripts/coop/coop_pose_relay_util.gd` | `_local_pose`, `_pose_position`, `_tangent_offset`, cold pose export/seed |
| assembly pack | `scripts/coop/coop_assembly_motion_util.gd` | pack/unpack motion stream entries, wheel scalars, `_motion_is_live` |
| dig relay | `scripts/coop/coop_dig_relay_util.gd` | guest dig soft-retry, pending join replay, `dig_ops` ring truncate |
| snapshot | `scripts/coop/coop_snapshot_broadcast_util.gd` | `_mark_snapshot_dirty`, `_tick_snapshot_broadcast` debounce/floor |
| join | `scripts/coop/coop_join_service.gd` | host terrain bulk prep/send, `_seed_joiner`, client `_apply_join` / terrain bulk / roster / reseat |

Паттерн сервиса: `class_name … extends RefCounted`, только `static func`, первый
аргумент нетипизированный `session` (узел `CoopSession`). Значения с `session` /
его полей — **явный тип**, не `:=`. Комментарии/инварианты переносятся дословно.

## `@rpc` — остаются на узле

Все `@rpc` методы (`_srv_*`, `_cli_*`) — тонкие обёртки на `CoopSession`.
Сервисы могут вызывать `session.rpc(...)` для broadcast-путей; side-effect order
не менять.

## Тонкие обёртки → сервис

| Метод на узле | сервис |
|---|---|
| `_broadcast_suits` / `_cli_suits` | `CoopStateSyncUtil` |
| `_broadcast_stores` / `_compute_store_broadcast_payload` / `_cli_stores` / `_clear_store_wire_cache` | `CoopStateSyncUtil` |
| `export_cold_poses` / `_seed_last_poses_from_cold` / `_local_pose` / `_pose_position` / `_tangent_offset` | `CoopPoseRelayUtil` |
| `_pack_assembly_motion_entry` / `_wheel_group_ids` / `_pack_wheel_scalars` / `_unpack_assembly_stream_entry` / `_motion_is_live` | `CoopAssemblyMotionUtil` |
| `_should_soft_retry_guest_dig` / `_tick_guest_dig_retries` / `_tick_pending_dig_reapply` | `CoopDigRelayUtil` |
| `_on_host_command_executed` → ring append | `CoopDigRelayUtil.append_dig_op` |
| `_mark_snapshot_dirty` / `_tick_snapshot_broadcast` | `CoopSnapshotBroadcastUtil` |
| `_prepare_join_terrain_bulk` / `_send_terrain_bulk_chunks` / `_seed_joiner` / `_apply_join` / `_apply_join_terrain_bulk` / `_replay_fallback_dig_ops` / `_wait_terrain_bulk_chunks` / `_clear_terrain_bulk_state` / `_spawn_join_roster_avatars` / `_finish_apply_join` | `CoopJoinService` |

## Что остаётся в монолите

| Блок | Почему |
|---|---|
| Join/leave / hello / terrain bulk | orchestration + `@rpc` (bodies → `CoopJoinService`) |
| Command submit / `_route_guest_submit` | gateway hook + pending results |
| Assembly motion broadcast/ingest/blend | следующая волна extract |
| Seat control stream | отдельный кластер |
| Avatars / teardown / host hooks | lifecycle |

## Соседние модули (не extract'ы)

| Файл | Роль |
|---|---|
| `coop_command_codec.gd` | wire codec, handshake, dig op shape |
| `coop_peer_registry.gd` | host peer table |
| `coop_terrain_bulk.gd` | join sqlite chunking |
| `remote_player.gd` | avatar presentation |

## Тесты

| Сцена | Что трогает |
|---|---|
| `test_coop_codec` | codec |
| `test_coop_bug_regressions` | `_prepare_join_terrain_bulk`, `_compute_store_broadcast_payload` (обёртки на узле) |
| `test_coop_dig_replay` | dig relay |
| `test_coop_seat` | seat / owner-sim |
