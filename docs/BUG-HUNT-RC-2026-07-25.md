# MEGA BUG REPORT — RC hunt 2026-07-25

Сводка 8 read-only hunt-агентов (coop, physics, industry, voxel/dig, HUD, kernel, perf, authoring).
**На момент снимка hunt — ничего не фикшено и не закоммичено.** Документ — рабочий бэклог для постепенного триажа; актуальные правки сессии — в **«Статус прогона»** ниже.

> **Область охвата.** RT (`world_rt_geometry`, viewmodel RT) и day/night исключены из этого прохода
> по запросу — упомянуты только там, где всплыли как побочный перф-эффект (`PERF-H04`).
> Балансовые тесты мог править отдельный fixer-агент; строки `IND-04/05/13`, `CMP-05/06`
> сверить с актуальным `resources/balance/game_balance.json` перед работой.

> **Природа находок.** Всё получено статическим анализом кода и спек. Ни одна находка не
> воспроизведена в запущенной игре. Поле **Repro** — это *гипотеза воспроизведения*, а не
> подтверждённый сценарий. Метки: `[R7]` — требует сверки с докой/issues Voxel Tools,
> `[R8]` — требует сверки с докой Godot Jolt, `[спек]` — расхождение кода и спеки,
> `[?]` — высокая доля спекуляции, сначала подтвердить.

## Статус прогона 2026-07-25 (после adversarial + dual smoke + domain verify)

**Сводный отчёт верификации всех 103 ID:** [`docs/_verify/MASTER.md`](_verify/MASTER.md)

Grand totals (primary verdict): **83 CONFIRMED** · **1 FALSE ALARM** (KRN-11) · **7 PARTIAL** ·
**3 NEEDS_PLAYTEST** (DIG-09/10, PHY-13) · **7 FIXED** (DIG-01/02/03, COOP-04/05, IND-01/02) ·
**2 OUT_OF_SCOPE** (IND-14, PERF-H04) + uncataloged **rope_path FIXED**. Orphans: **0** — каждый
ID покрыт одним из `docs/_verify/{DIG-COOP,KRN,PHY,IND,UI,PERF-REST-PASS2}.md`.

- **FIXED сессии (production):** **DIG-01/02/03, COOP-04/05** — batch-fix agent d67c5dbf;
  `test_coop_bug_regressions` **PASS**, добавлен в KERNEL gate (`run_tests.sh`).
- **FIXED ранее в сессии:** **IND-01/02** (`test_industry_v1` green); **rope_path** guest spam
  (`test_coop_rope_projection` в KERNEL) — см. MASTER §6.
- **Hard list:** S0 блок (DIG-01/02/03, COOP-04/05) снят — все пять **FIXED**. Следующий
  приоритет по TL;DR §2: **KRN-01/02/03**.
- Строки каталога §3.1–§3.8 по-прежнему `open` — статус верификации см. MASTER §11.
- **Dual-process smoke:** грязный host dig sqlite → **425 MiB** bulk; после
  `clear_moon_progress`: welcome ~26 s, bulk ~44 MiB, 0 SCRIPT ERROR.
- Большинство CONFIRMED = механизм в коде подтверждён статанализом, не in-game repro
  (кроме отмеченных smoke/probe). RT/day-night по-прежнему out of scope.

---

## 1. Severity legend

| Sev | Ярлык | Смысл |
|---|---|---|
| **S0** | crit | Потеря данных игрока / невозможность играть коопом / красный контракт в спеке |
| **S1** | high | Устойчивый рассинхрон, эксплойт, заметная поломка ключевого лупа |
| **S2** | med | Продуктовый дефект, edge-рассинхрон, UX-поломка, тупик в геймплее |
| **S3** | low | Долг, шум, косметика, «сейчас замаскировано» |

Маппинг с оригинальными агентами: `crit → S0`, `high → S1`, `med/medium → S2`, `low → S3`.
Агенты coop и physics нумеровали свои S1/S2/S3 по той же шкале.

**Status у всех записей — `open`.**

---

## 2. TL;DR — топ-10 к починке первыми (coop RC / играбельность)

| # | ID | Sev | Почему первым |
|---|---|---|---|
| 1 | **DIG-01** | S0 | Late join получает stale SQLite → холодные копки просто исчезают у гостя. Корень контракта flush/mark. |
| 2 | **DIG-02** | S0 | Тот же контракт с другой стороны: digs во время flush уезжают и в БД, и в tail → **double-carve**, битый SDF. |
| 3 | **DIG-03** | S1 | Таймаут чанков `terrain_bulk` + tail-only `dig_ops` = late join без пещер. Нет фолбэка. |
| 4 | **COOP-04** | S1 | Live `_cli_dig_op` при провале replay молча дропается (join-путь ретраит). Постоянный terrain desync гостя. |
| 5 | **COOP-05** | S1 | Стор/хотбар: optimistic cache на `unreliable_ordered` → HUD «замерзает» до следующего изменения. |
| 6 | **KRN-01** | S1 | Осиротевший redirect после erase survivor → `capture_snapshot` невалиден → join и save падают. |
| 7 | **KRN-02** | S1 | `restore_snapshot` не бампает `topology_generation` → preview-кэш клиента бьёт по устаревшему плану. |
| 8 | **KRN-03** | S1 | `structural_batch_committed` не слушают projection/industry → после compose хост не обновляет физику/визуал. |
| 9 | **PHY-01 + PHY-02** | S1 | Partial thaw по верёвке + root-only gate «assembly frozen» → «статуя с живыми колёсами», неконсистентный тик. |
| 10 | **UI-02 + UI-03** | S1 | Seat-гейт тулов смотрит только `is_in_vehicle()`, а `passenger:true` не проверяет архетип → копка из кресла / PAX на кокпите. |

Отдельно, вне coop-RC, но **известный красный контракт**: `IND-01/IND-02` — rope/`cable_stake`
не выживает snapshot round-trip (`test_industry_v1` красный, задокументировано в `ROPE-CHAIN-V0`).

---

## 3. Полный каталог

### 3.1 Terrain / dig / join-передача рельефа — `DIG-*`
Слито из voxel-агента (`D1…D15`) и coop-агента (`COOP-01/02/03/08/11`) — пересечения объединены.

