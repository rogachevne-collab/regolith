# Coop (host-authoritative) v0

Статус: этапы 0–3 реализованы и играбельны; спайк A–D в main (`eb66171`
и др.) — копка op-каналом, стрим сборок, кресло водителя/пассажира,
session `dig_ops` на join. Этапы 4–7 спеки частично перекрыты спайком
(см. Implementation order); приёмка глазами A–D ещё не закрыта. См. «Что
уже работает» и `docs/COOP_SPIKE_PLAN.md`. Цель — кооп на 2–4 игрока: один
игрок = хост (listen server), остальные подключаются, сессия и сейв живут
у хоста.

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
| правки террейна по сети | «Terrain replication» |
| позы ровера, тряска, double precision | «Physics replication» |
| игрок на ровере, кресло | «Игрок на движущемся теле» |
| инвентарь на N игроков | «Per-peer store» |
| скафандр, кислород, смерть | «Per-peer player state» |
| HUD у клиента | «Presentation на клиенте» |
| сейв хоста на N игроков | «Persistence» |
| порядок реализации, этапы | «Implementation order» |
| критерии приёмки | «Acceptance» |
| известные риски | «Риски» |

## Границы

**Входит в v0:**

- listen-server: хост играет и одновременно держит авторитетное состояние;
- 2–4 peer'а, ENet, `SceneMultiplayer`, LAN + прямой IP (без релея/lobby);
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
- копка / инструменты / K-панель из пассажирского кресла (PAX = sit + look
  only; co-pilot / permissions — позже; инвентарь из кресла — ок);
- репликация летающих обломков террейна (`dig_terrain_debris`) — far future;
- bulk пересылка dig SQLite «соло-история хоста до host» — later dig-channel;
- NAT punchthrough, Steam/EOS транспорт;
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
| A5 | Правки террейна применяются локально и никуда не публикуются | `terrain_excavation_service.gd`, `terrain_impact_carver.gd` | клиент не увидит выкопанное | частично: спайк B — live `_cli_dig_op` + session `_dig_ops` на join (`build_dig_op`); `dig_terrain_debris` в блок-листе (far future); pre-host SQLite bulk — later debt; форма `terrain_edits` из спеки **superseded** |
| A6 | Позы сборок живут только в Jolt на хосте | `simulation_physics_projection.gd`, `assembly_motion_state.gd` | клиент не увидит движение | частично: спайк C — `_cli_assembly_motion` 15 Гц + kinematic interp; без interest / f64-пакета исходной спеки |

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

**Консольные команды** (LimboConsole): `host [port=7777]`,
`join <ip> [port=7777]`, `leave`, `nick <name>`, `coop_status`.

**Видимость построек — не дельты, а полный снапшот-ребродкаст.**
Отклонение от плана «Terrain replication»/дельт: после структурного
изменения или изменения стора/лута на хосте (кроме террейна) — дебаунс
0.3 с + пол 1.0 с между отправками — хост шлёт **весь**
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
реестр, join-payload round-trip, `sync_suit_state`) — чистая логика,
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

При подключении peer'а хост шлёт **один** payload:

```gdscript
{
  "protocol": 1,
  "seed": ...,                     # MoonTerrainParams
  "generator_version": MoonTerrainParams.GENERATOR_VERSION,
  "simulation": world.capture_snapshot(),   # уже есть
  "dig_ops": [...],                # session dig log since host (см. Terrain replication)
  "peers": { peer_id: {"name": ..., "pose": ...} },
  "you": peer_id,
}
```

Планируемое поле `terrain_edits` из ранней спеки **superseded** формой
`CoopCommandCodec.build_dig_op` / массивом `dig_ops` — второй сетевой лог
правок не строить.

Клиент отклоняет коннект при несовпадении `protocol` или
`generator_version` — иначе террейн разъедется молча (та же проверка, что
уже есть в `WorldPersistence.read_payload`).

До применения снапшота клиент держит игрока в spawn-lock
(`set_spawn_locked(true)`) — переиспользуем существующий settle-механизм
из `player_controller.gd`, он ровно для этого.

