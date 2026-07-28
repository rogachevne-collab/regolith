# Coop (host-authoritative) v0

Статус: этапы 0–3 реализованы и играбельны; спайк A–D в main (`eb66171`,
`9d7b96e`, `3dcce29` и др.) — копка op-каналом, стрим сборок, кресло
водителя/пассажира, session `dig_ops` на join, R-COOP-7 proxy + soft-retry,
slip-limited brake, session last-pose, cold `players{}` poses (SAVE_VERSION
4). Этапы 4–7 спеки частично перекрыты спайком; **RC** — см. «Release
candidate» (глазная приёмка ещё открыта).
См. также `docs/COOP_SPIKE_PLAN.md`. Цель — кооп на 2–4 игрока: один игрок =
хост (listen server), остальные подключаются, сессия и сейв живут у хоста.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` — «Граница владения»;
- `docs/specs/SIMULATION-KERNEL-V0.md` — `SimulationWorld`, snapshot;
- `docs/specs/PLAYER-INTERACTION-V1.md` — команды игрока, aim;
- `docs/specs/INDUSTRY-V1.md` — stores, `PLAYER_STORE_ID`;
- `docs/specs/CONSTRUCTION-V1.md`;
- `docs/specs/MOON-EXPERIMENT-V0.md` — double precision, лунный радиус.

## Индекс (не читай файл целиком — найди термин и читай его раздел)

| Термин / вопрос | Раздел |
|---|---|
| что уже играбельно, файлы, консольные команды | «Что уже работает (этапы 0–3)» |
| что входит / не входит в v0 | «Границы» |
| кто чем владеет, host vs client | «Модель авторитета» |
| результаты аудита gateway-монополии | «Аудит: состояние кодовой базы» |
| как команда доезжает до хоста | «Транспорт команд» |
| join, снапшот, догон | «Join / снапшот» |
| lobby, как подключиться | «Join / снапшот»; «Границы» |
| правки террейна по сети | «Terrain replication» |
| позы ровера, тряска, double precision | «Physics replication» |
| игрок на ровере, кресло | «Игрок на движущемся теле» |
| инвентарь на N игроков | «Per-peer store» |
| скафандр, кислород, смерть | «Per-peer player state» |
| HUD у клиента | «Presentation на клиенте» |
| сейв хоста на N игроков | «Persistence» |
| порядок реализации, этапы | «Implementation order» |
| критерии приёмки | «Acceptance» |
| RC checklist (eyeball / gate) | «Release candidate» |
| известные риски | «Риски» |

## Границы

**Входит в v0:**

- listen-server: хост играет и одновременно держит авторитетное состояние;
- 2–4 peer'а, ENet, `SceneMultiplayer`, LAN + прямой IP; подключение через
  консоль `host` / `join <ip>` (LimboConsole), без lobby UI;
- общий мир: террейн, постройки, машины, индустрия, лут;
- ходьба, бур, строительство, инвентарь, панели HUD у всех;
- сейв у хоста, per-peer позиция и инвентарь в одном файле;
- катание на ровере как **пассажир/водитель в кресле**.

**НЕ входит в v0:**

- античит и валидация клиентов (кооп с друзьями — клиенту доверяем);
- dedicated server;
- client-side prediction для собственного персонажа сложнее, чем локальное
  движение + мягкая коррекция от хоста;
- ходьба по движущейся платформе (стоя на едущем ровере) — см. «Риски»;
- lobby UI / browser сессий / matchmaking — только IP + консоль; UI invite /
  список игр — отдельная веха поверх `CoopSession` (обсуждалось, не в v0);
- co-pilot seat / расширенные permissions в `passenger_seat` — позже;
- репликация летающих обломков террейна (`dig_terrain_debris`) — far future;
- NAT punchthrough, Steam/EOS транспорт, relay;
- миграция хоста при выходе хоста (хост выходит → сессия кончилась).

## Модель авторитета

```text
Client                          Host
------                          ----
input, aim raycast, HUD         SimulationWorld (авторитет)
      │                         WorldCommandGateway (единственный мутатор)
      │  submit(cmd) ─────rpc──▶│
      │                         VoxelTool (правки террейна)
      │                         Jolt (физика сборок)
      │◀──── command_completed ─┤
      │◀──── state deltas ──────┤