| ID | Sev | Title | Area | Evidence | Repro (гипотеза) | Status |
|---|---|---|---|---|---|---|
| **DIG-01** | S0 | `flush_digs_for_coop_join` — no-op при уже идущем persist → stale SQLite | join / persist | `bootstrap.gd:162-167,743-745`; `coop_session.gd:508-518` <br>*(D1 + COOP-02)* | Гость join'ится во время autosave-flush: `_persist_digs_durable` сразу `return` из-за `_dig_persist_in_flight`; `capture_coop_terrain_bulk` читает файл без свежих дыр, `dig_ops` = только post-mark tail. Второй hello подряд — flush пустой. | open |
| **DIG-02** | S0 | Digs во время flush попадают и в SQLite, и в `dig_ops` tail → double-carve | join / dig replay | `coop_session.gd:508-518`; `bootstrap.gd:754-776`; `coop_terrain_bulk.gd:95-103` <br>*(D3 + COOP-01)* | Копать на хосте, пока ждётся `flush_digs_for_coop_join`: dirty-loop дописывает блоки в БД, те же ops уходят в `slice(mark)` → клиент режет дважды. `[?]` если VT не успевает подхватить in-flight digs — будет наоборот недокопка. | open |
| **DIG-03** | S1 | Chunked `terrain_bulk` timeout → cold holes lost (нет фолбэка на full `dig_ops`) | join / transport | `coop_session.gd:515-518,660-683,686-699`; `coop_terrain_bulk.gd:95-103` <br>*(D2 + COOP-03)* | Host видит non-empty sqlite → `dig_ops` = tail. Клиент не собирает чанки за 120 s → bulk skip, cold ops в payload уже нет → late join без пещер. На LAN редко, на Tailscale/lossy — реально. | open |
| **DIG-04** | S1 | Path-sweep на хосте vs lone-sphere на replay → under-carve; тест закрепляет расхождение | dig replay | `world_command_gateway.gd:440-483`; `test_coop_dig_replay.gd:588-716`; `COOP-HOST-V0.md:511-513` <br>*(D4)* | Непрерывный бур A→B: host делает path-sweep, `replay_remote_dig` — нет. Acceptance-тест **фиксирует** меньший объём у клиента, т.е. рассинхрон канала легитимизирован. | open |
| **DIG-05** | S2 | Dig save timeout → неполный SQLite всё равно flush/capture `[R7]` | persist | `bootstrap.gd:172-176,758-774` <br>*(D5)* | Массовая копка + quit/join при >15 s `save_modified_blocks`: warning, `flush()`, файл уходит в bulk/reload с дырами в стенах пещер. Сверить семантику `VoxelSaveCompletionTracker` / abort. | open |
| **DIG-06** | S2 | Fail записи replica DB рвёт и granular restore | persist | `bootstrap.gd:187-223` <br>*(D6)* | `FileAccess.open(replica)` fail → `return false` до `restore_field_snapshot` → нет ни cold digs, ни spoil heaps. | open |
| **DIG-07** | S2 | Scoop-объём теряется на границе regions | granular | `granular_voxel_world.gd:894-910` <br>*(D10)* | Куча на стыке двух regions: `scoop_spoil` берёт первый covering `dig_at` и `return` → вторая половина сферы не собирается, capacity недозаполнен. | open |
| **DIG-08** | S2 | `_exit_tree` dig save без `await`/`flush` | persist | `bootstrap.gd:361-370` <br>*(D11)* | Stop в редакторе / kill процесса: `save_modified_blocks()` fire-and-forget → последние digs теряются при reload. | open |
| **DIG-09** | S2 | Spawn settle timeout / pad retire → провал сквозь кору `[R7]` | spawn (R5) | `bootstrap.gd:14-22,817-831,1508-1563`; `player_controller.gd:194-204` <br>*(D12)* | Collider >8 s → landing pad; settle на pad; retire pad при другом Y voxel floor / timeout-snap с exclude pad → падение сквозь кору. Сверить collider lag (VT #676/#677). | open |
| **DIG-10** | S2 | Viewer kick после stream swap может не перечитать dig blocks `[R7]` | streaming | `bootstrap.gd:209-233` <br>*(D9)* | После `lod.stream = replica` только toggle `view_distance` → клиент видит virgin generator crust, пока не отойдёт/не перезагрузит. Сверить hot-swap stream + viewer invalidate. | open |
| **DIG-11** | S2 | Pending join `dig_ops` ретраятся без TTL/cap `[R7]` | join / dig replay | `coop_session.gd:643-655,1571-1594` <br>*(D8 + COOP-11)* | Join-replay fail (chunk not editable) → очередь навсегда, попытки 2 Hz; дыра не появится, если stream не подтянет блок. Шум/CPU, не краш. | open |
| **DIG-12** | S3 | `MAX_DIG_OPS = 8192` ring drop-oldest без покрытия cold bulk | join / history | `coop_session.gd:869-878,96-98`; `coop_terrain_bulk.gd:100-101` <br>*(D13 + COOP-08)* | >8192 session digs без нового join-flush + пустой/отсутствующий sqlite → late joiner без старых ops (warning есть). Маловероятно в коротком playtest. | open |
| **DIG-13** | S3 | `raycast_hit_world_distance` делит на scale — контракт не из доки `[R7]` | aim / SDF | `voxel_space_util.gd:186-200`; `docs/cheatsheets/voxel-tools.md:36-41` <br>*(D14)* | При scale≠1 aim/spawn SDF-hit съезжает, если `hit.distance` уже в world-единицах. Сейчас `scale = 1.0` маскирует. Сверить units у `VoxelTool.raycast`. | open |
| **DIG-14** | S3 | Спека говорит `do_path`, код — sphere-sweep (обход VT assert) `[R7][спек]` | dig / долг | `world_command_gateway.gd:453-455`; `INDUSTRY-V1.md:769-772` <br>*(D15)* | `do_path` падает на assert `is_valid_block_position` в pinned VT → обход сферами. Риск регрессии при апдейте плагина. | open |

### 3.2 Coop — сеть, сессия, стрим — `COOP-*`

| ID | Sev | Title | Area | Evidence | Repro (гипотеза) | Status |
|---|---|---|---|---|---|---|
| **COOP-04** | S1 | Live `_cli_dig_op` не ставит failed replay в pending (асимметрия с join-путём) | dig sync | `coop_session.gd:884-888` vs `643-649` + `_tick_pending_dig_reapply:1573-1587` | Live op при `terrain_unavailable` / `false` от `replay_remote_dig` молча дропается, join-путь ретраит → постоянный terrain desync гостя (остаток R-COOP-3). Асимметрия в коде явная, не false alarm. | open |
| **COOP-05** | S1 | Soft store/hotbar: optimistic cache на `unreliable_ordered` | inventory sync | `coop_session.gd:20,27,83,963-1009,1012-1030` | Host пишет `_last_store_wire` / `_last_inventory_revision_sent` до подтверждения доставки. Потерянный пакет на CH_STREAM → HUD стора/хотбара «frozen» до следующего изменения. Hotbar (`assign_hotbar_instance` в `NO_BROADCAST_KINDS`) едет только этим каналом. | open |
| **COOP-06** | S2 | Far dig гостя мёртв: proxy viewer только после первой позы + короткий soft-retry | dig sync / viewer | `remote_player.gd:45-76,190-201`; `coop_session.gd:58-59,1221-1222,1536-1568` <br>*(COOP-06 + D7)* `[R7]` | `HostStreamViewer` создаётся в `_apply` после pose; гость не шлёт pose до `is_spawn_settled`; soft-retry ≤ 2×0.3 s. Дальний dig до прогрева Clipbox → `terrain_unavailable` окончательно (RC-3). Сверить `is_area_editable` / Clipbox load lag. | open |
| **COOP-07** | S2 | Rejoin `you_pose` без seat attach | seats / rejoin | `coop_session.gd:736-738`; `world_persistence.gd:84-98` (`{"p": pos}` only) | Reseat только по позиции; occupancy/seat из pose не восстанавливаются → спавн внутри кабины стоя, клип/физика (RC-6). Live pose имеет `"seat"`, но `_finish_apply_join` его игнорирует. | open |
| **COOP-08** | S2 | Seat force-release: клиентский фолбэк только при следующем тике input | seats | `coop_session.gd:1297-1303,1361-1383`; `world_command_gateway.gd:181-182` | Потеря reliable `_cli_force_seat_release` → локальный attach живёт, пока не сработает `_client_seat_replica_ok` (нужен seated + control tick) → «призрак» в кресле, рассинхрон occupancy. Edge на disconnect/destroy. | open |
| **COOP-09** | S2 | Soft-retry dig не шлёт промежуточный result гостю | UX / feedback | `coop_session.gd:840-848` (`return` без `_cli_result`) | До 0.9 s команда «висит» без HUD-отклика; при финальном fail — один тост. Риск ложных double-submit и ощущения лага копки. | open |
| **COOP-10** | S3 | Codec: `seed` в join payload не валидируется | handshake | `coop_command_codec.gd:103-122,158-168` <br>*(COOP-12)* `[?]` | Handshake проверяет protocol/real_t/generator, но не `seed`. Сейчас константа билда → почти наверняка неактуально; риск при будущем seed override. | open |

Кросс-ссылки в coop: **KRN-01/02/03** (snapshot и batch ломают join), **PHY-03/09** (стрим и паритет
физики), **PERF-H07** (broadcast storm), **UI-02/03** (seat-эксплойты по сети).

### 3.3 Физика / freeze / seats — `PHY-*`

| ID | Sev | Title | Area | Evidence | Repro (гипотеза) | Status |
|---|---|---|---|---|---|---|
| **PHY-01** | S1 | Partial thaw по верёвке → «статуя с живыми колёсами» `[R8]` | freeze / ropes | `simulation_physics_projection.gd:2938-2948` vs `1936-1940` | Park-freeze ровер → натянуть трос за одно тело до `ROPE_WAKE_OVERSHOOT_M`. `_wake_roped_body` снимает freeze только с endpoint, хотя `wake_assembly_bodies` прямо документирует опасность root-only thaw. Сверить поведение joint при mixed freeze/static. | open |
| **PHY-02** | S1 | Root-only gate «assembly frozen» → неконсистентный тик | freeze | `simulation_physics_projection.gd:1971-1973,2341-2342,3427-3429` | После PHY-01 root frozen / wheel live (или наоборот): `_is_assembly_frozen`, skip wheel tick, skip thrusters смотрят только root → часть assembly тикает неверно. | open |
| **PHY-03** | S2 | `motion.frozen` ≠ `body.freeze` после reproject / exit → coop-стрим глохнет | freeze / coop | capture `3800-3814`; skip writeback `287-289`; exit sync `2021-2027`; multibody `1288`; `1577-1584`; `coop_session.gd:1077-1083` | Settle-freeze → `E` → place/dismantle (full reproject): тела dynamic, `assembly.motion.frozen` ещё true до следующего `_physics_process`. Coop `_motion_is_live` гейтит стрим по **motion**, не по body → пауза стрима при живом хосте. | open |
| **PHY-04** | S2 | Settle-freeze глушит impact: «статуя» неуязвима к кинетике `[R8]` | impact | `impact_resolver_service.gd:85-87,226-227`; wake на carve `world_command_gateway.gd:832-834` <br>*(#4 + #13)* | Park-freeze → удар другой assembly / таран. Замороженный body не мониторится и не резолвит impact. Подкоп грунта будит (carve path OK), удар в корпус — нет. Спека IMPACT про StaticBody; freeze RigidBody — отдельный gap. | open |
| **PHY-05** | S2 | Actuator status тикает на frozen joint → ложный STUCK/OVERLOAD | actuators | piston skip `3294-3295`; `_world.tick_actuators` `3423-3424`; `actuator_simulation_service.gd:429-457` | Ровер с поршнем settle-freeze, команда target на frozen joint: constraint/observation не обновляются, kernel-status тикает → ложный STUCK/OVERLOADED. | open |
| **PHY-06** | S2 | Route gates при restore дефолтом ON vs seat thrusters OFF `[спек]` | load / control | `assembly_locomotion_controller.gd:207-211` vs `seat_control_state.gd:12,57` | Save с `activated` без route-ключей (или legacy) → load → unmanned craft с dampeners + thruster/gyro gates ON до первого seat-frame. Комментарий «legacy ON» конфликтует с дефолтом seat `control_thrusters=false`. | open |
| **PHY-07** | S2 | Parking settle-freeze только для wheel-locomotive `[?]` | freeze / perf | `_update_parking_freeze:1852-1855`; `thruster_simulation_service.gd:34-41` | Pure thruster hopper, PB on, exit, ждать → никогда не freeze → вечный per-frame thruster/gyro tick. Возможно by design; асимметрия с wheeled-путём. | open |
| **PHY-08** | S2 | Multibody reproject всегда thaw — park-freeze не сохраняется | freeze | `simulation_physics_projection.gd:1284-1288` | Park-freeze → любой full reproject (wheel/actuator topology). Спека ROVER-MODULES допускает «свободен пару секунд», но окно ударов/дрейфа/coop-стрима до re-settle реально. | open |
| **PHY-09** | S2 | Replica: kinematic freeze, без wheel joints — нет паритета host≈guest `[R8]` | coop physics | host `1097-1100,1306-1309,1570-1576`; client blend `1161-1192` | Гость смотрит/сидит в едущем ровере: подвеска/привод на клиенте не симулируются, только pose stream (~15 Hz + 120 ms interp). Открытый gap COOP-HOST-V0. Факт отсутствия joints — из кода; «достаточно ли kinematic write» — R8. | open |
| **PHY-10** | S3 | Wake не сбрасывает `motion.frozen` немедленно | freeze / coop | `wake_assembly_bodies:1939-1941` | Enter seat сразу после park+exit sync → один physics tick coop-стрим может молчать при уже thawed bodies. | open |
| **PHY-11** | S3 | Soft mass refresh vs frozen: snapshot motion может врать по vel | freeze | `_refresh_single_body_mass_com:679-683` | Soft place/remove на park-frozen single-body под PB: vel нулится, freeze не трогается (OK), но writeback всё ещё skip → snapshot motion устарел до thaw. | open |
| **PHY-12** | S3 | `has_active_input` считает latched PB brake → anti-sleep шум | freeze / perf | `assembly_locomotion_controller.gd:148-157`; seat wake исключает PB `1456-1470`; wheel tick `1975` → sleep poke `2258-2264` | Exit с PB, до settle-freeze: постоянный anti-sleep. Settle не ломается (vel-based), но physics server шумит. | open |
| **PHY-13** | S3 | Joint motors × freeze — семантика не проверена `[R8]` | verification | wheel/piston/rotor `Generic6DOFJoint3D` + `body.freeze` park path | Freeze mid-drive motor / spring-loaded suspension. Нужна сверка с докой Godot Jolt: останавливает ли freeze solver forces на joint, безопасно ли оставлять motor targets. Не выводить из GDScript. | open |
| **PHY-14** | S3 | Seat remote exit не синкает motion (асимметрия с local) | seats / coop | `_exit_remote_rover_seat:2043-2065` vs local `2027` | Гость нажимает `E` из паркованного settle-frozen: local пишет motion, remote нет → stale motion flags для стрима. | open |

### 3.4 Kernel / `SimulationWorld` / snapshot — `KRN-*` (оригинальные `SW-*`)

| ID | Sev | Title | Area | Evidence | Repro (гипотеза) | Status |
|---|---|---|---|---|---|---|
| **KRN-01** `SW-ORPHAN-REDIRECT` | S1 | Осиротевший redirect на мёртвый id → snapshot невалиден | topology / snapshot | `topology_mutation_service.gd:65-67` (erase без cleanup redirects); merge redirect `437`; validator `simulation_snapshot.gd:487-515` | Merge A←B, затем dismantle всех элементов survivor A до `assembly_removed`. `capture_snapshot` → `restore_snapshot` / `create_from_snapshot` падает на redirect на отсутствующий A. Coop-broadcast ломает join. | open |
| **KRN-02** `SW-RESTORE-NO-GEN` | S1 | `restore_snapshot` не бампает `topology_generation` → stale preview cache | snapshot / preview | `simulation_world.gd:1419-1455`; bump только `_notify_topology_changed:1898`; `construction_preview.gd:272-273` | Клиент: resolve preview → host structural → `_cli_apply_snapshot` → тот же aim/archetype. Context key совпадает → cache hit по старому плану против нового мира. | open |
| **KRN-03** `SW-BATCH-EVENT-GAP` | S1 | `structural_batch_committed` не обрабатывается projection/industry | events / compose | emit `simulation_world.gd:2051`; handlers `simulation_physics_projection.gd:316-351`, `element_visual_projection.gd:104-148`; `industry_simulation.gd:217-219` | `MachineComposer.compose` / `RoverComposer.compose` без `spawn_on_terrain`: события place/weld глушатся batch'ем, в конце только `structural_batch_committed` → host physics/visual/cargo-handle не обновляются. | open |
| **KRN-04** `SW-C1-UNGATED` | S1 | C1-дыры: мутации без `_refuse_replica_write` | replica gating | комментарий `simulation_world.gd:45-46`; `set_resource_amount:1122`, `ensure_resource_store:1109`, loot `1038+`, `sync_actuator_observation:983`, `begin/end_structural_batch:2033`, `get_locomotion_controller:742` | На `authoritative=false` вызвать `set_resource_amount` / `add_world_loot_pile` / `sync_actuator_observation` / `ensure_*` → мир меняется без `REASON_NOT_AUTHORITATIVE` (в отличие от `apply_structural_command_now:1201`). | open |
| **KRN-05** `SW-RESTORE-BATCH-STALE` | S2 | Restore не сбрасывает batch/deferred флаги | snapshot | `restore_snapshot:1419-1455`; suppress `_emit_structural_event:2054-2058` | `begin_structural_batch` → `restore_snapshot` без `end`: depth > 0 → дальнейшие structural events глушатся навсегда; `_deferred_derived_recompute` тянется из pre-restore мира. | open |
| **KRN-06** `SW-MERGE-LOCO-LEAK` | S2 | Merge не чистит locomotion loser'а | topology | `clear_assembly_locomotion` только при full remove `topology_mutation_service.gd:67`; merge tombstone `435-437`; `list_locomotion_rows:754-758` | Два mobile assembly, activate loco на будущем loser, merge → snapshot несёт locomotion на tombstone id; restore / `get_locomotion_controller(loser)` даёт ghost state. | open |
| **KRN-07** `SW-CMD-RAW-ID` | S2 | Structural-команды берут `get_assembly_raw` — redirect не резолвится | commands | place/dismantle `construction_command_service.gd:222,1396`; merge `topology_mutation_service.gd:275`; контракт `SIMULATION-KERNEL-V0.md:154-155` | После merge UI/команда держит loser `assembly_id` → `invalid_reference` вместо survivor через redirect. `get_assembly(loser)` работает, raw — нет. | open |
| **KRN-08** `SW-LETHAL-NO-TOPO-REV` | S2 | Lethal damage меняет топологию без `expected_assembly_revision` | concurrency | `damage_element:1283-1308` (только `expected_state_revision`) vs dismantle `1401-1404` | Параллельно place (бампает topo) и lethal damage по другому элементу с валидным state_rev → remove/split без optimistic topo gate → гонка с concurrent structural. | open |
| **KRN-09** `SW-REV-ASYMMETRY` | S2 | Разный контракт optimistic concurrency: electric vs construction | concurrency | `industry_network_commands.gd:40-41,275` (`>= 0`) vs `construction_command_service.gd:232` (строгое `!=`) | `ConnectNetworkCommand` с default `-1` проходит без revision check; `PlaceElementCommand` с `-1` на live assembly даёт стабильный `stale_revision`. | open |
| **KRN-10** `SW-ERASE-VS-TOMBSTONE` | S2 | Нет единой политики lifetime redirect'ов | topology | erase `topology_mutation_service.gd:66`; merge tombstone `435-437`; redirects никогда не prune | Любой redirect target, удалённый через dismantle последнего элемента, оставляет висячие tombstones (корень KRN-01). | open |
| **KRN-11** `SW-INDUSTRY-BATCH-STALE` | S2 | Industry runner держит stale `_cargo_graph` в batch | industry / events | `industry_simulation.gd:217-219`; derived rebuild `end_structural_batch:2042-2043` | Compose / weld_all в batch: runner держит старый `_cargo_graph` handle до следующего узнаваемого event → mid-batch industry tick видит stale adjacency. | open |
| **KRN-12** `SW-LOCO-READ-WRITE` | S2 | `get_locomotion_controller` — write-on-read, не C1-gated | replica gating | `simulation_world.gd:742-744`; `test_snapshot_replica.gd:285-287` (тест сам отмечает lazy insert) | На replica любой read loco создаёт `_assembly_locomotion` row → загрязняет `list_locomotion_rows` / semantic snapshot. | open |
| **KRN-13** `SW-CONNECT-NO-TOPO-BUMP` | S3 | Electric connect/disconnect не вызывает `_notify_topology_changed` | events | `industry_network_commands.gd:98-112,286-294` (только `industry_network_revision`) | Кэши, завязанные только на `topology_generation`, не видят wire-only мутации (preview / snap token не двигается). | open |
| **KRN-14** `SW-BATCH-PARTIAL-WORLD` | S3 | Failed compose закрывает batch с commit при частичных мутациях | compose / rollback | `machine_composer.gd:20-22` (always `end`), `50-57` | Compose с mid-fail validate: в мире остаётся half-built assembly + `structural_batch_committed`, без rollback. | open |
| **KRN-15** `SW-RECONCILE-DOUBLE-BUMP` | S3 | Double revision bump на один structural op | diagnostics | reconcile `construction_command_service.gd:1508-1510`; затем `bump_revision` `topology_mutation_service.gd:89,140,206,253` | Один op → 2 bump + 2 notify; `topology_generation` скачет двойным шагом, усложняя диагностику гонок. | open |

### 3.5 Industry / stores / balance / save / oxygen — `IND-*`

| ID | Sev | Title | Area | Evidence | Repro (гипотеза) | Status |
|---|---|---|---|---|---|---|
| **IND-01** | S0 | Rope / `cable_stake` не выживает snapshot round-trip — **красный тест** `[спек]` | ropes / snapshot | `ROPE-CHAIN-V0.md` § Save/load + Decisions (`INDUSTRY-V1: ropes must survive a snapshot round trip` — broken); `test_industry_v1.gd::_run_rope_free_attach_scenario` | headless `test_industry_v1` → сценарий rope→terrain (stake) → `capture_snapshot` / `create_from_snapshot` → fail. Блокер для ground-anchored ropes. | open |
| **IND-02** | S1 | Restore-ассерты устарели после stake-модели `[спек]` | ropes / test contract | тот же сценарий; `industry_network_commands.gd`; `CableAnchorUtil.localize` | Live-часть требует `element_b = cable_stake` + tie-point, а пост-restore проверяет `element_b != 0` (ждёт `0`) и `attach_b ≈ ground_point` в world, хотя `connect_rope` локализует attach и ставит stake ≠ 0. Тест красный даже при успешном restore. | open |
| **IND-03** | S1 | Legacy inventory не досыпает `tool_rope` | save migration | `PlayerInventoryRegistry.migrate_legacy_save()` (seed только если `_instances.is_empty()`); `INDUSTRY-V1` § tool instances (без rope); код: `starter_tool_rope`, hotbar `5:7` | Сейв v10 / ранний v11 с 4 tools → load → `starter_tool_rope` отсутствует, слот 5:7 пуст. | open |
| **IND-04** | S1 | `game_balance.json` без slice rover parts → JSON не управляет числами | balance | audit: нет `elements.control_terminal` / `drive_wheel` / `wheel_suspension`; `GameBalance.apply_element` no-op при пустом entry; `test_game_balance` проверяет только `REQUIRED_IDS` <br>*(= CMP-05)* | Compose rover / place terminal → mass/BOM/wheel tuning берутся только из `.tres`. **Сверить с возможным balance-fixer'ом.** | open |
| **IND-05** | S2 | Legacy dual-path всё ещё в balance (спека требует удалить) `[спек]` | balance / recipes | `INDUSTRY-V1` § Legacy dual-path; `resources/balance/game_balance.json`; `test_game_balance` требует `crush_regolith` и `construction_component` | Fabricator `reduce_oxide` → `metal_ingot` → `sinter_component` → `construction_component`, а BOM блоков ждёт `plate_metal`/`mechanism` → тупик для игрока. | open |
| **IND-06** | S2 | ISRU-кислород не пополняет OxygenModule / костюм | oxygen loop | `CargoTransferService` → `transfer_blocked` для O₂-module stores; `OXYGEN-SURVIVAL-V0`, `INDUSTRY-V1` (bulk→module deferred); `electrolyze_water` | Electrolyzer → store с `oxygen` → transfer/auto в `o2_module` → blocked; suit refill только из seeded module tank. Ср. IND-13 (осознанный deferred). | open |
| **IND-07** | S2 | Starter почти заполняет 100 L (headroom 5.8 L) | balance / UX | tools 31 L + `starter.player_resources` ≈ 63.2 L → 94.2 / 100 | Fresh world → pickup любого item ≥6 L (plate/girder/tool) → `storage_full` без ручной очистки кармана. | open |
| **IND-08** | S2 | `frame_lamp` есть в `elements`, нет в `electric.archetypes` | balance / electric | `game_balance.json`: `elements.frame_lamp` есть, `electric.archetypes` — нет; `.tres` без consumer definition | Лампа на базе без питания: не consumer в electric budget → «бесплатный» свет, если VFX не гейтится иначе. | open |
| **IND-09** | S2 | Инструменты без recipes / craft path | progression | items `tool_*` (вкл. `tool_rope`) не упомянуты ни в одном `recipes.*`; fabricator defaults — plates/ingots | Потерять/передать starter rope → новый `tool_rope` только через cheat/playtest cargo, не через ISRU. | open |
| **IND-10** | S2 | Два version-канала: save vs snapshot | save | `WorldPersistence.SAVE_VERSION := 4` (exact match или wipe) vs `SimulationSnapshot.VERSION := 11` (accept 9–11) | Payload `save_version:4` + `simulation.version:8` → outer OK, inner fail: `restore_snapshot_data` warning, cold poses/markers рассинхронятся с пустым sim. | open |
| **IND-11** | S3 | Спека starter vs registry по rope `[спек]` | docs | `INDUSTRY-V1` starter ids / hotbar page0 `0,1,2,8`; код + `tool_rope` на `5:7`; `test_player_inventory_hotbar` rope не проверяет | Чтение спеки vs hotbar wheel-page → расхождение контракта. | open |
| **IND-12** | S3 | Authored archetypes вне balance | balance | `H2O_Tank`, `Suspension_Medium`, `Test_Battery`, `Wheel_Medium_01` — нет в `elements{}` / `electric{}` <br>*(⊂ CMP-05)* | Part Wizard parts в мире → mass/BOM/electric не из JSON. | open |
| **IND-13** | S3 | `GameBalance.validate` не ловит дыры archetypes | tooling | validate проверяет shape items/recipes/elements, но не «каждый REQUIRED/ROVER/authored id ∈ elements» и не electric-consumer для lamp | Убрать `control_terminal` → `test_game_balance` зелёный, игра едет на `.tres`. Корень IND-04/IND-08/IND-12. | open |
| **IND-14** | info | OxygenModule refill из cargo — осознанный deferred v0 `[спек]` | contract | `OXYGEN-SURVIVAL-V0`, `INDUSTRY-V1` § «Не входит» | Не баг реализации, а контракт. Стоит рядом с IND-06 как продуктовый тупик ISRU→выживание («как в SE» не выполняется by design). | open |

### 3.6 HUD / input / seats — `UI-*` (оригинальные `BH-*`)

| ID | Sev | Title | Area | Evidence | Repro (гипотеза) | Status |
|---|---|---|---|---|---|---|
| **UI-01** `BH-01` | S1 | Drag инвентаря рвётся любым `command_completed` | inventory UI | `hud_inventory_grid.gd::_on_command_completed` → `refresh()` → `_rebuild_grid()` → `queue_free` слотов; то же в `hud_inventory_container_panel.gd`, `hud_terminal.gd::_refresh_panels`. Control terminal гейтит по `gui_is_dragging`, inventory — нет | Открыть `I` / dual-терминал → начать drag стопки → параллельно копать/ставить блок → drag срывается, превью пропадает. | open |
| **UI-02** `BH-02` | S1 | PAX/seat tool-gate смотрит только `is_in_vehicle()`, не seat meta | seats / tools | `tool_controller.gd::_pressed_action` / `_physics_process` (`in_vehicle = is_in_vehicle()`); `mouse_look.gd::_is_in_vehicle()` дополнительно принимает `control_seat_element_id` meta | Coop: сидеть (лучше PAX) → момент recreate body → ЛКМ drill/build до `ensure_local_seat_binding` → тул срабатывает, камера ещё «в кресле». | open |
| **UI-03** `BH-03` | S1 | `passenger: true` принимается без проверки архетипа | seats / gateway | `world_command_gateway.gd::_resolve_passenger_seat` — первый `if parameters.passenger` → `return true`; путь `KIND_CONTROL_SEAT` передаёт это в `_enter_rover_seat` | Гость шлёт `toggle_control_seat` на кокпит с `passenger:true` → sit+look без руля/K (`controls_permitted` false), выход по `E`. Локальный TC ставит флаг только на `passenger_seat`. | open |
| **UI-04** `BH-04` | S2 | Feedback врёт на ControlSeat («E — сесть в кокпит») | feedback | `hud_feedback.gd`: любой `KIND_CONTROL_SEAT` → «кокпит»; `passenger_seat` и `control_terminal` тоже ControlSeat, а TC на терминале делает `try_open` | Навести на PAX-кресло / стационарный пульт → подсказка «кокпит», поведение другое. | open |
| **UI-05** `BH-05` | S2 | Debug spoil (`O`) не гейтится сиденьем/PAX `[спек]` | debug / PAX policy | `tool_controller.gd::_update_debug_spoil_input` — после UI-check, без `in_vehicle` / passenger | Сесть в `passenger_seat` → держать `O` → сыпучка спавнится, хотя политика PAX запрещает dig/tools. | open |
| **UI-06** `BH-06` | S2 | Хоткеи глотаются при неудачном open (exclusive `UIWindowStack`) | input routing | `hud_terminal.gd` (`I`), `hud_palette.gd` (`G`), `hud_control_terminal.gd` (`K`): `set_input_as_handled()` даже если `push`/`toggle` — no-op | Открыть Esc-settings → `I`/`G` → окно не открылось, клавиша съедена. | open |
| **UI-07** `BH-07` | S2 | Hotbar remap из инвентаря недоступен в кресле | inventory UI / PAX | `hud_toolbar.gd`: `visible = false` при `is_in_vehicle` | PAX → `I` → drag tool instance на слот 1–3 → цели нет, бар скрыт. Инвентарь в PAX спекой разрешён. | open |
| **UI-08** `BH-08` | S2 | K-page хоткеи работают при фокусе в LineEdit | input routing | `hud_control_terminal.gd::_unhandled_input`: `toolbar_page_prev/next` обрабатываются до проверки `gui_get_focus_owner() is LineEdit` (цифры слотов — после) | Открыть `K` → rename → `page+/−` меняет страницу бара mid-edit. | open |
| **UI-09** `BH-09` | S2 | Close панели всегда возвращает capture/gameplay | mouse mode | `hud_terminal` / `hud_actuator_panel` deferred restore; `player_settings_overlay.close` форсит `MOUSE_MODE_CAPTURED` + gameplay true без проверки «другое окно ещё открыто» | Быстро чередовать `Esc`/`I`, закрыть одно поверх другого → кадр с захваченной мышью при видимом UI или наоборот. Сейчас маскируется exclusive-стеком. | open |
| **UI-10** `BH-10` | S2 | `V` (vehicle camera) не уважает модалки | camera / input | `mouse_look.gd::_process` — poll `toggle_vehicle_camera` без `UIWindowStack` / mouse mode | Сидя открыть `I`/`K` → `V` → orbit переключается под UI. | open |
| **UI-11** `BH-11` | S2 | Асимметрия seat detection: interact vs tools | seats | `_target_for_action`: meta `control_seat_element_id` → synthetic exit; tools — только `is_in_vehicle()` | Orphan seat: `E` = выход, ЛКМ = tool world action. Тот же корень, что UI-02. | open |
| **UI-12** `BH-12` | S2 | PAX `K`: silent deny + `set_input_as_handled` | feedback / PAX | `controls_permitted()` + `toggle()` no-op, но `_unhandled_input` всё равно помечает handled; RC-2 в `COOP-HOST-V0` — ⬜ human | PAX → `K` → ничего не происходит, нет тоста/лога. | open |
| **UI-13** `BH-13` | S3 | Orbit всегда сбрасывает pitch на 15° | camera | `mouse_look.gd::_init_orbit_from_vehicle`: `_orbit_pitch = clampf(15.0, …)` | Сидя `V` on/off → pitch орбиты не сохраняется. | open |
| **UI-14** `BH-14` | S3 | Triple rebuild инвентаря на одну команду | inventory UI / perf | Grid + container + terminal все подписаны на `command_completed` и делают refresh | Dual-терминал + любой submit → 3× snapshot/rebuild (лаг + усиливает UI-01). | open |
| **UI-15** `BH-15` | S3 | Flight-look delta копится при залипшем capture `[?]` | input edge | `mouse_look`: motion только при `MOUSE_MODE_CAPTURED`; при залипшем capture (UI-09) delta копится в `_flight_look_delta` при `gameplay_input=false` | Driver + gyros: залипший capture при «закрытом» UI → рывок attitude после close. Зависит от UI-09. | open |

### 3.7 Перф / R9 hot paths — `PERF-*` (оригинальные `H01…H12`)

| ID | Sev | Title | Area | Evidence | Оценка стоимости | Status |
|---|---|---|---|---|---|---|
| **PERF-H01** | S1 | Aim HUD пересобирает `InteractionCard` каждый кадр | HUD hot path | `InteractionCard.refresh` всегда `keys.clear()` + полный rewrite (`interaction_card.gd:13-31`); `hud_target_panel._process` / `hud_reticle` зовут `_aim_keys` каждый frame | ~0.2–2+ ms/frame при наведении на элемент; растёт с actuator/machine полями. Регресс «прицел в ровер → FPS» | open |
| **PERF-H02** | S1 | Кабели: full wire update каждый `_process` | industry projection | `industry_network_projection.gd:84-98` — при неизменной revision всё равно `_wire_points` → smooth → `_update_wire_colliders` → pointwise `_tube_path_changed`; gated только mesh rebuild | O(links)×path / frame; десятки тросов → заметный CPU hitch | open |
| **PERF-H03** | S1 | Physics projection: multi-pass + сортировки каждый physics tick | physics hot path | `simulation_physics_projection.gd:271-306`; `_tick_wheel_bodies` сортит `_bodies` и `_wheel_constraints`; `_sorted_int_keys` — 14× в файле; motion capture по всем unfrozen | ~1–10+ ms/tick на большом powered rover (исторический «кабина 200→30») | open |
| **PERF-H04** | S1 | World RT: `tlas_build` каждый frame в `main` `[вне охвата]` | RT | `WorldRtGeometry` в `scenes/main.tscn`; `_process` всегда `_rebuild_tlas()` → `_rd.tlas_build` (`world_rt_geometry.gd:79-104,270-282`); discover throttled 0.5 s, TLAS — нет | GPU/CPU TLAS rebuild / frame при RT on; до сотен instances в 96 m. **RT исключён из этого прохода** — оставлено для будущего RT-раунда | open |
| **PERF-H05** | S2 | Industry 4 Гц: полные world-scans в нескольких сервисах | industry tick | `IndustrySimulation._tick_once`; `industry_electric_budget.gd:7-21`; `recipe_runner_service.gd:17,253-262`; `cargo_transfer_service.gd:240` — повторные `list_elements` / `list_assemblies` / `list_joints` / `discover_pairs` | ~1–5+ ms каждые 250 ms при большом дворе | open |
| **PERF-H06** | S2 | Открытый K-пульт: full snapshot + UI list rebuild | HUD | `hud_control_terminal`: 10 Hz refresh, full `control_terminal_snapshot` при structure dirty / audit 1 s (комментарий «~16 ms»); `_fill_nodes` → `_rebuild_list` queue_free+rebuild | ~5–16 ms на full audit; UI O(nodes) alloc/free | open |
| **PERF-H07** | S2 | Coop: full `capture_snapshot` broadcast storm | coop | `coop_session.gd:852-922` — любой ok-command вне `NO_BROADCAST_KINDS` → `_mark_snapshot_dirty` → debounce 0.3 s / floor 1.5 s → `rpc(capture_snapshot())`; client interp всех streams каждый frame | Host: full-world serialize ≤ ~0.67 Hz при dirty burst; client: full restore hitch + O(moving assemblies)/frame | open |
| **PERF-H08** | S2 | Element visuals: poll body identity каждый кадр | visual projection | `element_visual_projection.gd:50-89` — `_resync_replaced_bodies` обходит все `_known_bodies`; нет dirty/signal от physics swap | O(assemblies)/frame baseline; spike — full visual rebuild при Static→Rigid activate | open |
| **PERF-H09** | S2 | Piston visuals: sync всех assemblies каждый кадр | visual projection | `piston_visual_projection.gd:42-46` — `for assembly_id in _records_by_assembly: _sync_assembly` без dirty/pose gate | O(piston joints)/frame; постоянный transform sync на drill-arm | open |
| **PERF-H10** | S2 | Target panel: live machine/actuator refresh без throttle | HUD | `hud_target_panel.gd:312-338` — даже при `panel_sig == _last_panel_sig` каждый frame `_refresh_actuator_info` / `_refresh_machine_info` / oxygen / cargo | +label/UI writes каждый кадр пока держится aim; усиливает PERF-H01 | open |
| **PERF-H11** | S3 | Seated bar: 10 Гц snapshot poll даже с закрытым пультом | HUD | `hud_control_terminal.gd:448-478,507-529` — `control_terminal_bar_snapshot` каждые `REFRESH_S=0.1`; compact bar рядом ещё раз `_process`+signature | ~0.1–1 ms × 10 Hz, всегда включено в кабине | open |
| **PERF-H12** | S3 | Rope tick фильтрует `list_links()` каждый physics tick | physics | `simulation_physics_projection.gd:2373-2395` — early-out по `rope_link_count`, иначе полный `list_links()` + filter + XPBD/collision budget | O(all links)/tick при наличии верёвок; spikes при многих ropes | open |

Намеренно вне топ-12 (агент отметил как холодное/opt-in): `power_radius_preview` (только при
зажатом ключе), `construction_preview` (покрыт `docs/cheatsheets/construction-perf.md`),
`hud_vehicle_power` (уже урезан до 1 Hz seated).

> **R9-дисциплина:** перед оптимизацией любого `PERF-*` — замер (perf-монитор / профайлер).
> Оценки в таблице — прикидки из чтения кода, не измерения.

### 3.8 Authoring / compose / палитра — `CMP-*`

| ID | Sev | Title | Area | Evidence | Repro (гипотеза) | Status |
|---|---|---|---|---|---|---|
| **CMP-01** `COMPOSE-WELD-SILENT` | S1 | Compose возвращает `ok:true` при незавершённой сварке | compose | `AssemblyBuildHelper.weld_all()` пишет `last_error=weld_incomplete…` + `push_warning`, но не возвращает `bool`; `RoverComposer`/`MachineComposer` сразу зовут `_wire_power` → `connect_*` обнуляет `last_error`; валидаторы integrity не проверяют | Сломать бюджет/BOM (или отключить retry) → `compose` → `ok:true`, элементы на ~1% integrity, в логе только warning. | open |
| **CMP-02** `TOOLBAR-PAGE-OVERFLOW` | S1 | Страницы 0/1 тулбара имеют 10 записей при лимите 9 | toolbar | `TOOLBAR_PAGES[0]`/`[1]` — по 10; `TOOLBAR_SLOTS_PER_PAGE=9`; HUD читает `toolbar_slot_1..9` (0..8) | Страницы 1/2 → 9 слотов; хвосты `piston_base` (page0) и `dozer_blade` (page1) недоступны кроме палитры/remap. | open |
| **CMP-03** `ELECTROLYZER-NOT-BUILDABLE` | S1 | `electrolyzer` в мире и рецептах, но не в construction | palette | есть в `Slice01Archetypes.REQUIRED_IDS` + balance/recipes; нет в `ToolController.CONSTRUCTION_ARCHETYPES` → нет в `construction_archetype_ids()` / палитре / remap | Открыть Block Palette → `electrolyzer` отсутствует; поставить штатным UI нельзя (при этом рецепты на него завязаны — см. IND-06). | open |
| **CMP-04** `TOOLBAR-MISSING-TERMINAL-LARGE` | S2 | `control_terminal` и `large_frame` не на `TOOLBAR_PAGES` | toolbar | оба в `CONSTRUCTION_ARCHETYPES` (+ HUD tokens), ни одного в `TOOLBAR_PAGES` | Листать страницы тулбара → нет TRM / `large_frame`, только палитра. | open |
| **CMP-05** `BALANCE-MISSING-CONTROL-TERMINAL` | S2 | Нет `elements.control_terminal` (+ authored/legacy без balance) — **дубль IND-04/IND-12** | balance | `.tres` есть (`mass_kg=25`, BOM mechanism×4), в `game_balance.json` нет; также вне balance: `H2O_Tank`, `Suspension_Medium`, `Wheel_Medium_01`, `Test_Battery`, `drive_wheel`, `wheel_suspension`; `test_game_balance` не требует ROVER_IDS | Сверить JSON vs `resources/archetypes/**`; `GameBalance.apply_element` no-op → числа только из `.tres`. | open |
| **CMP-06** `BALANCE-TRES-MASS-DRIFT` | S2 | `piston_head_large.mass_kg`: `.tres` 140 vs balance 80 | balance | `piston_head_large.tres` `mass_kg=140.0`; `game_balance.json` `elements.piston_head_large.mass_kg=80` | Открыть `.tres` в редакторе vs JSON; в игре после register масса 80 → авторская цифра игнорируется молча. | open |
| **CMP-07** `MACHINE-ORI-FALLBACK-0` | S2 | `MachineComposer` молча берёт orientation `0` при провале матча | compose | `boom_ori = orientation_with_local_faces(...)` без проверки; helper при отсутствии матча даёт `0`. `RoverComposer._orientation_for` намеренно возвращает `-1` и отмечает это как опасное | Сломать face-constraints / подставить несовместимый hinge → compose «успевает» с identity-ориентацией boom/wrist. | open |
| **CMP-08** `MACHINE-SPAWN-Y-ONLY` | S2 | `MachineComposer.spawn_on_terrain` копирует только `origin.y` | spawn / radial gravity | после compose: `motion.transform.origin.y = assembly_transform.origin.y`, basis/XZ из grid_frame; у ровера явный комментарий, что одного `y` мало на radial gravity | Planetoid (`main.tscn`) → spawn drill arm → фундамент не на поверхности по local up / уезжает в кору. | open |
| **CMP-09** `ROVER-PASSENGER-SEAT-IGNORE` | S2 | Place `passenger_seat` без проверки результата | compose | `RoverComposer._place_modules`: `helper.place(passenger_seat, …)` без `if not` | Ширина ≥4, занять клетку `(3, module_y, cockpit_z)` → compose `ok`, сиденья нет, `last_error` пуст. | open |
| **CMP-10** `REGISTRY-REGISTER-SILENT-FALSE` | S2 | `ArchetypeRegistry.register` тихо отвергает fingerprint clash | registry | при существующем id и другом fingerprint → `return false` без лога; `bootstrap` / composers игнорируют return | Зарегистрировать A, затем повторно register того же id с другим structural schema → `false`, в мире остаётся старый A. | open |
| **CMP-11** `WELD-ALL-SINGLE-PASS` | S2 | `weld_all` — один проход на элемент (`max_material_amount=100`) | compose | нет цикла до `is_complete`; partial → `unfinished` + warning (корень CMP-01); retry только на `INSUFFICIENT_MATERIAL` | Элемент с BOM/integrity, не закрываемым одним weld call, остаётся incomplete при «успешном» compose. | open |
| **CMP-12** `SLOPE-ORI-SILENT-0` | S3 | Декор ровера: `_slope_ori` тоже фолбэчит в `0` | compose | `_place_decor` → `_slope_ori` → `orientation_with_local_faces` (fallback 0), без fail | Несовместимые face-constraints у `frame_slope_45` → склоны встают identity, compose остаётся `ok`. | open |

---

## 4. Дедупликация — карта слияний

| Итоговый ID | Слитые исходные | Комментарий |
|---|---|---|
| **DIG-01** | `D1` (voxel) + `COOP-02` (coop) | Один корень: early-return `_persist_digs_durable` при `_dig_persist_in_flight`. |
| **DIG-02** | `D3` + `COOP-01` | Double-carve — обратная сторона того же flush/mark-контракта. |
| **DIG-03** | `D2` + `COOP-03` | Timeout чанков bulk при tail-only `dig_ops`. |
| **DIG-11** | `D8` + `COOP-11` | Pending join `dig_ops` без TTL/cap. |
| **DIG-12** | `D13` + `COOP-08` | `MAX_DIG_OPS` ring drop. |
| **COOP-06** | `COOP-06` + `D7` | Far dig гостя: создание proxy viewer после первой позы **и** короткий soft-retry — одна причина. |
| **PHY-04** | physics `#4` + `#13` | Freeze глушит impact; carve-путь будит, кинетический удар — нет. |
| **IND-04** | `IND-04` + `IND-12` + `CMP-05` | Отсутствие элементов в `game_balance.json`; CMP-05 оставлен в authoring-таблице как ссылка. |
| **PERF-H01 / PERF-H10** | не слиты | Разные точки (`InteractionCard` vs panel refresh), но усиливают друг друга — чинить вместе. |
| **CMP-01 / CMP-11** | не слиты | Симптом (`ok:true`) и причина (single-pass weld) — один батч. |
| **KRN-01 / KRN-10** | не слиты | Симптом (невалидный snapshot) и политика (lifetime redirect) — один батч. |

---

## 5. Предлагаемые батчи для постепенной работы (кода нет)

Батчи упорядочены по ценности для coop RC. Каждый — самостоятельный проверяемый заход.

| Батч | Состав | Тип верификации по DoD |
|---|---|---|
| **B1 · Join/terrain contract** | DIG-01, DIG-02, DIG-03, DIG-05, DIG-08, DIG-12 | Ядро + сеть: `run_one.sh test_coop_dig_replay`, затем live host+guest late join |
| **B2 · Live coop sync reliability** | COOP-04, COOP-05, COOP-06, COOP-08, COOP-09, PERF-H07 | Live coop-сессия (потеря пакетов / far dig), скриншот + логи |
| **B3 · Snapshot integrity** | KRN-01, KRN-02, KRN-05, KRN-06, KRN-07, KRN-10, KRN-14 | Ядро: `test_snapshot_*`; новый инвариант → новый тест + строка в `run_tests.sh` |
| **B4 · C1 replica gating** | KRN-04, KRN-12, PHY-09 | Ядро: `test_snapshot_replica`; полный гейт (трогаем ядро) |
| **B5 · Batch events → projections** | KRN-03, KRN-11, CMP-01, CMP-11 | Ядро + live: compose ровера/манипулятора без `spawn_on_terrain` |
| **B6 · Freeze coherence** | PHY-01, PHY-02, PHY-03, PHY-04, PHY-08, PHY-10 | `[R8]` сверка Jolt-доки; live: park → rope yank / ram / place block |
| **B7 · Seat & PAX gate** | UI-02, UI-03, UI-04, UI-05, UI-07, UI-11, UI-12, COOP-07 | Live (R2: HUD/интеракции не тестируются headless); подтверждение человеком |
| **B8 · UI window & input hygiene** | UI-01, UI-06, UI-08, UI-09, UI-10, UI-13, UI-14, UI-15 | Live прогон окон/хоткеев, скриншот |
| **B9 · Balance JSON как единственный источник** | IND-04, IND-05, IND-08, IND-13, CMP-05, CMP-06 | `test_game_balance` (расширить контракт); сверить с возможным balance-fixer'ом |
| **B10 · Rope / cable_stake snapshot** | IND-01, IND-02 (+ IND-03, IND-09, IND-11) | `run_one.sh test_industry_v1` до зелёного + обновить `ROPE-CHAIN-V0` |
| **B11 · Палитра и тулбар: покрытие** | CMP-02, CMP-03, CMP-04 | Live: палитра/страницы бара, скриншот |
| **B12 · Compose robustness** | CMP-07, CMP-08, CMP-09, CMP-10, CMP-12 | Live compose на planetoid + скилл-сценарии `rover-compose` / `machine-compose` |
| **B13 · Perf: aim & HUD** | PERF-H01, PERF-H10, PERF-H06, PERF-H11 | Замер до/после (перф-монитор), не оптимизировать без цифры |
| **B14 · Perf: per-frame projections** | PERF-H02, PERF-H03, PERF-H08, PERF-H09, PERF-H12 | Замер на большом powered rover; профайлер |
| **B15 · Perf: industry tick** | PERF-H05 | Замер на большом дворе |
| **B16 · Oxygen / ISRU loop** | IND-06, IND-07, IND-14 | Продуктовое решение до кода: обновить спеку, потом реализация |
| **B17 · Долг и мелочи** | DIG-13, DIG-14, KRN-08, KRN-09, KRN-13, KRN-15, PHY-05…PHY-07, PHY-11…PHY-14, COOP-10, IND-10 | По типу изменения; часть — только `[R7]`/`[R8]` сверка без кода |
| **отложено** | PERF-H04 (RT TLAS) | RT вне охвата этого прохода — в будущий RT-раунд |

---

## 6. Требует внешней сверки перед фиксом

**`[R7]` — Voxel Tools (дока Zylann + GitHub issues), не выводить контракт из кода проекта:**
DIG-05, DIG-06 (частично), DIG-09, DIG-10, DIG-11, DIG-13, DIG-14, COOP-06.
Конкретно: семантика `VoxelSaveCompletionTracker` / abort, `is_area_editable` и Clipbox load lag,
hot-swap `stream` + viewer invalidate, units у `VoxelTool.raycast().distance`, upstream-статус
`do_path` stamp, collider lag (issues #676/#677).

**`[R8]` — Godot Jolt (дока + веб-поиск по встроенному Jolt 5.6, не legacy extension):**
PHY-01, PHY-04, PHY-09, PHY-13. Конкретно: поведение joint при mixed freeze/static,
останавливает ли `freeze` solver forces и motor targets, достаточно ли kinematic write для реплики.

**`[?]` — высокая доля спекуляции, сначала подтвердить наблюдением:**
DIG-02 (направление ошибки: double-carve vs недокопка), COOP-10 (сейчас, вероятно, неактуально),
PHY-07 (возможно by design), UI-15 (зависит от UI-09).

**`[спек]` — расхождение кода и документа; сначала решить, что источник истины:**
DIG-14, IND-01, IND-02, IND-05, IND-11, IND-14, PHY-06, UI-05.

---

## 7. Учёт объёма

| Область | Записей | S0 | S1 | S2 | S3 / info |
|---|---|---|---|---|---|
| DIG (terrain/join) | 14 | 2 | 2 | 7 | 3 |
| COOP (сеть/сессия) | 7 | — | 2 | 4 | 1 |
| PHY (физика/freeze) | 14 | — | 2 | 7 | 5 |
| KRN (kernel/snapshot) | 15 | — | 4 | 8 | 3 |
| IND (industry/balance) | 14 | 1 | 3 | 6 | 4 |
| UI (HUD/input) | 15 | — | 3 | 9 | 3 |
| PERF (R9) | 12 | — | 4 | 6 | 2 |
| CMP (authoring) | 12 | — | 3 | 8 | 1 |
| **Итого** | **103** | **3** | **23** | **55** | **22** |

Источники: 8 hunt-агентов сессии `7541c632` (coop, physics, industry, voxel/dig, HUD, kernel,
perf, authoring). Ни один агент не вносил правок.