**Ограничение v0:** join только в момент, когда мир уже готов; join во
время активной физики сборок допускается, позы приедут следующим дельта-пакетом.

## Terrain replication

Террейн детерминирован от сида, поэтому воксели по сети не гоняем — только
**лог подтверждённых dig-операций** сессии после `host`.

**Факт кода (спайк B):** не отдельный геометрический `terrain_edits`
`{c,r,mode,mat,seq}`, а санитайзнутый op (`build_dig_op`) по CH_MAIN
(`_cli_dig_op` live + массив `dig_ops` в join payload → `replay_remote_dig`).
Кинды: `voxel_remove` / `scoop_spoil` / `dump_scoop`. Кольцо
`MAX_DIG_OPS=8192` на хосте — truncate oldest + warn, join не отказываем;
лимит держим до SQLite bulk. Acceptance digs = **session digs после Host**;
соло-история до `host` (SQLite dig-stream bulk) — later debt, не критерий
сейчас. `dig_terrain_debris` — far future (блок-лист).

Исходный эскиз `terrain_edits` ниже — исторический; **не реализовывать
вторым каналом**.

```gdscript
# superseded — не строить; см. dig_ops / build_dig_op выше
{"c": Vector3 (world, f64!), "r": float, "mode": int, "mat": int, "seq": int}
```

**Ловушка T1:** у клиента чанк под правкой может быть ещё не загружен
(`VoxelTerrain` стримит вокруг своего `VoxelViewer`). Правку в незагруженный
чанк применять нельзя — её съест генератор при загрузке. Решение v0:
хост хранит session-лог (`_dig_ops`); клиент при необходимости догоняет
pending-reapply, когда область становится editable. Полный SQLite bulk +
переприменение при загрузке чанка — later.

**Ловушка T2:** `c` — мировая координата на лунном радиусе (~1737 км).
Godot RPC пакует `Vector3` как **float32** → ошибка порядка метра. Для
текущего коопа оба пира на одном double-precision билде (`real_t_bits` в
хендшейке); см. «Что уже работает». Исторический фолбэк — `PackedFloat64Array`
или offset от чанк-origin (`5f4e9bf`).

## Physics replication

Хост — единственный, кто гоняет Jolt. Клиент не симулирует сборки вообще:
`SimulationPhysicsProjection` на клиенте создаёт тела как `FREEZE_MODE_KINEMATIC`
и только ставит им позы из сети.

Пакет поз, `unreliable_ordered`, 20 Гц, только для сборок в радиусе
интереса peer'а (~200 м):

```gdscript
{"a": assembly_id, "p": PackedFloat64Array(3), "q": Quaternion, "v": Vector3, "w": Vector3}
```

- позиция — **f64** (см. T2), ориентация — кватернион f32 (точности хватает);
- клиент интерполирует между пакетами с буфером ~100 мс;
- `v`/`w` нужны для экстраполяции при потере пакета.

Актуаторы (поршни/роторы/шарниры) — состояние мотора едет в общем пакете
сборки как массив углов/вылетов; клиент проецирует визуал существующими
`*_projection_util.gd`, не пересчитывая физику.

## Игрок на движущемся теле

Самая дорогая часть. Решение v0 — **обойти проблему, а не решать**:

- вход в кресло (`toggle_control_seat`) на хосте клеймит occupancy
  (`SimulationWorld._player_seat_contexts`); локальный актёр ещё и
  репарентится в тело (`enter_vehicle`). Удалённый актёр на хосте
  occupancy-only — клиент сам зовёт `apply_local_seat_attach` на своей
  реплике. В позе едет `"seat": element_id`, аватар садится на локальную
  реплику кресла (без интерполяции `p`);
- управление водителя-гостя — НЕ команда гейтвея, а `_srv_control_input`
  на CH_INPUT 20 Гц → `apply_remote_driver_input` (команда на 20 Гц
  устроила бы snapshot-шторм через `_on_host_command_completed`). Хост
  по-прежнему тикает свой руль через `tick_rover_locomotion_input()`;
- выход из кресла — release occupancy + `clear_driver_input`; клиент
  зовёт `release_local_seat_attach`. Сломанное кресло: `seat_occupant_evicted`
  → force-eject + `_cli_force_seat_release`; клиентский фолбэк если
  элемент/body исчезли из реплики.

