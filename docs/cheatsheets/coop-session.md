# CoopSession — куда смотреть

`scripts/coop/coop_session.gd` — ENet transport, peer registry, pose relay,
snapshot re-broadcast, console `host`/`join`/`leave`, gateway client hook.
Спека: `docs/specs/COOP-HOST-V0.md`.

## Монолит vs сервисы

| Слой | Файл | Что лежит |
|---|---|---|
| узел | `scripts/coop/coop_session.gd` | `@export` / state vars, `@rpc` (тонкие обёртки), join/leave orchestration, host hooks/teardown, setup (sandbox/instance lock) |
| state sync | `scripts/coop/coop_state_sync_util.gd` | suit + store broadcast/apply, wire cache (`_last_store_revision`, buffers, inventories, industry runtimes) |
| pose relay | `scripts/coop/coop_pose_relay_util.gd` | `_local_pose`, `_pose_position`, `_tangent_offset`, cold pose export/seed |
| assembly pack | `scripts/coop/coop_assembly_motion_util.gd` | pack/unpack motion stream entries, wheel scalars, `_motion_is_live` |
| dig relay | `scripts/coop/coop_dig_relay_util.gd` | guest dig soft-retry, pending join replay, `dig_ops` ring truncate |
| snapshot | `scripts/coop/coop_snapshot_broadcast_util.gd` | `_mark_snapshot_dirty`, `_tick_snapshot_broadcast` debounce/floor |
| join | `scripts/coop/coop_join_service.gd` | host terrain bulk prep/send, `_seed_joiner`, client `_apply_join` / terrain bulk / roster / reseat |
| assembly stream | `scripts/coop/coop_assembly_stream_service.gd` | motion broadcast/ingest/blend, ghost wheels, physics ownership, owner upload |
| command route | `scripts/coop/coop_command_route_service.gd` | guest submit routing, pending results, `_cli_result` seat attach, host command_completed → dirty |
| seat control | `scripts/coop/coop_seat_control_relay_util.gd` | client control input tick, `_srv_control_input`, driver watchdog/clear, force-release notify |
| avatars | `scripts/coop/coop_avatar_service.gd` | spawn/despawn avatar, pose inbox flush |
| console | `scripts/coop/coop_session_console_util.gd` | `host`/`join`/`leave`/`nick`/`coop_status`, nick load/save, cmdline autohost/autojoin |

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
| `_broadcast_assembly_motion` / `_cli_assembly_motion` / `_srv_assembly_motion` / `_ingest_assembly_motion_batch` / `_sync_ghost_wheel_kernel_motions` / `_tick_assembly_stream_blend` / `_apply_assembly_blend` / `_apply_observer_wheel_scalars` / `_forget_observer_assembly` / `_write_blended_body_pose` / `_commit_streamed_assembly_pose` / `_begin_local_driver_physics` / `_end_local_driver_physics` / `_host_update_physics_ownership_from_seat` / `_set_remote_physics_owner*` / `_clear_remote_physics_owner*` / `_tick_local_owner_motion_upload` | `CoopAssemblyStreamService` |
| `_on_local_submit` / `_srv_submit` / `_cli_result` / `_on_host_command_completed` / `_route_guest_submit` | `CoopCommandRouteService` |
| `_tick_client_control_input` / `_client_seat_replica_ok` / `_srv_control_input` / `_notify_remote_seat_force_release` / `_cli_force_seat_release` / `_tick_remote_driver_watchdog` / `_clear_remote_driver` | `CoopSeatControlRelayUtil` |
| `_spawn_avatar` / `_flush_pose_inbox_to` / `_despawn_avatar` | `CoopAvatarService` |
| `_load_nick` / `_save_nick` / `_kickoff_cmdline_autostart` / `_await_world_ready` / `_autohost_when_ready` / `_autojoin_when_ready` / `_cmd_host` / `_cmd_join` / `_cmd_leave` / `_cmd_nick` / `_cmd_coop_status` | `CoopSessionConsoleUtil` |

## Что остаётся в монолите

| Блок | Почему |
|---|---|
| Join/leave / hello / terrain bulk | orchestration + `@rpc` (bodies → `CoopJoinService`) |
| Host hooks / teardown | lifecycle wiring, gateway signal connects |
| Setup (sandbox, instance lock) | runs before bootstrap, not extracted |
| `resolve_seat_world_transform` | Callable identity for RemotePlayer resolver |
| Pose relay `@rpc` (`_srv_pose`, `_cli_pose`) | thin relay on node |
| Snapshot apply (`_cli_apply_snapshot`) | client rebind after restore |

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
| `test_coop_rope_projection` | assembly stream / projection seam |
