# Voxel Tools multiplayer/co-op dig — research (host FPS)

Дата: 2026-07-25. Метод: WebSearch/WebFetch официальной доки
`voxel-tools.readthedocs.io` + GitHub issues `Zylann/godot_voxel`. Только
research — код не менялся.

## TL;DR (RU, для пользователя)

1. **Официальной многопользовательской поддержки для `VoxelLodTerrain`
   формально нет.** Страница [Multiplayer](https://voxel-tools.readthedocs.io/en/latest/multiplayer/)
   описывает протокол только для `VoxelTerrain` (блочный, без LOD); секция
   «With `VoxelLodTerrain`» прямо говорит: *«There is no support for now,
   but it is planned»*. Regolith использует `VoxelLodTerrain` — мы уже вне
   документированного пути, host-authoritative ENet-подход (не RPC-протокол
   плагина) — это осознанный обход, не баг конфигурации.
2. Второй `VoxelViewer` для гостя (не для рендера, а чтобы `is_area_editable`
   работал вокруг него) — это именно то, что советует автор плагина в issue
   [#676](https://github.com/Zylann/godot_voxel/issues/676): *«put a
   `VoxelViewer` on these bodies... you may also need to turn off visuals
   for these extra viewers»*. То, что у нас уже есть в `remote_player.gd`
   (`requires_visuals=false`, `requires_collisions=true`,
   `streaming_system=CLIPBOX`) — это **правильный паттерн**, не хак.
3. **Просадка FPS не в стриминге, а в физике.** Официальная дока
   [Performance](https://voxel-tools.readthedocs.io/en/latest/performance/#shape-creation-is-very-slow)
   прямо пишет: создание физического коллайдера из меша в 3–5 раз (в другом
   месте — до 10–20 раз) дороже, чем сам меш, **и обязано выполняться в
   главном потоке** — Godot не даёт thread-safe `PhysicsServer3D`. Это общий
   с локальным потоком бюджет `voxel/threads/main/time_budget_ms` (дефолт
   ~8 мс/кадр, в проекте не переопределён). Второй viewer с
   `requires_collisions=true`, который двигается (пассажир на ровере) —
   это гарантированно больше коллайдеров в той же очереди главного потока,
   которую делит с ним локальный игрок.
4. Второй канал деградации — Vulkan: [«Slowdown when moving fast with
   Vulkan»](https://voxel-tools.readthedocs.io/en/latest/performance/#slowdown-when-moving-fast-with-vulkan) —
   *разрушение* mesh-буферов на GPU дороже создания и тоже происходит в
   главном потоке. Быстро двигающийся второй viewer (ровер) удваивает
   churn чанков (создание+удаление), даже если у него `requires_visuals =
   false` — это влияет на **collision**-меши тоже, не только визуальные.
5. Итог: «дёрг + движение» = два независимых источника нагрузки на один и
   тот же главный поток (коллайдеры под гостем + коллайдеры под
   быстро двигающимся ровером), которые физически не могут работать
   параллельно в Godot 4 (нет thread-safe PhysicsServer). Это архитектурное
   ограничение плагина/движка, не баг Regolith-кода.

## 1. Официальная документация — multiplayer

`https://voxel-tools.readthedocs.io/en/latest/multiplayer/`

Два задокументированных паттерна, оба только для `VoxelTerrain` (без LOD):

- **2023/04/13 — `VoxelNetworkTerrain*` / `VoxelTerrainMultiplayerSynchronizer`.**
  Server-authoritative. На сервере: `VoxelViewer` на игрока с
  `network_peer_id` + `requires_data_block_notifications=true`;
  `requires_visuals=false` для чужих viewer'ов («*it's normally not
  necessary to render their surroundings*»). Клиент: свой `VoxelViewer`
  чуть больше view_distance сервера (иначе дыры от выгрузки), **не** ставит
  viewer на remote-аватары.
- **2022/01/31 — ручной скриптинг** (`_on_data_block_entered`,
  `_on_area_edited`, `get_viewer_network_peer_ids_in_area`,
  `try_set_block_data`, `VoxelBlockSerializer`). То же принципиально:
  сервер шлёт блоки/дельты, клиент пассивно применяет.
- **`With VoxelLodTerrain`: «There is no support for now, but it is
  planned.»** — буквальная цитата, актуальна и на `/latest/`, и на
  `/stable/`.
- **Protocol notes**: RPC в Godot — UDP (reliable/unreliable); для больших
  объёмов voxel-данных плагин предлагает TCP, но признаёт сложность
  (два порта) и склоняется к reliable UDP.
- **«Other points to explore»**: block caching/versioning на клиенте,
  client-request модель вместо push, diff-map 1 бит/воксель для частичных
  правок при известном seed.

Важно: страница не обновлялась под появление `STREAMING_SYSTEM_CLIPBOX`
(это видно по датам — секции 2022/2023, а Clipbox — более поздняя фича).
Т.е. **Clipbox решает задачу «несколько viewer'ов на одном терейне»**,
но не задачу «сеть» — она относится к другому слою (streaming), не к
синхронизации правок между машинами. Regolith правильно развёл эти два
слоя сам: Clipbox — для локального multi-viewer стриминга у host, ENet —
для сети.

## 2. `VoxelViewer` / Clipbox — API-контракт

`https://voxel-tools.readthedocs.io/en/latest/api/VoxelViewer/`,
`https://voxel-tools.readthedocs.io/en/latest/api/VoxelLodTerrain/`

- `VoxelViewer.requires_visuals` (default **true**) — «*generate meshes
  around this viewer... may be enabled for the local player*» (implying:
  выключай для чужих).
- `VoxelViewer.requires_collisions` (default **true**).
- `VoxelViewer.requires_data_block_notifications` (default false) — нужен
  только для сетевого паттерна выше (уведомление сервера о новых блоках
  для пира); Regolith это не использует, т.к. у нас нет плагинового
  network-протокола.
- `VoxelViewer.view_distance_vertical_ratio` — **только под Clipbox**, для
  других систем стриминга не работает.
- `VoxelLodTerrain.streaming_system`:
  - `STREAMING_SYSTEM_LEGACY_OCTREE` (default!) — **не** поддерживает
    несколько viewer'ов, **не** поддерживает collision-only viewer'ы, не
    поддерживает per-viewer view_distance.
  - `STREAMING_SYSTEM_CLIPBOX` — concentric boxes; поддерживает multiple +
    collision-only viewers; «*This is a better system for multiplayer
    streaming*»; трейд-офф — менее оптимальное размещение чанков на каждом
    LOD, чем legacy octree.
- `debug_draw_viewer_clipboxes` — визуальный дебаг границ каждого viewer'а
  под Clipbox; полезно для живой диагностики (см. §6).
- `VoxelLodTerrain.lod_distance` vs `secondary_lod_distance` — второй
  параметр **только под Clipbox**: позволяет держать большой LOD0 (для
  edit-reach) и при этом ограничить, насколько далеко тянутся LOD>0
  вокруг того же viewer'а — прямой рычаг против «второй viewer = ещё один
  полный терейн».

## 3. GitHub issues — паттерны и грабли

- **[#676](https://github.com/Zylann/godot_voxel/issues/676)
  «how prevent rigidbody3d dont go through terrain»** — авторский совет:
  ставить `VoxelViewer` на любое физическое тело, которое должно иметь
  коллайдеры вдалеке от игрока (ровер, NPC, гость); включать Clipbox;
  «*you may also need to turn off visuals for these extra viewers*»; и
  прямое предупреждение: *«putting a VoxelViewer on these bodies... in
  itself also makes things more expensive»* — доп. viewer **всегда**
  стоит денег, даже без визуалов, потому что коллайдеры/данные вокруг
  него всё равно генерируются на главном потоке.
- **[#150](https://github.com/Zylann/godot_voxel/issues/150)** —
  `VoxelBoxMover` (AABB-физика плагина) заметно дешевле стандартного
  Jolt/Bullet, но требует блочного (не smooth Transvoxel) терейна — не
  применимо к лунному ландшафту Regolith как есть.
- **[#124](https://github.com/Zylann/godot_voxel/issues/124)
  «Create collision shapes from the meshing thread»** — до сих пор
  открыт: PhysicsServer3D не thread-safe, коллайдер обязан строиться на
  главном потоке; автор пометил это блокером до апстрим-фикса в Godot
  (proposal [#483](https://github.com/godotengine/godot-proposals/issues/483),
  всё ещё не решён).
- **[#225](https://github.com/Zylann/godot_voxel/issues/225)
  «Real Time Edition Issues»** — рекомендует диагностику через
  `VoxelServer.get_stats()` / `VoxelLodTerrain.get_statistics()` →
  `remaining_main_thread_blocks`: если это число долго не падает к 0 —
  бутылочное горлышко именно в главном потоке (мешинг/коллайдеры), не в
  логике; и «*if you don't need collision shapes while sculpting, turning
  them off can give a big boost*».
- **[#72](https://github.com/Zylann/godot_voxel/issues/72) /
  [#97](https://github.com/Zylann/godot_voxel/issues/97)** — спам edits
  каждый кадр (или в `_process` без рейт-лимита) может: (а) оставлять
  недомешенные дырки на границах блоков, (б) при большом объёме — рост
  памяти без ограничения (копии блоков быстрее создаются, чем поглощаются
  тредом мешинга). Автор явно предлагает лимитировать частоту правок к
  «предыдущей edited-позиции» вместо `_process`/`_input`.
- **[#640](https://github.com/Zylann/godot_voxel/issues/640)** —
  экспериментальная ветка `clipbox_deferred_merges`: артефакты мерджа
  чанков при **быстром** движении viewer'а назад под Clipbox; не влита
  (сложность). Значит быстро двигающийся ровер-viewer под Clipbox может
  давать визуальный мерцающий артефакт помимо стоимости — известное,
  неисправленное поведение апстрима.
- **[#57](https://github.com/Zylann/godot_voxel/issues/57)** — дырки при
  ремеше на стыке блоков — тюнится `voxel/threads/main/time_budget_ms`
  (больше времени на кадр главному потоку под мешинг/коллайдеры, но выше
  риск подвисания) либо принудительный main-thread flush рядом с
  игроком.

## 4. Официальный паттерн host-auth dig sync (обобщение §1–3)

1. **Host = единственный владелец `VoxelTool`-правок.** Клиенты никогда
   не вызывают `do_sphere`/`do_box` напрямую на своей копии терейна —
   ровно так, как уже сделано в Regolith (`_gateway.replay_remote_dig`
   на host, `dig_ops` broadcast клиентам).
2. **Каждый удалённый актор с editable-требованием получает свой
   `VoxelViewer`, но без визуалов.** `requires_visuals=false`,
   `requires_collisions` — по потребности (`true`, если нужен физический
   коллайдер под гостем; `false`, если нужны только данные для
   `is_area_editable`, без физики).
3. **`STREAMING_SYSTEM_CLIPBOX` обязателен**, как только больше одного
   viewer'а или нужен collision-only viewer — legacy octree их не
   поддерживает вообще (не «плохо работает» — API откажет).
4. **Дельты, не полные блоки.** Плагин отправляет либо целые
   сериализованные блоки (`VoxelBlockSerializer`), либо (в scripting-
   паттерне) diff по площади. Regolith уже шлёт компактные dig-op'ы
   (команда + результат), что ближе духом к «diff», чем к «shipping
   VoxelBuffer» — это не противоречит рекомендациям плагина.
5. **Рейт-лимит правок.** Официальный совет (#225, #72) — не дёргать
   `VoxelTool` из `_process` без throttle; лимитировать по расстоянию от
   предыдущей edit-позиции. Стоит сверить `terrain_excavation_service.gd`
   / drill-tick на наличие throttle для **гостевых** дигов конкретно (не
   только локальных).
6. **Главный поток — общий, единый ресурс.** `time_budget_ms` не делится
   по «источнику» нагрузки (гость vs локальный игрок vs ровер-viewer) —
   это одна очередь. Не существует официального способа «дать host-у
   больше бюджета под гостя» — единственный официальный рычаг:
   **уменьшить количество/стоимость коллайдеров**, которые нужно строить
   одновременно (view_distance гостевого viewer'а, `secondary_lod_distance`,
   `collision_lod_count`, временное отключение collision-стрима под
   активным дигом).

## 5. Regolith сейчас — что совпадает, что может конфликтовать

Прочитано: `scripts/coop/remote_player.gd` (`HostStreamViewer`),
`scripts/coop/coop_session.gd` (dig_ops/broadcast), `scenes/main.tscn`
(`VoxelLodTerrain`), `scripts/simulation/runtime/terrain_excavation_service.gd`.

**Совпадает с советом плагина:**

- Host = единственный владелец правок; клиенты только применяют
  `replay_remote_dig` — ровно server-authoritative паттерн из доки.
- `HostStreamViewer`: `requires_visuals=false`, `requires_collisions=true`
  — именно то, что советует #676 и multiplayer-дока (в доке это про
  визуализацию, а не рендер; но принцип «дай коллайдеры без мешей» —
  Clipbox collision-only viewer, задуман ровно под это).
- Условие `_host_needs_terrain_stream`: viewer создаётся только когда
  гость реально копает (`_tool_id == &"drill"`), не всегда — снижает
  число одновременных viewer'ов до необходимого минимума. Это шаг дальше
  официального примера (там viewer один раз создаётся на join и живёт
  всегда), и разумен как оптимизация, раз плагин прямо пишет «putting a
  VoxelViewer on these bodies... in itself makes things more expensive».
- Seated (driver/passenger): гостевой terrain-viewer отключается —
  комментарий в коде прямо ссылается на регресс 30 FPS от движущегося
  viewer, что совпадает с официальным разделом «Slowdown when moving fast
  with Vulkan» (движущийся viewer = churn создания/удаления чанков и их
  коллайдеров на главном потоке — дороже, чем стоящий на месте).

**Потенциальный источник конфликта / необследованное:**

- ✅ **`STREAMING_SYSTEM_CLIPBOX` подтверждён** —
  `scripts/bootstrap.gd:394` явно ставит
  `lod.streaming_system = VoxelLodTerrain.STREAMING_SYSTEM_CLIPBOX`
  (default терейна в `main.tscn` не переопределён, но код делает это в
  runtime до старта стрима); также задокументировано в
  `docs/specs/MOON-EXPERIMENT-V0.md`. Снимает риск «мультивьюер на
  неподдерживаемом legacy octree» — это **не** источник регресса.
- **`voxel/threads/main/time_budget_ms` не переопределён** — дефолт ~8 мс.
  Дока прямо говорит: увеличение бюджета ускоряет постройку
  меша/коллайдера за счёт риска подвисаний. Не проверено, играет ли
  Regolith этим рычагом; это дешёвый эксперимент для playtest (см. §7).
- **`_host_needs_terrain_stream` создаёт/убивает viewer динамически** —
  сам плагин не документирует «частое create/destroy VoxelViewer»; неясно,
  дёшева ли пересборка Clipbox-состояния при add_child/queue_free
  viewer'а на каждый toggle инструмента, или это дополнительный скачок
  нагрузки в момент начала дига (ещё один источник «2-5 FPS именно когда
  начинается дриллинг»).
- **Гостевой `view_distance` = `MoonGeometry.DEFAULT_LOD_DISTANCE` (48
  вокселей)** — это разумно мало относительно локального `view_distance =
  512` на терейне, но при Clipbox `secondary_lod_distance` (LOD>0 вокруг
  того же viewer'а) не тронут явно — если он не занижен, гостевой viewer
  всё равно тащит несколько LOD-уровней вокруг себя, а не только LOD0,
  даже если `requires_visuals=false` (LOD>0 всё ещё стримит **данные**,
  которые нужны для мешинга/коллайдеров LOD0→1 переходов).
- **Нет явного рейт-лимита на гостевые дигы** отдельно от локальных —
  `terrain_excavation_service.excavate` не просмотрен полностью на предмет
  throttle по времени/дистанции для remote-команд специфично; #225/#72
  советуют это как первую линию защиты против «spam edits каждый кадр».

## 6. Диагностика, доступная из VT (для playtest, не для этого research)

- `VoxelServer.get_stats()` / `VoxelLodTerrain.get_statistics()` →
  `remaining_main_thread_blocks` — если во время «дриллинг + движение»
  число стабильно не падает к нулю, бутылочное горлышко подтверждено на
  стороне коллайдеров/мешинга главного потока, а не логики Regolith.
- `debug_draw_viewer_clipboxes = true` на `VoxelLodTerrain` — визуально
  показывает границы каждого active viewer'а; можно на живом host'е
  увидеть, раздувается ли гостевой clipbox при посадке в ровер / дриллинге
  сильнее ожидаемого.
- `debug/settings/stdout/verbose_stdout` — упомянутый в доке как
  (специфичный для GL, менее релевантный на Vulkan, но дешёво проверить)
  workaround тайминга.

## 7. Конкретные рекомендации для Regolith (actionable, без гарантий — верифицировать в игре)

1. ~~Подтвердить `streaming_system = CLIPBOX`~~ — уже подтверждено
   (`bootstrap.gd:394`), можно не проверять.
2. **Проверить `remaining_main_thread_blocks` живьём** через
   `VoxelLodTerrain.get_statistics()` в момент «дриг + движение на
   ровере» — подтвердит/опровергнет гипотезу «bottleneck = коллайдеры
   главного потока», прежде чем тратить время на другие теории (сеть,
   GDScript-логика coop_session).
3. **Занизить `secondary_lod_distance` для Clipbox** отдельно от
   `lod_distance`, если ещё не сделано — держит LOD0 достаточно большим
   для edit-reach гостя, но не тащит LOD>0 далеко вокруг гостевого
   viewer'а.
4. **Эксперимент с `voxel/threads/main/time_budget_ms`** — дешёвый A/B на
   playtest: приподнять с дефолтных ~8 мс и замерить, снижается ли
   просадка при готовности пожертвовать пиковыми стирками кадра ради
   средней устойчивости.
5. **Рейт-лимит на гостевые дигы** конкретно (не только "дриллер тикает
   раз в N мс локально") — если `terrain_excavation_service`/coop-command
   path не throttle-ит частоту `do_sphere` из replay guest-команд отдельно
   от локальных, добавить нижнюю границу интервала — прямая рекомендация
   #225/#72.
6. **Профилировать именно момент toggle `_ensure_host_stream_viewer` /
   `_release_host_stream_viewer`** — частое add_child/queue_free
   `VoxelViewer` при входе/выходе из дриллинга может сама быть всплеском
   (Clipbox должен пересчитать все viewer'ы при добавлении/удалении
   одного из них). Если подтвердится — рассмотреть держать viewer
   постоянным (как в официальном примере — создаётся один раз на join),
   но с `view_distance = 0` в неактивном состоянии вместо
   destroy/recreate, если API это позволяет (не проверено — надо сверить
   документацию `VoxelViewer.view_distance` на предмет `0` = «не
   стримить»).
7. **Собрать статистику через `debug_draw_viewer_clipboxes` на живом
   host'е** во время воспроизведения регресса — визуально сравнить размер
   гостевого clipbox с ожидаемым (48 вокселей LOD0), убедиться что он не
   раздувается сам по себе.

## 8. Что осталось неизвестным / нужен playtest

- Не подтверждено эмпирически на этом терейне, **что именно** доминирует
  во время «guest dig + rover motion»: (а) коллайдеры под host
  локальным игроком vs (б) коллайдеры/данные под гостевым
  `HostStreamViewer` vs (в) сам Clipbox-пересчёт при движении ровера
  (если у ровера/сидений есть свой viewer помимo пассажирского) vs (г)
  чистая логика `coop_session.gd` (RPC/сериализация dig_ops) — этот
  research не профилировал, только собрал официальные источники
  деградации. Нужен реальный `get_statistics()`-снимок на воспроизведённом
  регрессе.
- Неизвестно поведение Clipbox при частом create/destroy `VoxelViewer`
  (не задокументировано явно ни в API, ни в issues, которые попались в
  этом поиске) — стоит либо найти более специфичный issue, либо
  протестировать эмпирически.
- Неизвестна текущая стоимость самого RPC/сериализации `dig_ops` в
  `coop_session.gd` относительно VT-стороны — не входило в scope этого
  research (только VT, не ENet-слой Regolith), но раз главный поток общий
  между VT-коллайдерами и Godot's `rpc()`-обработкой, конкурирующая
  нагрузка возможна и там.

## Ссылки (полный список)

- https://voxel-tools.readthedocs.io/en/latest/multiplayer/
- https://voxel-tools.readthedocs.io/en/latest/performance/
- https://voxel-tools.readthedocs.io/en/latest/api/VoxelViewer/
- https://voxel-tools.readthedocs.io/en/latest/api/VoxelLodTerrain/
- https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/
- https://github.com/Zylann/godot_voxel/issues/676
- https://github.com/Zylann/godot_voxel/issues/150
- https://github.com/Zylann/godot_voxel/issues/124
- https://github.com/Zylann/godot_voxel/issues/225
- https://github.com/Zylann/godot_voxel/issues/72
- https://github.com/Zylann/godot_voxel/issues/97
- https://github.com/Zylann/godot_voxel/issues/57
- https://github.com/Zylann/godot_voxel/issues/640
- https://github.com/Zylann/godot_voxel/issues/292
- https://github.com/godotengine/godot-proposals/issues/483