Пассажирское кресло (спайк D, `passenger_seat`): **sit + look only** — freelook,
без руля / `_srv_control_input`, без копки и инструментов, без K-панели
(co-pilot seat / permissions — позже). Инвентарь из кресла — ок.

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

`WorldPersistence.save()` расширяется (цель v0, не спайк):

```gdscript
{
  "save_version": 2,
  "simulation": ...,          # без изменений, сторы уже per-peer
  "players": {                # было: "player": {...}
    "<player_uid>": {"pose": ..., "suit": ...},
  },
  # dig: session dig_ops / локальный SQLite хоста — не поле terrain_edits
  "map_markers": ...,
}
```

**Hotbar в сейве** — важно для продукта, но **отложено** после session
last-pose rejoin. Пока один `PlayerInventoryRegistry` на мир — не фейкать
`"hotbar"` в `players{}` (иначе поле врёт с первого дня). Порядок: session
last-pose по uid → затем per-uid inventory + hotbar + bump сейва.

**Миграции нет.** Игра не выпущена, сейвы существуют только как локальные
dev-файлы, поэтому `save_version` просто поднимается, а старый payload
отбрасывается существующей проверкой в `WorldPersistence.read_payload`
(она уже возвращает `{}` при несовпадении версии). Писать и тестировать
конвертер ради файлов, которые можно удалить, — чистые расходы. Если к
моменту работ появится сейв, который жалко, — это решение надо
пересмотреть, а не обходить.

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
| 4 | Terrain replication (session dig_ops; SQLite bulk / chunk-reapply — later) | частично (спайк B + join `dig_ops`; без SQLite bulk / debris) | копаем в сессии после Host — видно у обоих; late join видит session digs |
| 5 | Дельты состояния мира + HUD у клиента (сейчас — полный снапшот-ребродкаст, см. «Что уже работает») | — | строим/крафтим — HUD у обоих совпадает |
| 6 | Physics replication (позы сборок, f64) | частично (спайк C: `_cli_assembly_motion` 15 Гц, без f64-пакета спеки) | ровер едет — обоим видно гладко; цель — паритет ощущений хост ≈ гость |
| 7 | Кресло: `seated`, ввод водителя, выход, PAX | частично (спайк C+D: occupancy + `toggle_control_seat` + `_srv_control_input` + `passenger_seat`; без ходьбы на платформе) | водитель (cockpit, хост или гость) ведёт; PAX = sit + look only |

Этапы 0–2 не требовали сети и были полезны сами по себе. Этап 3 + спайк
A–D в коде — кооп играбелен для пробного забега; глазная приёмка A–D ещё
открыта (см. `COOP_SPIKE_PLAN.md`).

## Acceptance

- Хост и 3 клиента в одной сессии, 30+ минут без рассинхрона;
- клиент выкопал яму **в текущей сессии (после Host)** → хост и другие видят
  (±0 вокселей); late join получает session `_dig_ops`. Соло-ямы до Host /
  cold SQLite bulk — later debt, не критерий сейчас;
- клиент поставил и приварил блок → у хоста та же сборка, ресурсы списаны
  с **его** стора, стор хоста не тронут;
- хост сохранил, все вышли, зашли снова → мир и сторы; per-peer позы —
  цель (session last-pose → cold `players{}`); hotbar в сейве — postponed
  после last-pose, не фейкать;
- водитель (хост или гость в cockpit) ведёт ровер; второй peer в
  пассажирском кресле едет без рывков на ~100 мс RTT, freelook, без руля;
  пассажир **не** копает, **не** использует инструменты и **не** открывает
  K-панель из кресла (sit + look only; инвентарь — ок);
- паритет ощущений езды хост ≈ гость — продуктовая цель (не «гость гладкий
  достаточно»);
- отключение клиента не роняет хоста; отключение хоста корректно
  завершает сессию у всех.

Финальное подтверждение — человек в игре на двух машинах. «Тест зелёный»
не считается доказательством (см. `AGENTS.md`, «Верификация»).

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