```

Инвариант **C1**: клиент **не мутирует** `SimulationWorld` и `VoxelTool`
никогда. Любое изменение мира — только через `WorldCommandGateway.submit()`
на хосте.

Инвариант **C2**: команда — plain `Dictionary` из сериализуемых типов
(int/float/String/StringName/bool/Vector3/массивы/словари). Никаких
`Object`/`Node`/`Resource` внутри команды. `RefCounted`-команды
(`PlaceElementCommand` и пр.) строятся **на хосте** внутри gateway из
словаря — как сейчас.

Инвариант **C3**: прицеливание (`InteractionQuery`, `VoxelTool.raycast`)
считается **на клиенте**, результат едет в поле `target` команды. Хост его
не пересчитывает (v0 — доверяем).

## Аудит: состояние кодовой базы

Проверено на текущем `main`. Монополия gateway на игровом пути **соблюдена**.

**Хорошо (менять не надо):**

- `WorldCommandGateway.submit()` ([world_command_gateway.gd:107](../../scripts/world_command_gateway.gd))
  — единственная точка входа, уже принимает `Dictionary`, уже даёт
  `command_id` и `command_completed(command_id, result)`. ~25 kind'ов.
  Это готовый RPC-шов.
- Прямые вызовы `world.apply_*` вне gateway встречаются только в:
  - `scripts/authoring/*` — редакторный/oneshot-инструментарий, в рантайме
    кооп-сессии не участвует;
  - `scripts/simulation/**` — внутренности симуляции, исполняются на хосте;
  - `scripts/test_*` — headless-тесты.

  Игровой путь (`tool_controller.gd`, `construction_placement.gd`,
  `scripts/ui/*`) ходит **только** через `submit()`.
- `SimulationWorld.capture_snapshot()` уже используется
  `WorldPersistence` — готовый join-снапшот.
- `MeteoriteSystem` берёт `VoxelTool` только на raycast (чтение) —
  запись идёт через gateway. Норм.
- `drill.gd` — только звук/VFX, мира не трогает.

**Требует правки (это и есть работа v0):**

| # | Что | Где | Почему | Статус |
|---|---|---|---|---|
| A1 | `store_id: String = "player"` — единственный глобальный инвентарь | `place_element_command.gd:13`, `weld_element_command.gd:6`, `dismantle_element_command.gd:6`, `repair_element_command.gd:6`, `construction_placement.gd`, `construction_snap_resolver.gd:71`, `industry_store_service.gd:4` | на 4 игроков один общий рюкзак | ✅ этап 1 |
| A2 | HUD читает `world` напрямую | ~15 файлов `scripts/ui/hud_*.gd` | у клиента нет `world` | ✅ закрыто иначе, чем планировалось: клиент держит настоящую read-only реплику `world` (этап 2), HUD-файлы не тронуты вообще |
| A3 | Один игрок захардкожен: спавн, settle, `VoxelViewer` | `bootstrap.gd` (`_player`, `_ensure_player_viewer_for_planet`, `_find_voxel_viewer`) | нужен per-peer спавн и свой `VoxelViewer` на каждого | частично: локальный игрок каждого клиента спавнится/settle'ится как раньше; на хосте у `RemotePlayer` — collision-only `VoxelViewer` proxy (R-COOP-7) для dig far from host |
| A4 | `SuitState` — Node на сцене игрока, вне `SimulationWorld` | `suit_state.gd` | не реплицируется, не сохраняется per-peer. **Решено переносить в мир** — см. «Per-peer player state» | ✅ этап 1b |
| A5 | Правки террейна применяются локально и никуда не публикуются | `terrain_excavation_service.gd`, `terrain_impact_carver.gd` | клиент не увидит выкопанное | частично: спайк B — live `_cli_dig_op` + session `_dig_ops` на join; RC — cold dig SQLite+granular bulk (`terrain_bulk` / CH_BULK); `dig_terrain_debris` far future; форма `terrain_edits` **superseded** |
| A6 | Позы сборок живут только в Jolt на хосте | `simulation_physics_projection.gd`, `assembly_motion_state.gd` | клиент не увидит движение | частично: спайк C — `_cli_assembly_motion` 30 Гц + kinematic interp; колёса — scalar reconstruct; без interest / f64-пакета исходной спеки |

A1 — не архитектурная проблема, а дефолтное значение параметра: `store_id`
уже параметризован везде. Достаточно убрать дефолты и проставлять
`store_id` на границе gateway из `peer_id` отправителя.

## Что уже работает (этапы 0–3)

Реализовано (`f50df72` реплика-мир, `db36f54` транспорт, `35c0e70`
disambiguation фикс). Разделы ниже («Транспорт команд», «Join / снапшот»)
описывают исходный план — читай их для намерения, этот раздел — для того,
что реально в коде и чем оно отличается.

**Файлы:**

- `scripts/coop/coop_session.gd` — единственный узел со всеми `@rpc`
  (в `main.tscn`), консольные команды, ENet, реле поз, ребродкаст снапшота,
  join/leave.
- `scripts/coop/coop_command_codec.gd` — статический класс: санитайзер
  команд (вырезает `source`/`target.collider`/`placement_plan` + рекурсивно
  любые Object), блок-лист kind'ов, сборка/валидация join-payload,
  хендшейк-поля.
- `scripts/coop/coop_peer_registry.gd` — host-side таблица `peer_id ↔ uid`.
- `scripts/coop/remote_player.gd` + `scenes/remote_player.tscn` — аватар
  другого игрока: капсула + ник (Label3D) + фонарь (SpotLight3D), без
  физтела, интерполяция ~120 мс.
- `WorldCommandGateway.set_network_submit()` / `submit_as()` /
  `complete_remote()` — сетевой шов гейтвея (см. «Транспорт команд» ниже —
  реализовано близко к плану, actor_uid стемпится в `_flush` per-command).
- `SimulationWorld.sync_suit_state()` — новый санкционированный путь записи
  реплики (семейство `sync_*`): держит O2-бар клиента живым между полными
  снапшотами (1 Гц).
- `SimulationWorld.sync_resource_stores()` /
  `sync_element_industry_buffers()` / `sync_player_inventories()` —
  **interim этапа 5** (не полная delta-система): `CoopSession` шлёт на
  CH_STREAM 1 Гц только изменившиеся сторы/буферы/инвентари (`_cli_stores`),
  чтобы HUD клиента не замерзал между полными снапшотами (dig credits,
  transfer, machine buffers). Топология по-прежнему едет полным
  `capture_snapshot` / `restore_snapshot`. Клиент остаётся read-only (C1).

**Консольные команды** (LimboConsole): `host [port=7777]`,
`join <ip> [port=7777]`, `leave`, `nick <name>`, `coop_status`.

**Видимость построек — не дельты, а полный снапшот-ребродкаст.**
Отклонение от плана «Terrain replication»/дельт: после структурного
изменения на хосте (кроме террейна и amount-only industry — см. interim
этапа 5) — дебаунс 0.3 с + пол ~1.5 с между отправками — хост шлёт **весь**
`capture_snapshot()`, клиент применяет через `restore_snapshot()`
(санкционированный путь этапа 2). Работает, но с ростом базы (сотни
деталей) каждый ребилд у клиента ощутим — настоящие дельты остаются
задачей этапа 5.

**Блок-лист вместо частичной поддержки.** Клиент не может слать
`dig_terrain_debris`, `debug_spawn_spoil`, `place_block` — гейтвей отвечает
`not_in_coop_yet` вместо попытки и десинка. `voxel_remove` / `scoop_spoil` /
`dump_scoop` разрешены со спайк-этапа B (op-ребродкаст). `toggle_control_seat`
снят с блок-листа со спайк-этапа C: хост клеймит occupancy, клиент
присасывается к реплике кресла на `ok`; руль едет отдельным
`_srv_control_input` на CH_INPUT (unreliable_ordered, свой seq — не делит
канал с позами); не команда гейтвея (иначе snapshot-шторм). Сломанное /
удалённое кресло эмитит `seat_occupant_evicted` → хост force-eject + reliable
`_cli_force_seat_release`; E без occupancy всё равно отцепляет.

**Отклонение от T2 (float32/PackedFloat64Array).** Позиции едут как обычный
`Vector3`, не `PackedFloat64Array`. Обоснование в
`coop_command_codec.gd`: оба пира гарантированно на одном кастомном
double-precision билде (друг получает наш экспорт), поэтому Variant кодирует
позиции как f64 сквозно; `real_t_bits` в хендшейке жёстко отсекает
несовместимый (float32) билд до того, как координаты начнут расходиться.
Луна тут Ø~19 км, не 1737 км спеки — запас по эпсилону тоже больше, чем
предполагалось изначально.

**Дизамбигуация одной машины.** Два окна на одной машине раньше читали один
`user://player_uid.txt` и не видели друг друга (совпадающий uid → клиент
принимал хоста за себя). Починено loopback-мьютексом
(`127.0.0.1:47800` в `_ready()`): первый процесс держит порт и оставляет
свой сохранённый uid, второй не может забиндиться и берёт
uid + случайный суффикс. Хост дополнительно явно отказывает джойну с uid,
совпадающим с его собственным (`uid_is_host`), вместо тихой немоты. Флаг
`--coop-sandbox=<label>` всё ещё доступен, если нужна дополнительная
изоляция `user://` (сейв/dig-стрим) для локальной отладки.

**Персистенс клиента.** Пока подключён — сохранения полностью запрещены
(`bootstrap.set_coop_persistence_inhibited`), собственный прогресс
однократно флашится перед приёмом снапшота хоста
(`save_now_then_inhibit_persistence`). `leave` / отключение хоста —
`reload_current_scene()`, без попытки «разреплицировать на месте».

**Проверено:** `tests/run_one.sh test_coop_codec` (санитайзер, блок-лист,
реестр, join-payload round-trip, `sync_suit_state`, interim
`sync_resource_stores` / buffers / inventories) — чистая логика,
сетевые потоки не покрыты тестами, верификация только вручную (два
инстанса).

## Транспорт команд

`WorldCommandGateway` получает сетевой фасад. Клиент:

```gdscript
# на клиенте
gateway.submit_networked(cmd)  # → rpc_id(1, "_remote_submit", cmd)
```

Хост в `_remote_submit` (`@rpc("any_peer", "call_local", "reliable")`):

1. `peer := multiplayer.get_remote_sender_id()`;
2. проставляет `cmd["actor_peer"] = peer` и `cmd["store_id"] = "player:%d" % peer`
   (перетирая всё, что прислал клиент — клиент не выбирает чужой рюкзак);
3. кладёт в существующую очередь `_queue`;
4. после `_execute` шлёт `result` обратно `rpc_id(peer, "_remote_result", local_id, result)`.

`command_id` остаётся локальным счётчиком клиента: клиент присылает свой
`local_id`, хост возвращает его в ответе. Так HUD-код, который ждёт
`command_completed`, продолжает работать без изменений.

Канал: `reliable`, дефолтный. Порядок команд от одного peer сохраняется —
это важно для последовательности «поставил блок → приварил».

**Открытый вопрос O1:** `_flush()` сейчас идёт через `call_deferred` в
произвольный момент кадра. Для сети надо привязать флаш к `_physics_process`
хоста, чтобы порядок команд был детерминирован относительно тика симуляции.

## Join / снапшот

**Подключение (v0).** Lobby UI / browser сессий **нет** — только прямой IP и
консоль LimboConsole: `host [port=7777]`, `join <ip> [port]`, `leave`,
`coop_status`. Локальная отладка: `tools/coop_two_windows.bat` или флаги
`--coop-autohost` / `--coop-sandbox=guest --coop-autojoin`. **Lobby** (список
открытых игр, invite flow, опционально relay/NAT) обсуждался как следующий
UX-слой поверх того же `CoopSession` — host-authoritative модель не меняется;
в v0 не реализован.

При подключении peer'а хост шлёт **один** payload:

```gdscript
{
  "protocol": 1,
  "seed": ...,                     # MoonTerrainParams
  "generator_version": MoonTerrainParams.GENERATOR_VERSION,
  "simulation": world.capture_snapshot(),   # уже есть
  "dig_ops": [...],                # ops after dig-stream flush (см. Terrain)
  "terrain_bulk": { ... },         # optional cold dig SQLite meta (+ inline/chunks)
  "peers": { peer_id: {"name": ..., "pose": ...} },
  "you": peer_id,
}
```

Join UX: roster-аватары (хост + peers) спавнятся у гостя сразу после
`restore_snapshot`, **до** ожидания `terrain_bulk`; позы буферятся в
`_pose_inbox`, пока RemotePlayer ещё нет. Иначе гость 15–20 с не видит
хоста (bulk / kick viewers), хотя хост гостя уже видит. Assembly-motion
на клиенте принимается только после `_replica_ready` (конец join).

Планируемое поле `terrain_edits` из ранней спеки **superseded** формой
`build_dig_op` / `dig_ops` (live + join tail) и отдельным каналом
`terrain_bulk` (байты host `moon.sqlite` + granular snapshot) — второй
сетевой лог geometric edits не строить.

Клиент отклоняет коннект при несовпадении `protocol` или
`generator_version` — иначе террейн разъедется молча (та же проверка, что
уже есть в `WorldPersistence.read_payload`).

До применения снапшота клиент держит игрока в spawn-lock
(`set_spawn_locked(true)`) — переиспользуем существующий settle-механизм
из `player_controller.gd`, он ровно для этого.

**Ограничение v0:** join только в момент, когда мир уже готов; join во
время активной физики сборок допускается, позы приедут следующим дельта-пакетом.

## Terrain replication

Террейн детерминирован от сида; `capture_snapshot` **не** несёт воксели.
По сети — два согласованных канала (не geometric `terrain_edits`):

1. **Live / session ops** — `build_dig_op` по CH_MAIN (`_cli_dig_op`) и
   хвост `dig_ops` в join payload → `replay_remote_dig`. Кинды:
   `voxel_remove` / `scoop_spoil` / `dump_scoop`. Кольцо
   `MAX_DIG_OPS=8192` — truncate oldest + warn. `_dig_ops.clear()` на `host`.
2. **Cold dig bulk (RC)** — перед join host `flush_digs_for_coop_join`, затем
   байты `moon.sqlite` + `GranularVoxelWorld.capture_field_snapshot` как
   `terrain_bulk` (inline ≤384 KiB или чанки `_cli_terrain_bulk_chunk` по
   CH_BULK). Клиент после inhibit пишет replica
   `user://coop_join_replica/moon.sqlite` (не personal `gen_vN`),
   `apply_coop_terrain_bulk` (swap stream + kick viewer + granular restore).
   Join `dig_ops` = только ops **после** flush (избежать double-carve).

Acceptance digs RC: session после Host **и** pre-host / post-restart holes
из SQLite bulk. `dig_terrain_debris` — far future (блок-лист).

Исходный эскиз `terrain_edits` ниже — исторический; **не реализовывать**.

```gdscript
# superseded — не строить; см. dig_ops / terrain_bulk выше
{"c": Vector3 (world, f64!), "r": float, "mode": int, "mat": int, "seq": int}
```

**Ловушка T1:** у клиента чанк под правкой может быть ещё не загружен.
Session `dig_ops` — pending-reapply когда editable. Cold bulk опирается на
stream swap: незагруженные области подтянут host digs при стриминге с
replica DB.

**Ловушка T2:** `c` — мировая координата на лунном радиусе (~1737 км).
Godot RPC пакует `Vector3` как **float32** → ошибка порядка метра. Для
текущего коопа оба пира на одном double-precision билде (`real_t_bits` в
хендшейке); см. «Что уже работает». Исторический фолбэк — `PackedFloat64Array`
или offset от чанк-origin (`5f4e9bf`).

## Physics replication

**Модель v0 (owner-authoritative locomotion):**

- **Мир** (террейн, dig, стройка, сейв, припаркованные сборки) — всегда
  хост. Инвариант C1 для команд мира не меняется.
- **Едущий ровер / корабль**, пока peer в кресле **водителя** — считает
  **тот peer, кто рулит** (полный Jolt + wheel joints локально).
- **Остальные** (включая хоста, если рулит гость) держат kinematic ghost и
  берут сглаженный state stream.

Исторический эскиз «только хост Jolt, клиент никогда не симулирует» —
superseded для **локомотивных** сборок с живым водителем. Пассажир /
пешком / стоящие машины по-прежнему без client Jolt.

**Стрим observers** (`_cli_assembly_motion`, CH_STREAM, ~30 Гц,
`unreliable_ordered`):

- корень + не-колёсные body groups — world pose + velocity;
- **колёса не едут как body transforms** (world/rel slerp спина давал дрожь
  на кочках/в воздухе): в пакете только скаляры на колесо
  (`compression_m`, `steering_angle_rad`, `wheel_speed_rad_s` + group id);
  observer ставит kinematic wheel = strut × compression × steer × spin,
  spin интегрируется локально из скорости;
- клиентский буфер ~100 мс (как `RemotePlayer`).

Гость-водитель шлёт state на хост (`_srv_assembly_motion`); хост применяет к
ghost и ретранслирует зрителям. Руль гостя применяется **локально** у
водителя (не петля `_srv_control_input` → хост → стрим назад). Команды мира
(dig/build) по-прежнему через gateway на хосте.

**Инварианты owner-sim (playtest regressions):**

- upload `_srv_assembly_motion` не зависит от observer stream buffer (гость
  один за рулём → buffer пуст; иначе хост-ghost никогда не двигается);
- `toggle_control_seat` в `NO_BROADCAST_KINDS` — seat-ok / ownership без
  full snapshot mid-drive;
- host parking-freeze **не** thaw'ит `_ghost_assemblies` (mirrored
  `drive_command` иначе снимает freeze с jointless ghost → ragdoll);
- перед unghost / seat-exit last streamed pose коммитится в kernel motion;
- host ghost переписывает wheel `body_group_motions` из scalars (колёса
  больше не в `"m"`) — иначе electric radius видит колёса в точке посадки
  и гасит `powered` у уехавшего гостя.

Актуаторы (поршни/роторы) на observers — позы групп из стрима / snapshot;
полная client-side actuator sim — вне этой вехи.

## Игрок на движущемся теле

Самая дорогая часть. Решение v0 — **обойти проблему, а не решать**:

- вход в кресло (`toggle_control_seat`) на хосте клеймит occupancy
  (`SimulationWorld._player_seat_contexts`); локальный актёр ещё и
  репарентится в тело (`enter_vehicle`). Удалённый актёр на хосте
  occupancy-only — клиент сам зовёт `apply_local_seat_attach` на своей
  реплике. В позе едет `"seat": element_id`, аватар садится на локальную
  реплику кресла (без интерполяции `p`);
- управление водителя — локально у того, кто в кресле (`tick_rover_locomotion_input`
  / `apply_driver_frame` на его машине). Гость больше не гоняет руль через
  `_srv_control_input` на хост ради ощущений езды; хост получает **state**
  сборки и держит kinematic ghost. (Legacy `_srv_control_input` может
  остаться как фолбэк до land owner-sim — не критерий приёмки.);
- выход из кресла — release occupancy + `clear_driver_input`; клиент
  зовёт `release_local_seat_attach`. Сломанное кресло: `seat_occupant_evicted`
  → force-eject + `_cli_force_seat_release`; клиентский фолбэк если
  элемент/body исчезли из реплики.

Пассажирское кресло (спайк D, `passenger_seat`): **только freelook** —
вращение камеры, без руля / `_srv_control_input`. Строительный тулбар и
compact action bar скрыты (`is_in_vehicle` + `controls_permitted() == false`);
из кресла нельзя переключать инструменты и слать игровые команды. Co-pilot
seat / permissions — позже.

Хождение **стоя** на едущем ровере в v0 не поддерживается: клиент локально
предсказывает свой `CharacterBody3D`, а платформа приезжает с лагом →
дрожь и проваливание. См. «Риски».

Собственный персонаж: клиент двигает себя локально (авторитет клиента над
своей позой — это кооп, не соревнование), шлёт позу 20 Гц
`unreliable_ordered`, хост ретранслирует остальным. Хост корректирует
только при грубом нарушении (проваливание под террейн).

## Per-peer store

`IndustryStoreService.PLAYER_STORE_ID` (`"player"`) → `player_store_id(peer_id)`
→ `"player:%d" % peer_id`.

- дефолты `store_id: String = "player"` в командах **убрать** (сделать
  обязательным полем) — чтобы забытый прокид не превратился молча в
  общий рюкзак;
- `cargo_transfer_service.gd` сравнивает `store_id == PLAYER_STORE_ID` в
  6 местах — заменить на `IndustryStoreService.is_player_store(store_id)`;
- `store_snapshot_builder.gd` / `industry_transfer_util.gd` — берут
  store текущего локального игрока;
- снапшот мира уже сериализует стор по id — per-peer сторы поедут
  автоматически.

Peer id меняется между сессиями, поэтому в сейве стор ключуется **не** по
peer id, а по стабильному `player_uid` (генерится клиентом один раз,
хранится в его `user://`). Маппинг `peer_id → player_uid` живёт у хоста
на время сессии.

## Per-peer player state

**Решено: `SuitState` переносится в `SimulationWorld`.** Рассматривался
более дешёвый вариант (оставить тик на клиенте + отсылка значений хосту
2 Гц), он отклонён: состояние жило бы в двух местах, смерть игрока
пришлось бы подтверждать отдельным протоколом, а сейв и репликация
требовали бы своего механизма. Скафандр по сути такой же ресурс, как
заряд батареи, и должен жить там же.

Сейчас [suit_state.gd](../../scripts/suit_state.gd) — `Node` на сцене
игрока, который сам себе тикает в `_process`. После переноса:

- состояние скафандров — часть мира: `world.suit_state(player_uid)`
  возвращает значения, `world.apply_suit_damage(player_uid, amount, source)`
  их меняет, тик идёт в `_physics_process` хоста вместе с индустрией;
- попадает в `capture_snapshot()` → едет в join-снапшот и в сейв
  существующим механизмом, ничего специального писать не надо;
- смерть — обычное состояние мира, расхождений между клиентами нет
  по построению.

Затрагиваемые вызовы (весь список):

| Место | Сейчас | После |
|---|---|---|
| [hud_vitals.gd:22](../../scripts/ui/hud_vitals.gd) | `ctx.get("suit")`, duck-typing по `changed` / `*_fraction()` | тот же интерфейс, но объект — лёгкий view поверх состояния мира; сам HUD не меняется |
| [impact_resolver.gd:120](../../scripts/simulation/runtime/impact_resolver.gd) | `player_suit_state(partner)` — поиск узла `"SuitState"` | `player_uid_of(partner)` |
| [impact_resolver_service.gd:586](../../scripts/simulation/runtime/impact_resolver_service.gd) | `suit.apply_damage(...)` | `world.apply_suit_damage(uid, ...)` |
| [meteorite_system.gd:379](../../scripts/meteorite_system.gd) | то же | то же |
| `test_suit_state.gd`, `test_impact_destruction.gd` | конструируют `SuitState.new()` | конструируют мир и дёргают его API |

Тик остаётся детерминированно вызываемым извне (как сейчас флаг
`simulate`) — headless-тесты на этом держатся.

**Важно:** узловой поиск `player_suit_state()` заодно работает как
предикат «этот коллайдер — игрок» (`impact_resolver_service.gd:226,363`).
При переносе этот предикат надо вынести явно, иначе логика попадания по
игроку тихо сломается.

## Presentation на клиенте

У клиента нет `SimulationWorld` с живым тиком, но **есть** его реплика:
клиент держит `SimulationWorld`, в который применён join-снапшот и
последующие дельты. Тик индустрии на клиенте отключён
(`IndustrySimulation.tick` не вызывается) — состояние приезжает по сети.

Это позволяет оставить ~15 `scripts/ui/hud_*.gd` **без изменений**: они
читают `world` как и раньше, просто у клиента это read-only реплика.

Дельты состояния (уровни сторов, статусы машин, очереди рецептов) —
20 Гц, `unreliable_ordered`, только изменившиеся элементы, только в
радиусе интереса + элементы, чью панель peer сейчас открыл.

**Открытый вопрос O2:** объём дельт для крупной базы (сотни элементов) в
GDScript. Мерить на этапе 4; если не тянет — переводить дельты на
`PackedByteArray` через `snapshot_codec.gd`.

## Persistence

`WorldPersistence.save()` (v0):

```gdscript
{
  "save_version": 4,
  "simulation": ...,          # сторы + suits + player_inventories per-uid
  "players": {                # cold pose map (было: singular "player" в v3)
    "<player_uid>": {
      "pose": {"position": [x,y,z], "body_yaw": ..., "head_pitch": ...},
    },
  },
  # dig: session dig_ops / локальный SQLite хоста — не поле terrain_edits
  "map_markers": ...,
}
```

**Hotbar / tool instances** — per-uid `PlayerInventoryRegistry` в
`SimulationWorld` (`player_inventories` в simulation snapshot, рядом с
`suits`). Seed на join (`_seed_joiner`) и на fresh world; gateway reads /
hotbar assign / tool transfers идут по `actor_uid`. Не класть отдельное
`"hotbar"` в cold `players{}` — источник истины уже в `simulation`.
**Suit** — тоже только в `simulation.suits`; cold `players{}` не дублирует.

**Cold poses** — хост пишет local uid + session `_last_poses` (гости) в
`players{}` (merge, чтобы autosave до rejoin не затирал чужие uid). После
рестарта хоста `host` сидит `_last_poses` из cold → join `you_pose` /
reseat как session rejoin.

**Миграции нет.** Игра не выпущена, сейвы существуют только как локальные
dev-файлы, поэтому `save_version` просто поднимается (3 → 4 при вводе
`players{}`; ранее 2 → 3 для per-uid hotbar), а старый payload
отбрасывается существующей проверкой в `WorldPersistence.read_payload`
(она уже возвращает `{}` при несовпадении версии). Dev wipe OK. Писать
конвертер ради локальных файлов — чистые расходы.

Сейв пишет **только хост**; клиенты своё локальное состояние не сохраняют.

## Implementation order

Этапы независимо проверяемы; каждый — отдельный коммит.

| # | Этап | Статус | Проверяемо |
|---|---|---|---|
| 0 | Ввести инварианты C1–C3 в `AGENTS.md`; статик-проверка «нет `world.apply_*` вне host-путей» | ✅ | grep-гейт зелёный |
| 1 | `player_uid`, `store_id` per-peer, убрать дефолты `"player"`, `is_player_store()`, поднять `save_version` (без конвертера — см. «Persistence») | ✅ (`271c9ea`) | `run_one.sh test_industry_v1`, `test_store_snapshot` зелёные, одиночная игра не сломана |
| 1b | `SuitState` → `SimulationWorld` (см. «Per-peer player state»); обновить `PHYSICAL-LANGUAGE.md` «Состояние скафандра» и `HUD-UI-01.md` в том же коммите | ✅ (`55504c1`) | `run_one.sh test_suit_state`, `test_impact_destruction` зелёные; метеорит бьёт игрока в запущенной игре |
| 2 | `SimulationWorld` как read-only реплика: флаг `authoritative`, отключаемый тик; snapshot apply на клиенте | ✅ (`f50df72`) | новый `test_*` на «снапшот → реплика идентична» — `test_snapshot_replica` |
| 3 | Транспорт: ENet, host/join, `_remote_submit`, join-снапшот, спавн N игроков (`bootstrap.gd`, per-peer `VoxelViewer`) | ✅ (`db36f54`, `35c0e70`) — см. «Что уже работает»; host per-peer collision-only `VoxelViewer` (R-COOP-7) | два инстанса, видим друг друга, ходим; guest dig far from host |
| 4 | Terrain replication (session dig_ops + SQLite/granular bulk на join) | частично (спайк B + join `dig_ops` + RC `terrain_bulk`; без debris) | session digs live; late join — session tail + cold SQLite holes |
| 5 | Дельты состояния мира + HUD у клиента | interim: 1 Гц `_cli_stores` (changed stores/buffers/inventories); полный snapshot — топология; полные дельты — later | копаем/крафтим/transfer — HUD сторов у клиента оживает ≤1 с без snapshot-storm |
| 6 | Physics replication (owner loco + observer stream) | в работе: scalar wheel reconstruct + 30 Гц + owner-authoritative driver Jolt; observers kinematic | водитель (хост или гость) едет как в одиночке; зрители — кочки/руль/спин без дрожи |
| 7 | Кресло: `seated`, ввод водителя, выход, PAX | частично (спайк C+D: occupancy + `toggle_control_seat` + `_srv_control_input` + `passenger_seat`; без ходьбы на платформе) | водитель (cockpit, хост или гость) ведёт; PAX — только freelook, тулбар скрыт |

Этапы 0–2 не требовали сети и были полезны сами по себе. Этап 3 + спайк
A–D в коде — кооп играбелен для пробного забега; глазная приёмка A–D ещё
открыта (см. `COOP_SPIKE_PLAN.md`).

## Acceptance

- Хост и 3 клиента в одной сессии, 30+ минут без рассинхрона;
- клиент выкопал яму **в текущей сессии (после Host)** → хост и другие видят
  (±0 вокселей); late join получает session dig tail + cold `terrain_bulk`
  (SQLite dig-stream / granular) для ям до `host` и после рестарта хоста;
- клиент поставил и приварил блок → у хоста та же сборка, ресурсы списаны
  с **его** стора, стор хоста не тронут;
- хост сохранил, все вышли, зашли снова → мир, сторы, per-uid hotbar/
  tool inventories и per-uid cold позы (`players{}` → session last-pose
  seed → join reseat);
- водитель (хост или гость в cockpit) ведёт ровер; второй peer в
  пассажирском кресле едет без рывков на ~100 мс RTT, freelook, без руля;
  у пассажира **нет тулбара** — только вращение камеры;
- паритет ощущений езды хост ≈ гость — продуктовая цель (не «гость гладкий
  достаточно»);
- отключение клиента не роняет хоста; отключение хоста корректно
  завершает сессию у всех.

Финальное подтверждение — человек в игре на двух машинах. «Тест зелёный»
не считается доказательством (см. `AGENTS.md`, «Верификация»).

## Release candidate

Короткий ship-gate для co-op RC. Не расширяет scope — только locked
решения + уже лежащий в main код спайка A–D / R-COOP-7 / last-pose /
slip-brake. Глазная приёмка обязательна; headless gate — sanity, не
доказательство.

**Locked (не пересматривать в RC-коммите):**

- PAX = только freelook; строительный тулбар скрыт, игровые команды из кресла
  не шлются
- Acceptance digs = session digs после `host` **и** cold SQLite/granular bulk
  на join (не через `capture_snapshot`)
- Hotbar в сейве — только после реального per-uid inventory (не фейкать поле)
- Паритет ощущений езды хост ≈ гость — продуктовая цель
- `MAX_DIG_OPS=8192` остаётся для live/session ring; ring truncate + warn,
  join не отказывать
- RT / day-night / viewmodel probes — **не** в RC coop commit

| # | Проверка | Как | Статус |
|---|---|---|---|
| RC-1 | Eyeball A–D | два окна / Tailscale: tool в руках + взгляд; live dig виден обоим; водитель ведёт (хост↔гость); пассажир на `passenger_seat` | ⬜ human |
| RC-2 | PAX policy | в `passenger_seat`: freelook ок; тулбар / compact bar скрыты; только камера | ⬜ human |
| RC-3 | R7 far dig | гость копает далеко от хоста (proxy `VoxelViewer`); soft-retry / toast «Грунт ещё загружается», затем яма у обоих | ⬜ human |
| RC-4 | Brakes | service brake на грунте — slip-limited (как drive TC); нет сильной тряски колёс у хоста при торможении гостем-водителем | ⬜ human |
| RC-5 | Late join | session digs + **cold** digs до `host` / после рестарта (`terrain_bulk`) | ⬜ human |
| RC-6 | Rejoin pose | disconnect → join тем же uid → session last-pose; cold `players{}` после рестарта хоста → seed `_last_poses` → `you_pose` | ⬜ human |
| RC-7 | Headless gate | `test_coop_codec`, `test_coop_seat`, `test_coop_dig_replay`, `test_control_actions`, `test_seat_input_router`, `test_snapshot_replica` | ⬜ run |

Практический сценарий: `tools/coop_two_windows.bat` или `host` /
`join 127.0.0.1` (+ `--coop-sandbox=guest` для dig). Финал — две машины.

**Блокеры RC после параллельных агентов (hotbar / SQLite dig bulk / store
interim sync):** см. актуальный список в `docs/COOP_SPIKE_PLAN.md` §
«Release candidate» — глазная таблица выше + merge/verify тех трёх слайсов
без RT-мусора.

## Риски

| Риск | Вероятность | Митигация |
|---|---|---|
| **R-COOP-1** Ходьба по движущемуся ровера — тряска/проваливание | высокая | v0: только кресло. Полноценно — только с prediction движущегося парента, это отдельная веха |
| **R-COOP-2** float32 в RPC ломает координаты на лунном радиусе | снята для стемпа поз этапа 3 | оба пира — один double-precision билд, `Vector3` кодируется как f64 сквозно, `real_t_bits` в хендшейке отсекает несовместимый билд (см. «Что уже работает»). Остаётся актуальным для этапа 6 (физика сборок) — перепроверить на живой сборке, не только на позе игрока |
| **R-COOP-3** Правка террейна в незагруженный чанк теряется | высокая | лог правок + переприменение при загрузке чанка (T1) |
| **R-COOP-4** Объём дельт не тянет в GDScript | средняя | мерить в этапе 5; фолбэк — бинарный кодек |
| **R-COOP-5** Каждая новая фича теперь обязана ходить через сеть | 100% | это постоянный налог, а не риск. Инвариант C1 делает нарушение заметным |
| **R-COOP-6** Оценка этапов 6–7 может поехать вдвое | средняя | контрольная точка после этапа 3 |
| **R-COOP-7** Хост не стримит террейн вокруг чужих игроков (`VoxelViewer` только у локального) | снята (host proxy) | Host: `RemotePlayer.enable_host_stream_proxy` — child `VoxelViewer` с `requires_visuals=false`, `view_distance=MoonGeometry.DEFAULT_LOD_DISTANCE` (Clipbox multi-viewer). Guest dig `terrain_unavailable` while proxy shell loads: host soft-retries dig kinds up to 2× / 0.3 s (≤3 tries, no extra RPCs); guest HUD already toasts «Грунт ещё загружается» (`hud_feedback`). Playtest: guest dig far from host. Клиентские remote-аватары без viewer |

## Оценка

Порядок: этапы 0–3 ≈ 1–2 недели плотной работы, этапы 4–7 ≈ 2–4 недели.
Этапы 6–7 — единственные с реальным риском промаха по срокам.
