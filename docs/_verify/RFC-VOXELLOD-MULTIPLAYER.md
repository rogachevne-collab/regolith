# RFC: Multiplayer-поддержка для `VoxelLodTerrain` (Voxel Tools)

Статус: черновик-предложение (research + design), НЕ implementation. Написан
так, как если бы это был реальный RFC/issue-предложение в
`zylann/godot_voxel`. Код не менялся, коммитов нет.

Дата: 2026-07-25.

**Источники ground truth:**

- Полный C++ исходник модуля локально: `Y:\godot_voxel`, git
  `a584c4d6537171d016a7abf4510eddfcc6a66a89` (`v1.6-121-ga584c4d6`,
  fork поверх `Zylann/godot_voxel` master). Remote `origin` —
  <https://github.com/Zylann/godot_voxel.git>; remote `fork` —
  <https://github.com/rogachevne-collab/godot_voxel.git>. На этом форке уже
  есть 3 неслитых в `origin/master` коммита от команды проекта
  (`9420b751`, `5a412196`, `a584c4d6` — SQLite transaction-race hardening,
  автор Yaroslav Rogachev) — т.е.у команды уже есть реальный (пусть пока не
  влитый) опыт патчить именно этот модуль, не только читать его.
- Официальная дока `voxel-tools.readthedocs.io` (через `doc/source/*.md` в
  том же чекауте — она версионирована вместе с кодом).
- Прежний research в этом репозитории (переиспользован, не передублирован):
  `docs/_verify/VOXEL-TOOLS-COOP-DIG.md` (issues, официальные паттерны),
  `docs/_verify/COLLIDER-SQLITE-CACHE-FEASIBILITY.md` (SQLite-схема,
  масштаб Ø19 км, почему коллайдер некэшируем).
- Regolith как живой кейс: `scripts/coop/coop_session.gd`,
  `scripts/coop/coop_terrain_bulk.gd`, `scripts/coop/remote_player.gd`,
  `scripts/bootstrap.gd`, `docs/COOP_SPIKE_PLAN.md`.

Всё, что не подтверждено чтением исходника/доки, помечено **ГИПОТЕЗА**.
Числа стоимости без реального профайлинга — как в исходных research-доках —
считаются **NOT_PROFILED**.

---

## 1. Проблема и цель

Официальная позиция апстрима (`doc/source/multiplayer.md:63-66`, дословно):

```
With `VoxelLodTerrain`
------------------------

There is no support for now, but it is planned.
```

и (`multiplayer.md:4`): «Not all the features of the engine are supported,
it is still very experimental and might change in the future» — это
предупреждение относится даже к уже существующей MP-поддержке
`VoxelTerrain` (не-LOD), не говоря про LOD.

Regolith использует именно `VoxelLodTerrain` (Ø19 км планетоид,
Transvoxel/smooth) и уже построил рабочий host-authoritative кооп поверх
недокументированной комбинации `VoxelViewer` + Clipbox + ручной ENet-слой в
GDScript (`docs/COOP_SPIKE_PLAN.md`, этапы A–D в main). Вопрос RFC:
**что реально означало бы «поддержка мультиплеера» для `VoxelLodTerrain` на
уровне движка**, и стоит ли это делать вместо/вместе с прикладным слоем.

### Скоуп предложения (что должно быть покрыто)

1. **Авторитетные правки** — один источник истины для voxel-данных, у
   клиентов нет собственной, независимо мутирующей копии.
2. **Late join** — новый пир получает согласованное состояние мира без
   передачи полного дерева LOD с нуля в реальном времени.
3. **Дивергенция стриминга** — у каждого пира свой viewer/clipbox с разным
   view distance/позицией; правка должна корректно лечь в мип-пирамиду
   независимо от того, что именно у пира сейчас загружено.
4. **Персистентность** — сохранение/восстановление согласуется с сетевой
   моделью (кто пишет на диск, кто просто держит рантайм-копию).

### Скоуп НЕ покрыт (сознательно, не то же RFC)

- Client-side prediction/interpolation правок (Regolith сознательно её не
  делает — `docs/COOP_SPIKE_PLAN.md` этап C, «Латенцию руля гостя принять»).
- Dedicated server без графики/физики хоста — отдельная большая тема.
- Полная физическая репликация RigidBody-объектов поверх террейна — не
  относится к terrain-слою как таковому.

---

## 2. Что уже есть в апстриме

### 2.1 `VoxelTerrain` (fixed LOD, блочный) — реальная MP-поддержка есть

Это **не** только паттерн в доке — есть выделенный класс:

| Путь | Роль |
|---|---|
| `terrain/fixed_lod/voxel_terrain_multiplayer_synchronizer.h/.cpp` | `VoxelTerrainMultiplayerSynchronizer : public Node` |
| `terrain/fixed_lod/voxel_terrain.h` | `set_multiplayer_synchronizer()` / `get_multiplayer_synchronizer()` |
| `doc/source/multiplayer.md` | руководство по настройке |
| `doc/classes/VoxelTerrainMultiplayerSynchronizer.xml` | ClassDB-документация |

```cpp
// terrain/fixed_lod/voxel_terrain_multiplayer_synchronizer.h:18-20
class VoxelTerrainMultiplayerSynchronizer : public Node {
    GDCLASS(VoxelTerrainMultiplayerSynchronizer, Node)
```

```cpp
// terrain/fixed_lod/voxel_terrain_multiplayer_synchronizer.cpp:22-30
VoxelTerrainMultiplayerSynchronizer::VoxelTerrainMultiplayerSynchronizer() {
    Dictionary config;
    config["rpc_mode"] = MultiplayerAPI::RPC_MODE_AUTHORITY;
    config["transfer_mode"] = MultiplayerPeer::TRANSFER_MODE_RELIABLE;
    rpc_config(VoxelStringNames::get_singleton()._rpc_receive_blocks, config);
    rpc_config(VoxelStringNames::get_singleton()._rpc_receive_area, config);
```

Модель: `RPC_MODE_AUTHORITY` + `TRANSFER_MODE_RELIABLE` — сервер шлёт целые
блоки/площади, клиент только принимает. Дока (`multiplayer.md:20-24`):

> On the server: Add `VoxelTerrain` … Add a `VoxelTerrainMultiplayerSynchronizer`
> node as child … When a player joins, make sure a `VoxelViewer` is
> created … Assign its `network_peer_id` and enable
> `requires_data_block_notifications`.

Второй, более старый паттерн («ручной») тоже задокументирован
(`multiplayer.md`, секция 2022/01/31): `_on_data_block_entered`,
`get_viewer_network_peer_ids_in_area`, `try_set_block_data`,
`VoxelBlockSerializer` — тот же принцип (сервер решает, клиент применяет),
но без выделенного класса.

**`VoxelLodTerrainMultiplayerSynchronizer` не существует** — искали по
`*multiplayer*`, `LodTerrain.*[Mm]ulti` во всём дереве, ничего не нашли.

### 2.2 `VoxelViewer`

Файлы: `terrain/voxel_viewer.h/.cpp`.

| Свойство | Тип/default | Замечание |
|---|---|---|
| `view_distance` | `unsigned int` / 128 | `ADD_PROPERTY` |
| `view_distance_vertical_ratio` | `float` / 1.0 | только под Clipbox |
| `requires_visuals` | `bool` / true | |
| `requires_collisions` | `bool` / true | |
| `requires_data_block_notifications` | `bool` / false | нужен для сетевого паттерна §2.1 |
| **`network_peer_id`** | **`int` / -1** | **есть как поле + get/set методы, НО не в `ADD_PROPERTY`** (voxel_viewer.cpp:239-254) — виден в API только как метод, не как редактируемое свойство |

```cpp
// terrain/voxel_viewer.cpp:73-81
void VoxelViewer::set_network_peer_id(int id) {
    _network_peer_id = id;
    if (is_active()) {
        VoxelEngine::get_singleton().set_viewer_network_peer_id(_viewer_id, id);
    }
}
```

**Открытый вопрос (ГИПОТЕЗА, не проверено в этом проходе):** используется ли
`network_peer_id` хоть где-то в коде Clipbox-стриминга
(`voxel_lod_terrain_update_clipbox_streaming.cpp`)? В прочитанных фрагментах
это не встретилось — судя по всему, поле сегодня осмысленно только для
`VoxelTerrainMultiplayerSynchronizer` (fixed-LOD), а для `VoxelLodTerrain`
это мёртвый атрибут. Нужен отдельный grep перед тем как на это полагаться в
дизайне.

### 2.3 `VoxelLodTerrain.streaming_system`

```cpp
// terrain/variable_lod/voxel_lod_terrain_update_data.h:54-57
enum StreamingSystem : uint8_t {
    STREAMING_SYSTEM_LEGACY_OCTREE = 0,
    STREAMING_SYSTEM_CLIPBOX
};
```

**Legacy Octree (default!):** один общий `OctreeStreamingState` на весь
терейн, единственная позиция «viewer» на весь стриминг:

```cpp
// terrain/variable_lod/voxel_lod_terrain_update_octree_streaming.h:9-12
// Limitations:
// - Supports only one viewer
// - Still assumes a viewer exists at world origin if there is actually no viewer
// - Does not support viewer flags (separate collision/visual/voxel requirements)
```

```cpp
// terrain/variable_lod/voxel_lod_terrain.cpp:1208-1217
Vector3 VoxelLodTerrain::get_local_viewer_pos() const {
    // TODO Support for multiple viewers, this is a placeholder implementation
    VoxelEngine::get_singleton().for_each_viewer(
        [&pos](ViewerID id, const VoxelEngine::Viewer &viewer) { pos = viewer.world_position; });
```

**Clipbox:** `ClipboxStreamingState` с `StdVector<PairedViewer>
paired_viewers`, каждый viewer несёт свои `data_box_per_lod` /
`mesh_box_per_lod` (`FixedArray<Box3i, MAX_LOD>`) — но voxel-данные и
mesh-карта **общие**, с рефкаунтом по блоку:

```cpp
// terrain/variable_lod/voxel_lod_terrain_update_data.h:109-116
// Refcount here to support multiple viewers, we can't do it on the main
// thread's mesh map since the streaming logic is in the update task.
SafeRefCount mesh_viewers;
SafeRefCount collision_viewers;
```

Официальная дока (`doc/source/api/VoxelLodTerrain.md:115-116`):

> `STREAMING_SYSTEM_LEGACY_OCTREE` = 0 — … Does not support multiple viewers.
> Does not support collision-only viewers.
>
> `STREAMING_SYSTEM_CLIPBOX` = 1 — … Supports multiple viewers and
> collision-only viewers. **This is a better system for multiplayer
> streaming.** Due to simplifications, chunk locations at each LOD might be
> less optimal than `STREAMING_SYSTEM_LEGACY_OCTREE`.

Clipbox — молодой код: introduced `e385eeb2` (2023-12-08, «Initial
implementation of "clipbox" streaming»), с тех пор регулярные багфиксы
(`75bb4cd4` «Fixed incorrect loading of chunks near terrain borders»,
`3a9775f6` «Fix missing locks … when using threaded update», `aa2ecc32`
«Fix wrong index used in Clipbox subdivision corner case») — т.е. это не
«давно устоявшийся, отполированный» путь, а активно чинящаяся подсистема.

**Критично для этого RFC:** «Clipbox поддерживает несколько viewer'ов»
означает несколько viewer'ов **внутри одного процесса**, делящих один
`VoxelData` в памяти. Это решает задачу «локальный игрок + локальные
коллизионные прокси для чужих аватаров на хосте» (ровно то, что делает
`HostStreamViewer` в Regolith) — но НЕ задачу «два независимых процесса
должны согласовать состояние по сети». Это разные слои, и Clipbox сам по
себе не является сетевым решением — вопреки тому, как формулировку «better
system for multiplayer streaming» можно прочитать поверхностно.

### 2.4 `VoxelStream` / `VoxelStreamSQLite`

Формат (`doc/source/specs/sqlite_format_v1.md:35-54`): таблица `blocks`
(`loc` PK, `vb` BLOB — сжатый `VoxelBuffer` по Block format v4, `instances`
BLOB), таблица `meta` (version, block_size_po2, coordinate_format). **Нет
колонки под mesh или collision shape** — схема физически не несёт ничего,
кроме voxel-данных (см. также `COLLIDER-SQLITE-CACHE-FEASIBILITY.md` §2).

```cpp
// streams/sqlite/voxel_stream_sqlite.h:18-30
// Saves voxel data into a single SQLite database file.
class VoxelStreamSQLite : public VoxelStream {
    // Warning: changing this path from a valid one to another is not
    // always safe in a multithreaded context.
```

Конкурентность — **локальная, однопроцессная**: сериализация statement'ов
мьютексом внутри одного процесса (`voxel_stream_sqlite.h:83-95`), это НЕ
сетевая multi-writer БД. Для многопользовательской модели это означает: файл
БД может быть носителем «полного снимка на джойн» (как уже делает Regolith),
но не общей шиной синхронизации между процессами.

### 2.5 `VoxelTool` edit-путь и mip-пропагация

Правка идёт только по LOD0-сетке:

```cpp
// edition/voxel_tool_lod_terrain.cpp:91-126
void VoxelToolLodTerrain::do_sphere(Vector3 center, float radius) {
    data.get_blocks_grid(op.blocks, world_box, 0); // lod=0 явно
    op();
    _post_edit(world_box);
}
```

```cpp
// terrain/variable_lod/voxel_lod_terrain.cpp:626-633
// Marks intersecting blocks in the area as modified, updates LODs and
// schedules remeshing. The provided box must be at LOD0 coordinates.
void VoxelLodTerrain::post_edit_area(Box3i p_box, bool update_mesh) {
    _data->mark_area_modified(p_box, &_update_data->state.edit_notifications.edited_blocks_lod0, update_mesh);
```

Мип-пропагация — явная, синхронная, downscale-проходом:

```cpp
// terrain/variable_lod/voxel_lod_terrain_update_task.cpp:650-652
data.update_lods(to_span(tls_modified_lod0_blocks), nullptr);
```

```cpp
// storage/voxel_data.cpp:815-822
void VoxelData::update_lods(Span<const Vector3i> modified_lod0_blocks, ...) {
    // Propagates edits performed so far to other LODs.
    // These LODs must be currently in memory, otherwise terrain data will miss it.
    // This is currently ensured by the fact we load blocks in a "pyramidal" way,
```

```cpp
// storage/voxel_data.cpp:1008-1015
{
    ZN_PROFILE_SCOPE_NAMED("Downscale");
    src_block->get_voxels().downscale_to(dst_block->get_voxels(), Vector3i(), size, rel * half_bs);
}
```

Ключевая формулировка комментария — «This is **currently ensured** by the
fact we load blocks in a pyramidal way» — это инвариант **одного локального
стримера**, не гарантия, действующая при произвольном внешнем триггере
правки (см. блокер §3.3).

`VoxelData` — один `shared_ptr` на весь терейн, общий для всех viewer'ов
внутри процесса:

```cpp
// terrain/variable_lod/voxel_lod_terrain.cpp:130-131
_data = make_shared_instance<VoxelData>();
_update_data = make_shared_instance<VoxelLodTerrainUpdateData>();
```

### 2.6 Главный поток: бюджет, меш, коллайдер

Проектная настройка (default 8 мс):

```cpp
// engine/voxel_engine_gd.cpp:58-66
add_custom_project_setting(Variant::INT, "voxel/threads/main/time_budget_ms",
    PROPERTY_HINT_RANGE, "0,1000", 8, true);
config.inner.main_thread_budget_usec = 1000 * int(ps.get("voxel/threads/main/time_budget_ms"));
```

Меш применяется как **preemptible time-spread задача**:

```cpp
// engine/voxel_engine.cpp:317-319
_time_spread_task_runner.process(_main_thread_time_budget_usec);
```

```cpp
// terrain/variable_lod/voxel_lod_terrain.cpp:147-155
callbacks.mesh_output_callback = [](void *cb_data, VoxelEngine::BlockMeshOutput &ob) {
    VoxelEngine::get_singleton().push_main_thread_time_spread_task(task);
```

А коллайдер — **отдельным, не time-spread проходом**, с явным TODO от
автора:

```cpp
// terrain/variable_lod/voxel_lod_terrain.cpp:1275-1276
// TODO This could go into time spread tasks too
process_deferred_collision_updates(VoxelEngine::get_singleton().get_main_thread_time_budget_usec());
```

Построение формы уже оптимизировано относительно наивного пути (не
`Mesh::create_trimesh_shape`, а свой билдер без лишнего `Trimesh`/BVH):

```cpp
// util/godot/classes/concave_polygon_shape_3d.cpp:10-12
Ref<ConcavePolygonShape3D> create_concave_polygon_shape(const Span<const Array> surfaces) {
    // Faster version of Mesh::create_trimesh_shape(), because
    // `create_trimesh_shape` creates a Trimesh internally, which is super slow
```

Но регистрация в `PhysicsServer3D` (`util/godot/direct_static_body.cpp:18-56`,
вызывается из `terrain/voxel_mesh_block.cpp:147-168`) обязана идти на
главном потоке — `PhysicsServer3D` не потокобезопасен, это трекается issue
[#124](https://github.com/Zylann/godot_voxel/issues/124) (открыт с 2020,
автор сам пытался перенести построение формы в поток мешинга — не вышло),
заблокировано до апстрим-фикса Godot,
[godot-proposals#483](https://github.com/godotengine/godot-proposals/issues/483)
(не решён). Числа стоимости — [Performance
doc](https://voxel-tools.readthedocs.io/en/latest/performance/#shape-creation-is-very-slow)
и issue [#54](https://github.com/Zylann/godot_voxel/issues/54) (2019): «20
times slower than creating the visual mesh», ~8 мс/блок 32³ в release —
подробный разбор масштаба уже в `COLLIDER-SQLITE-CACHE-FEASIBILITY.md` §1,
§3.

### 2.7 История/CHANGELOG — LOD MP не в работе

`doc/source/changelog.md`: MP для `VoxelTerrain` — `d1250ef0` (2022-01-31,
ручной паттерн), `0fee7583` (2023-04-13, `VoxelTerrainMultiplayerSynchronizer`).
Clipbox — `e385eeb2` (2023-12-08). `git log --since=2024-07-01
--grep=multiplayer -i` по всему репозиторию — **пусто**. Последние ~50
коммитов в `terrain/` — Clipbox-багфиксы, instancer, stair-climbing, GPU —
**без** следов работы над LOD-мультиплеером. `.github/` не содержит issue
templates/workflow упоминаний multiplayer.

**Вывод раздела 2:** «planned» в доке — не эвфемизм для «почти готово». Для
fixed-LOD есть реальный класс и 4 года шлифовки (2022→2026); для LOD —
ничего, кроме констатации проблемы и инфраструктуры даже не для сети, а для
локального мульти-viewer стриминга (Clipbox), которая сама ещё получает
багфиксы.

### 2.8 Позиция автора и сообщества (GitHub issues)

Помимо доки и git-истории, сам Zylann прямо высказывался по теме:

- Issue [#602](https://github.com/Zylann/godot_voxel/issues/602) («Can this
  work for Godot 4+ multiplayer open-world chunk system?», закрыт автором
  вопроса 2024-02-21): Zylann — «*I'm not actively working on multiplayer
  right now as I have a lot of other things to do.*» Единственный
  многопользовательский пример, на который он ссылается — блочная (не LOD)
  демка `Zylann/voxelgame`.
- Issue [#151](https://github.com/Zylann/godot_voxel/issues/151)
  («Streaming regions over network», открыт с ~2020, **до сих пор открыт**)
  — самое глубокое техническое обсуждение проблемы. Zylann: «*`VoxelStream`
  is a synchronous interface, network isn't. This forces a very inefficient
  request design where the query would block until it receives the data...
  Replacing `VoxelDataLoader` sounds like a better alternative.*» И отдельно
  про генератор: «*it's for generating procedurally. If network features
  appear in the future, it won't be in that class.*» Это отдельный,
  четвёртый (не упомянутый в §3 изначально) блокер уровня API:
  **`VoxelStream`/`VoxelDataLoader` спроектированы как синхронный интерфейс
  под дисковый I/O, не под асинхронную сеть с произвольной задержкой** —
  bulk-передача файла (как делает Regolith и как предлагает §4.4)
  обходит эту проблему копированием целого файла, но «нативная» потоковая
  синхронизация блок-за-блоком поверх существующего `VoxelStream`
  потребовала бы или блокировки на сетевой RTT, или отдельного нового
  интерфейса — ровно то, на что намекает сам автор («Replacing
  `VoxelDataLoader` sounds like a better alternative»).
- Issue [#571](https://github.com/Zylann/godot_voxel/issues/571) —
  сторонний репортер прямым текстом: «*I recently had to switch from LOD
  terrain to non-LOD terrain as I'm developing a multiplayer game and LOD
  terrain currently does not support multiplayer... Adding multiplayer
  support to LOD terrain would fix a good portion of the issue.*» —
  независимое от Regolith подтверждение, что это реальный, а не надуманный
  блокер для сторонних проектов.
- Issue [#640](https://github.com/Zylann/godot_voxel/issues/640) (tracker
  фича-веток) упоминает WIP-ветку `clipbox_deferred_merges` — «*improves
  the Clipbox LOD streaming system to reduce recently edited chunks
  flickering when moving fast backwards... Not sure if it will be merged
  given the added complexity*» — Clipbox продолжает получать нетривиальные,
  не факт что мерджуемые доработки уже сейчас, без всякой сети.
- README репозитория (актуальный снимок 2026) в разделе «Areas of
  interest» отдельно перечисляет и «Multiplayer synchronization», и «Level
  of detail with blocky voxels» как нерешённые направления — то есть даже
  по собственной классификации автора это две разные незакрытые задачи, а
  не одна.
- Реальных сторонних форков/веток именно с LOD-мультиплеером не найдено;
  ближайшее — [WithinAmnesia/ARPG](https://github.com/WithinAmnesia/ARPG) и
  обсуждения в `Zylann/voxelgame` [#100](https://github.com/Zylann/voxelgame/issues/100),
  [#101](https://github.com/Zylann/voxelgame/issues/101) — но это про
  блочный (не LOD) `VoxelTerrain`, конвертируемый в top-down 2D. Т.е.
  комбинация «LOD + сеть» для этого плагина в паблике практически не
  пробовалась никем.

---

## 3. Технические блокеры LOD (честный список)

1. **Legacy Octree (default!) физически не поддерживает несколько viewer'ов
   и viewer-флаги** (`voxel_lod_terrain_update_octree_streaming.h:9-12`) —
   это не «работает похуже», а «API откажет/не будет работать корректно».
   Clipbox обязателен как предпосылка, но это отдельный шаг миграции даже
   для одиночной игры, которая просто хочет когда-нибудь добавить кооп.

2. **Multi-viewer (Clipbox) ≠ сетевой мультиплеер.** Несколько viewer'ов в
   Clipbox — это несколько точек стриминга **внутри одного процесса**,
   делящих один `shared_ptr<VoxelData>` (§2.3, §2.5). Для реальной сети два
   процесса всё равно должны согласовывать состояние снаружи — ни один
   существующий примитив LOD-стриминга это не делает. Аналог с fixed-LOD
   (`VoxelTerrainMultiplayerSynchronizer`) шлёт **целые блоки** через
   `_rpc_receive_blocks`/`_rpc_receive_area` — у LOD нет эквивалента,
   и «просто прислать LOD0-блок» не имеет смысла без знания, на каком LOD
   и в какой фазе стриминга сейчас находится принимающий пир.

3. **Инвариант мип-пропагации завязан на локальный порядок стриминга.**
   `update_lods`/`downscale_to` (§2.5) документированы как корректные
   «потому что мы грузим блоки пирамидально» — то есть предполагается, что
   когда LOD0 правится, родительские LOD-блоки уже резидентны, потому что
   именно так работает штатный локальный стример вокруг одного viewer'а.
   Для реплицированной правки в позиции, куда локальный Clipbox пира ещё не
   догрузил соответствующую мип-цепочку (например: правка пришла от
   удалённого игрока, копающего далеко от вас), это НЕ гарантировано.
   **ГИПОТЕЗА (не проверено чтением кода в этом проходе):** неизвестно,
   есть ли у `update_lods` защита/fallback на случай отсутствующего
   родительского блока, или пропуск/дырка в мип-пирамиде просто тихо
   остаётся до тех пор, пока блок не догрузится обычным путём. Это первое,
   что нужно перепроверить прямым чтением `VoxelData::update_lods` целиком
   перед реализацией.

4. **Детерминизм генератора/мешера между независимыми процессами не
   доказан.** Op-репликация (переслать параметры `do_sphere`, а не байты)
   работает только если оба процесса, применив одну операцию к
   одинаковому полю, получают идентичный результат — включая порядок
   плавающей арифметики при downscale. Для `VoxelGeneratorGraph` и
   скриптовых генераторов это не проверялось никем в этом research; сам
   Regolith сознательно **принимает** дрейф как компромисс
   (`docs/COOP_SPIKE_PLAN.md`, этап B: «двойной билд с одинаковым seed …
   применение одной и той же dig-операции … даёт одинаковый результат с
   точностью до дрейфа, который для спайка принимаем»).

5. **Save/stream — не многопользовательский примитив.** `VoxelStreamSQLite`
   — локальный однопроцессный файл (§2.4). Любая модель с несколькими
   активными писателями голосования данных должна явно выбрать одного
   писателя (хост) — сам движок этого выбора не делает и не проверяет.

6. **Коллайдер — главный поток каждого процесса, независимо от сети, но
   сеть умножает нагрузку именно там.** Хосту, чтобы физически держать
   удалённых акторов «на земле» или проверять `is_area_editable` вокруг
   их дальних правок, нужны дополнительные (пусть collision-only) viewer'ы
   — то есть именно на процессе, который и так сервер, растёт коллайдерная
   нагрузка главного потока пропорционально числу пиров (см. §2.6,
   `COLLIDER-SQLITE-CACHE-FEASIBILITY.md`). Ни один известный флаг API не
   даёт «сэкономить» здесь без сокращения радиуса/LOD этих прокси-viewer'ов.

7. **Память и масштаб растут с числом viewer'ов, а не полем.** Для
   Ø19 км-планетоида: ~9-13М LOD0-блоков во всём мире против ~21.8 тыс.
   блоков за реальную игровую сессию (`COLLIDER-SQLITE-CACHE-FEASIBILITY.md`
   §3) — стриминг по view distance спасает от полного мира, но каждый
   дополнительный (даже collision-only) viewer — это ещё один независимый
   набор data/mesh/collision box'ов по всем LOD (`PairedViewer`,
   §2.3), а Clipbox как система для N>1 viewer'ов — код, который существует
   меньше двух лет и всё ещё чинится (§2.3).

8. **Нет понятия «сетевой пир» на уровне `VoxelLodTerrain`.**
   `VoxelViewer.network_peer_id` существует как поле (§2.2), но осмысленно
   потреблялся до сих пор только для `VoxelTerrain`/`VoxelTerrainMultiplayerSynchronizer`.
   Для LOD нужно решить более сложную задачу: одна и та же правка должна
   быть отправлена разным пирам, возможно, ожидающим разное LOD-разрешение
   в той точке (пир далеко от места правки может не нуждаться в LOD0 вовсе).

9. **`VoxelStream`/`VoxelDataLoader` спроектированы как синхронный интерфейс
   под дисковый I/O, не под сеть.** Подтверждено автором напрямую в issue
   [#151](https://github.com/Zylann/godot_voxel/issues/151): «*`VoxelStream`
   is a synchronous interface, network isn't. This forces a very
   inefficient request design where the query would block until it
   receives the data.*» Он же явно исключает `VoxelGenerator` из будущей
   сетевой роли: «*it's for generating procedurally. If network features
   appear in the future, it won't be in that class.*» Значит «естественного»
   способа подключить сеть в существующий streaming-pipeline (генератор →
   стрим → data map) нет — нужен отдельный слой синхронизации сбоку (что
   Regolith и делает через ENet+RPC, минуя `VoxelStream` API целиком, кроме
   как для файлового bulk-хендовера).

10. **`requires_collisions` под Clipbox официально ограничен последним
    LOD.** Дока `api/VoxelViewer` (`/stable/`): «*This property has
    limitations: it is only implemented on `VoxelLodTerrain` when using
    `STREAMING_SYSTEM_CLIPBOX`, and applies only to the last LOD, like view
    distance.*» — «последний LOD» здесь означает LOD у границы view
    distance viewer'а, а не «все LOD»; нужно перепроверять терминологию
    доки перед тем, как проектировать collision-only прокси-viewer с
    ожиданием «коллайдер везде, где нужно» — сегодня гарантия ýже.

---

## 4. Предлагаемая архитектура

### 4.1 Authority model

**Server(host)-authoritative `VoxelData`, per-peer локальный стриминг.**
Единственный процесс исполняет `VoxelToolLodTerrain.do_sphere/do_box/...`
против своего `VoxelData`; клиенты никогда не вызывают edit-методы
напрямую на своей копии. Это ровно модель, которую уже использует
`VoxelTerrainMultiplayerSynchronizer` для fixed-LOD (`RPC_MODE_AUTHORITY`,
§2.1), и ровно то, что Regolith уже реализовал в GDScript
(`WorldCommandGateway.replay_remote_dig`, host исполняет от имени пира).

Централизовать сам LOD-стриминг (общий на всех) — не вариант и не нужно:
смысл LOD — адаптивное разрешение вокруг конкретной точки обзора, у каждого
пира по определению своя. Поэтому «сервер владеет данными, каждый пир
стримит их локально под свою камеру» — единственная архитектура,
совместимая с самой идеей LOD.

### 4.2 Формат правки на проводе

| Вариант | Плюсы | Минусы |
|---|---|---|
| **(a) Сырой SDF-дельта блока** (`vb` BLOB, Block format v4) | Формат уже есть; получатель просто кладёт байты в свой `VoxelDataMap`, семантика брэша не нужна; работает для любых генераторов/скриптовых кистей | Блок 16³/32³ — десятки КБ сжатых на логическую правку «шар 2 м»; трафик; правки у границ блока требуют нескольких блоков |
| **(b) Op-лог** (`do_sphere`/`do_box`/`do_point` + параметры) | Крошечный payload (именно так уже делает Regolith — `CoopCommandCodec.build_dig_op`); естественно ложится на API `VoxelToolLodTerrain` | Требует детерминизма (см. блокер §3.4); каждый пир сам пересчитывает мип-пирамиду у себя — упирается в блокер §3.3; нужен версионированный словарь op-ов |
| **(c) Гибрид** | Op — основной путь; сырой блок — явный repair-механизм при обнаруженном рассинхроне (чек-сумма блока не совпала) | Требует детекции дивергенции (сама по себе нетривиальная фича, см. §7) |

**Рекомендация: (b)+(c).** Op-лог как основной путь (дёшево, естественно
ложится на существующий `VoxelTool` API, ровно то, что уже де-факто
изобрёл Regolith), сырой блок — как redundancy/resync механизм, а не
повседневный путь.

### 4.3 Пропагация на родительские LOD

Если каждый пир независимо вызывает `do_sphere`/`do_box` у себя (модель
(b)), то `update_lods` у каждого пира тоже считается локально — **мипы не
нужно реплицировать по сети**, пока держится детерминизм (§3.4) и
резидентность родительской цепочки (§3.3).

Новый примитив для закрытия §3.3: перед применением реплицированной op-ы —
гарантированно догрузить/сгенерировать нужный диапазон родительских LOD:

```gdscript
# Гипотетический API, ГИПОТЕЗА-предложение, не существует сегодня
VoxelData.ensure_lod_pyramid_loaded(lod0_box: AABB, max_lod: int) -> bool
```

Синхронно (заблокировать применение op-ы до готовности) или асинхронно
(поставить op в очередь до сигнала готовности) — по аналогии с уже
существующим soft-retry, который Regolith вынужден был написать вручную
именно из-за отсутствия этого примитива (`coop_session.gd`, `_srv_submit`
retry на `terrain_unavailable`, 2 попытки по 0.3 с).

### 4.4 Late join / catch-up

Op-репликация с t=0 не масштабируется (лог бесконечно растёт) — сам
Regolith уже ограничивает это `MAX_DIG_OPS = 8192` (ring buffer,
`coop_session.gd`). Рабочая модель, которую Regolith уже построил вручную и
которую стоит формализовать в движке:

1. **Bulk-хендовер целого стрима** на джойне — как сегодня делает
   `coop_terrain_bulk.gd` (host шлёт `VoxelStreamSQLite`-файл целиком,
   чанками по 256 КиБ, реиспользуя `CH_BULK`-аналог), клиент подменяет
   `VoxelStream` на реплику файла.
2. **Хвост op-лога** после точки бакапа (post-flush tail), для правок,
   случившихся между «снять бакап» и «применить у клиента».

Формализация в движке: контракт экспорта/импорта байтов у `VoxelStream`
(`export_bytes()`/`import_bytes()`, ГИПОТЕЗА — нужно свериться, нет ли уже
чего-то похожего у `VoxelStreamSQLite`, это не проверялось в этом проходе)
плюс явный флаш перед экспортом (то, что `bootstrap.gd:flush_digs_for_coop_join`
уже делает руками — `save_modified_blocks()` + `stream.flush()`), и метод
верхнего уровня:

```gdscript
# ГИПОТЕЗА-предложение
VoxelLodTerrain.request_full_resync(peer_id: int) -> void
```

### 4.5 Кто платит за меш/коллайдер у каждого пира

- Визуальный меш — всегда локально у каждого пира (иначе теряется весь
  смысл LOD).
- Хосту дополнительно нужны collision-only прокси-viewer'ы под каждым
  удалённым актором, которому нужна физика/`is_area_editable` рядом с ним
  — ровно `HostStreamViewer` Regolith'а. Это неустранимая часть
  host-authoritative дизайна с физикой, не следствие конкретного выбора
  протокола.
- Предлагается формализовать **класс viewer'а**, чтобы движок мог
  планировать бюджет по классам (см. §4.6):

```gdscript
# ГИПОТЕЗА-предложение
enum ViewerClass { VIEWER_CLASS_LOCAL_PLAYER, VIEWER_CLASS_REMOTE_PROXY }
VoxelViewer.viewer_class: ViewerClass
```

### 4.6 Главный поток / коллайдер: есть ли инженерный фикс?

Честно по каждому направлению:

- **Deferred/budgeted registration.** Уже частично есть для меша
  (`_time_spread_task_runner`, §2.6), но коллайдер идёт **отдельным,
  не time-spread** проходом — и это прямо помечено TODO самим автором
  (`voxel_lod_terrain.cpp:1275`, «This could go into time spread tasks
  too»). **Конкретное предложение RFC: перенести создание+регистрацию
  коллайдера в ту же очередь time-spread задач, что и меш** — не убирает
  потокобезопасность `PhysicsServer3D`, но превращает нераздельный
  проход с потолком по usec в честно вытесняемую единицу работы с
  backpressure. Это единственный пункт в этом разделе, который выглядит
  как реально небольшой, самодостаточный, вероятно мерджуемый PR — сам
  автор уже отметил место.
- **Бюджет по классу viewer'а.** Дать `VIEWER_CLASS_REMOTE_PROXY` меньшую
  долю `voxel/threads/main/time_budget_ms`, либо отдельную настройку
  `voxel/threads/main/collision_time_budget_ms` — чтобы всплеск
  коллайдеров под гостями не голодал очередь локального игрока и наоборот.
- **Лимит LOD для коллайдера.** Уже существует рычаг (`collision_lod_count`
  / упомянутый в Regolith как `SPAWN_COLLISION_LOD_COUNT`) — предложение:
  явно документировать и, возможно, задать отдельно per-viewer-class лимит
  (прокси-viewer'ам почти всегда достаточно LOD0, никогда не нужен LOD1+).
- **Переиспользование формы.** `create_concave_polygon_shape` уже быстрее
  наивного `Mesh::create_trimesh_shape` (§2.6, оптимизация, закрывшая
  часть issue [#54](https://github.com/Zylann/godot_voxel/issues/54) ещё
  до этого RFC) — быстрых неиспользованных выигрышей здесь в этом проходе
  не найдено. **ГИПОТЕЗА:** дальнейший выигрыш потребовал бы
  специализированной формы (что-то вроде `HeightMapShape3D`) вместо общей
  concave-формы — это уже вопрос формата мешинга, вне скоупа этого RFC.
- **Корневой фикс — не полностью в руках автора модуля, но картина
  изменилась с 2020 года.** `PhysicsServer3D` исторически не
  потокобезопасен на уровне ядра Godot; трекается
  [godot-proposals#483](https://github.com/godotengine/godot-proposals/issues/483)
  (открыт самим Zylann 2020-02-15, не закрыт, последнее обновление
  2024-12-03). Его же исходные слова там: «*Creating mesh colliders is 10
  times slower than creating visual meshes... Unlike VisualServer and
  PhysicsServer2D, PhysicsServer has no thread model option... I currently
  have no choice but to create my shapes on the main thread.*»; в 2022 —
  «*I am still heavily bottlenecked by shapes having to be created on the
  main thread... The ideal (and minimal) solution I would need would be
  the ability to fully create shapes from my own threads, in a safe way.*»
  Реплика Calinou там же (2022): «*we don't have an active physics
  maintainer anymore, so this feature will take a while.*» Module-level
  попытка автора зафиксирована как [#124](https://github.com/Zylann/godot_voxel/issues/124)
  (открыт 2020-02-15, статус «Waiting for Godot», не закрыт): «*This issue
  must be addressed as soon as Godot implements this.*» Его же обходной
  путь по факту — тот самый `time_budget_ms`-цикл: «*I build collision
  shapes on the main thread. If it takes more than 8 ms, I stop and
  continue dequeuing them next frame.*»

  **Новое обстоятельство (проверено в этом проходе через официальную доку
  Godot):** Jolt стал **дефолтным** 3D-физическим движком Godot начиная с
  **4.6**, и, в отличие от расширения `godot-jolt`, встроенный Jolt-модуль
  *обладает* потокобезопасностью, включая поддержку настройки «Physics >
  3D > Run On Separate Thread» —
  [docs.godotengine.org/en/4.6/tutorials/physics/using_jolt_physics.html](https://docs.godotengine.org/en/4.6/tutorials/physics/using_jolt_physics.html):
  «*Unlike the Godot Jolt extension, the Jolt module does have
  thread-safety... However this has not been tested very thoroughly, so it
  should be considered experimental.*» Это **не** автоматически закрывает
  #124/#483: сторонний разбор миграции подтверждает нюанс — «*Jolt
  supports multithreaded physics internally... However, accessing physics
  state from multiple threads in GDScript is still unsafe*»
  ([strayspark.studio migration guide](https://www.strayspark.studio/blog/godot-46-jolt-physics-migration-guide)).
  То есть: **сам физический шаг** Jolt может идти на отдельном потоке —
  но вызовы уровня `PhysicsServer3D.body_add_shape`/`shape_create`,
  которые как раз и делает `godot_voxel` при регистрации коллайдера блока
  (`util/godot/direct_static_body.cpp:18-56`), это отдельный, скриптовый
  API-слой, про потокобезопасность которого явного «да» в источниках,
  прочитанных в этом проходе, нет. **ГИПОТЕЗА, требует прямой проверки**
  (эксперимент на Godot 4.6+/4.8 с включённым `Run On Separate Thread` +
  профайлинг `create_concave_polygon_shape`/`body_add_shape` из
  не-главного потока в контексте самого `godot_voxel`): возможно, что
  Godot 4.6+ впервые открывает путь к тому, чего issue #124 добивался с
  2020 года, но это не подтверждено ни доком `godot_voxel`, ни этим
  research — только официальной докой Godot и вторичным источником про
  сам движок в целом, не про API, которым пользуется этот плагин.

### 4.7 API-поверхность (конкретные имена)

| Имя | Тип | Назначение |
|---|---|---|
| `VoxelLodTerrainMultiplayerSynchronizer` | новый `Node` | Структурный аналог `VoxelTerrainMultiplayerSynchronizer`, но на уровне op-лога (§4.2b), а не целых блоков |
| `VoxelViewer.viewer_class` | новый enum property | Партиционирование главного-поточного бюджета (§4.5, §4.6) |
| `VoxelEditOperation` | новый Resource/struct | Каноническое, версионированное представление одной правки (`kind`: SPHERE/BOX/POINT/PATH, `center`, `radius`/`extents`, `mode`, `channel`, `texture_index`) — заменяет самодельные op-дикты вроде `CoopCommandCodec.build_dig_op` |
| `VoxelToolLodTerrain.apply_operation(op: VoxelEditOperation)` | новый метод | Применить каноническую op локально (используется и локальным вводом, и сетевым реплеем) |
| `VoxelLodTerrain.edit_applied(op: VoxelEditOperation)` | новый сигнал | Единая точка для геймплейных сайд-эффектов (ресурсы, VFX) без ре-вывода состояния из diff'а |
| `VoxelData.ensure_lod_pyramid_loaded(box, max_lod)` | новый метод | Закрывает блокер §3.3 перед применением реплицированной op |
| `VoxelLodTerrain.request_full_resync(peer_id)` | новый метод | Формализация bulk catch-up (§4.4) |
| `voxel/threads/main/collision_time_budget_ms` | новая project setting | Отдельный бюджет коллайдера от общего мешевого (§4.6) |

`VoxelViewer.network_peer_id` уже существует (§2.2) — предлагается либо
подтвердить и задокументировать его использование для LOD-пути, либо (если
подтвердится, что сейчас не используется — см. открытый вопрос §2.2)
явно расширить Clipbox-код, чтобы он тоже его учитывал.

---

## 5. Поэтапный план реализации

Каждая фаза — независимо мерджуемый PR, что-то реально разблокирующий,
без необходимости ждать все последующие фазы.

| Фаза | Что | Разблокирует | Риск для существующих пользователей |
|---|---|---|---|
| **0** | Коллайдер → time-spread очередь (уже помечено TODO автором, §4.6) | Честный backpressure под нагрузкой от N viewer'ов, ещё до сети | Низкий — чисто внутренний рефактор существующего прохода |
| **1** | `VoxelViewer.viewer_class` + `collision_time_budget_ms` | Безопасное сосуществование local+N remote-proxy viewer'ов | Низкий — новые opt-in свойства, дефолт = старое поведение |
| **2** | `VoxelEditOperation` + `VoxelToolLodTerrain.apply_operation()` + сигнал `edit_applied` | Канонический, версионированный формат правки для любых будущих потребителей (не только сети) | Низкий — новый тип, старые `do_sphere/do_box/do_point` не меняют поведение |
| **3** | `VoxelData.ensure_lod_pyramid_loaded()` | Безопасное применение Фазы-2 op, пришедшей из сети, в точке, куда локальный стример ещё не догрузил мип-цепочку | Средний — трогает threading-модель update task |
| **4** | `VoxelLodTerrainMultiplayerSynchronizer` (минимальный: только «горячий» op-стрим для уже присоединённых пиров) | Собственно «инжиниринг» существующего Regolith-паттерна dig-op broadcast в движок | Средний — новый Node, по образцу уже существующего fixed-LOD синхронизатора |
| **5** | Контракт export/import байтов `VoxelStream` + `request_full_resync` | Late join без ожидания реплея с t=0 (инжиниринг `coop_terrain_bulk.gd`) | Средний |
| **6** (опционально/stretch) | Детекция дивергенции (чек-сумма блока/региона) + точечный resync | Устойчивость к дрейфу без ресета всей сессии | Высокий — то, что даже Regolith сознательно не строил (`COOP_SPIKE_PLAN.md`: «Ресинк дрейфа террейна» — записанный долг, не сделано) |

Фазы 0–1 не трогают публичное поведение по умолчанию. Фазы 2–3 добавляют
новые opt-in типы, не касаясь Legacy Octree/однопользовательского пути.
Фазы 4–6 — собственно «мультиплеер», и по аналогии с тем, что fixed-LOD MP
до сих пор помечен «very experimental» (`multiplayer.md:4`) спустя 4 года,
разумно держать это поведение за explicit opt-in классом, не влиять на
дефолт.

---

## 6. Что можно вынести из Regolith в апстрим

Прочитан весь `scripts/coop/` + `bootstrap.gd`-часть, отвечающая за
terrain-sync. Ниже — конкретные куски, которые являются переизобретением
недостающего движкового примитива, а не игровой логикой:

| Regolith-механизм | Файл:строки | Инженерный эквивалент выше |
|---|---|---|
| Подтверждённый op dig-протокол + reliable ordered relay | `coop_session.gd:911-943`, `coop_command_codec.gd:127-138` | Фаза 2 (`VoxelEditOperation`) + Фаза 4 (`VoxelLodTerrainMultiplayerSynchronizer`) |
| Replay-on-client carve с очередью soft-failure | `coop_session.gd:677-683,935-943,1642-1663`; `world_command_gateway.gd:377-400` | Фаза 3 (`ensure_lod_pyramid_loaded`) — soft-retry Regolith существует именно потому, что этого примитива нет |
| Session dig log + late-join tail vs cold base | `coop_session.gd:98-100,162-163,553-574`; `coop_terrain_bulk.gd:104-112` | Фаза 5 |
| Целиковая SQLite bulk-передача (chunked) | `coop_terrain_bulk.gd:8-15,117-166`; `bootstrap.gd:172-223`; `coop_session.gd:577-589,694-721` | Фаза 5 (`export_bytes`/`import_bytes`, `request_full_resync`) |
| Host flush-before-join | `bootstrap.gd:162-167,746-784`; `coop_session.gd:554` | Часть контракта `request_full_resync` |
| Per-remote-peer collision-only `VoxelViewer` lifecycle | `remote_player.gd:71-76,194-233`; `coop_session.gd:1510-1513` | Фаза 1 (`viewer_class = REMOTE_PROXY`) — заодно снимает открытый в `VOXEL-TOOLS-COOP-DIG.md` §5 вопрос «дёшево ли частое add_child/queue_free viewer'а», если движок даст дешёвый enable/disable вместо пересоздания узла |
| Host soft-retry при `terrain_unavailable` под гостевым Clipbox | `coop_session.gd:57-61,1605-1637` | Симптом того же пробела, что закрывает Фаза 3 |
| Sandbox-метки изолированных dig БД для двух окон на одной машине | `coop_session.gd:244-260`; `moon_terrain_params.gd:60-75` | Остаётся прикладным (тестовая инфраструктура, не движковая забота) |

**Явно НЕ должно идти в апстрим** — специфика игры поверх terrain-sync:
ENet-каналы/позы/сиденья/инвентарь/экономика, ребродкаст sim-снапшота,
командные kind'ы гейтвея, правила `discard_yield`, реестр nick/uid. Это
ровно тот слой, который остаётся нужен игре даже после подключения
`VoxelTerrainMultiplayerSynchronizer` для fixed-LOD — терейн-синк не
избавляет от необходимости реплицировать игровое состояние.

---

## 7. Риски и открытые вопросы

- **Детерминизм заявлен, но с явной оговоркой самого автора.**
  [`doc/source/generators.md`](https://github.com/Zylann/godot_voxel/blob/master/doc/source/generators.md):
  «*Generators are designed to be deterministic: if the same area is
  generated twice, the result must be the same.*» — но там же: «*Column
  passes are executed in parallel, using multiple threads. Also, players
  can cause columns to generate from any direction. That means the order
  in which columns generate is unpredictable [with multipass].*» Т.е.
  «детерминизм» гарантирован для результата генерации конкретной области,
  но НЕ для порядка/тайминга событий вокруг неё — для op-репликации это
  разница некритична (правки одного и того же do_sphere в одном и том же
  месте детерминированы), но для многопроходных (multipass) генераторов
  стоит перепроверять на конкретном генераторе Regolith. Полной
  межплатформенной идентичности downscale-арифметики (§3.4) это не
  доказывает и не опровергает — остаётся ГИПОТЕЗОЙ, как и раньше; сам
  Regolith сознательно принимает дрейф как компромисс, а не как доказанное
  свойство (`COOP_SPIKE_PLAN.md`).
- **Мейнтейнер прямо сказал, что не работает над этим.** Zylann, issue
  [#602](https://github.com/Zylann/godot_voxel/issues/602) (2024): «*I'm
  not actively working on multiplayer right now as I have a lot of other
  things to do.*» Это не гипотеза о загрузке мейнтейнера — это прямая
  цитата, снимающая всякую двусмысленность из §8: инициатива и первичная
  работа по факту должны исходить от внешнего контрибьютора, если это
  вообще должно случиться в обозримом будущем.
- **`VoxelStream` спроектирован для синхронного дискового I/O, не для
  сети** (issue [#151](https://github.com/Zylann/godot_voxel/issues/151),
  подробнее §2.8/§3.9) — часть архитектуры §4 (bulk-файл + op-лог поверх
  ENet, мимо `VoxelStream`-протокола как такового) была выбрана именно
  чтобы обойти эту проблему, а не решить её «внутри» абстракции стрима;
  стоит явно защитить этот архитектурный выбор перед мейнтейнером, если
  RFC когда-либо дойдёт до обсуждения с ним — вероятно он предложит
  что-то в духе своей же идеи «replace `VoxelDataLoader`».
- **`network_peer_id` в Clipbox — не подтверждено ни туда, ни сюда**
  (§2.2) — нужен отдельный прямой grep `voxel_lod_terrain_update_clipbox_streaming.cpp`
  на использование этого поля, прежде чем на нём строить дизайн Фазы 4.
- **Резидентность мип-родителей при внешней правке (§3.3)** — прочитаны
  только выдержки `update_lods`, не вся функция целиком; поведение при
  отсутствующем родительском блоке не подтверждено.
- **Влияние многопоточности Jolt на бутылочное горлышко
  `PhysicsServer3D` (§4.6)** — веб-часть этого research не успела
  подтвердить/опровергнуть тезис «проблема в API-слое движка, а не в
  физическом бэкенде» до сдачи документа; помечено ГИПОТЕЗА, требует
  отдельной проверки (Jolt release notes, Godot 4.8+ changelog,
  обсуждения в godot-proposals).
- **Bandwidth/latency op-репликации не измерены** — NOT_PROFILED, как и
  все числа стоимости в родственных доках этого репозитория.
- **Legacy Octree остаётся default и не мигрируется этим предложением** —
  любая существующая одиночная игра не тронута, но это значит, что переход
  на Clipbox — обязательный отдельный шаг ещё до всего, описанного здесь,
  и сам Clipbox всё ещё получает багфиксы (§2.3).
- **Пропускная способность мейнтейнера.** Судя по паттерну коммитов/PR
  (`Merge pull request #879`, `#878`, …), проект живой, но, по всей
  видимости, с одним основным ревьюером кодовой базы такого масштаба —
  RFC такого объёма (6 фаз, новые публичные классы) реалистично требует
  месяцы, а не недели, независимо от готовности патча.
- **Готовность community/автора принять именно эту архитектуру** — этот
  документ — предложение одной команды, не согласованное с Zylann; выбор
  op-лога vs сырых блоков, конкретные имена классов — предмет обсуждения,
  не факт.

---

## 8. Реалистичная оценка и вердикт

### Оценка усилий (ГИПОТЕЗА, грубая, для разработчика уровня знакомства с кодовой базой, сравнимого с мейнтейнером; для внешнего контрибьютора — выше)

| Фаза | Оценка |
|---|---|
| 0 — коллайдер в time-spread | 1–2 недели |
| 1 — viewer class + бюджет | ~1 неделя |
| 2 — `VoxelEditOperation` + `apply_operation` | 2–3 недели (трогает основной edit-путь, нужна осторожность) |
| 3 — `ensure_lod_pyramid_loaded` | 2–4 недели (вероятно самая рискованная по технике фаза при скромном объёме кода — threading update task) |
| 4 — `VoxelLodTerrainMultiplayerSynchronizer` (минимальный) | 3–5 недель (новый Node + RPC + доки + пример, по объёму сравнимо с тем, чем уже была fixed-LOD версия) |
| 5 — bulk export/import + resync | 2–3 недели |
| **Итого 0–5** | **~3–4.5 месяца непрерывной сфокусированной работы**, ДО циклов ревью/итераций апстрима |
| 6 — детекция дивергенции | не оценивается — research-грейд, стратегия не определена |

С учётом реалистичного цикла ревью в open-source проекте с одним основным
мейнтейнером — **6–12 месяцев с момента старта до фактического мерджа фаз
0–5**, при благоприятном сценарии (мейнтейнер в целом согласен с
архитектурой с первого захода). Дольше, если контрибьютор внешний и не
знаком с `variable_lod/`-подсистемой заранее.

### Вердикт

**(a) Ждать/контрибьютить в апстрим** — технически «правильный» долгосрочный
путь, и у команды Regolith уже есть реальный (хоть и пока не влитый)
трек-рекорд патчей именно этого модуля (3 коммита SQLite-хардненинга на
форке). Но горизонт 6–12 месяцев и риск несогласия мейнтейнера с
архитектурой делают это неподходящим путём для того, чтобы получить
играбельный кооп сейчас.

**(b) Оставить GDScript-слой как есть** — правильный выбор на сегодня.
Ключевой вывод этого RFC: архитектура, которую Regolith уже построил в
GDScript (host-authoritative op-broadcast, per-peer collision-only
viewer, SQLite bulk на джойн), **структурно совпадает** с тем, что
предлагается здесь как движковое решение (Фазы 2, 4, 5 — это буквально
инжиниринг уже существующего Regolith-паттерна). Значит, никакого
«архитектурного долга» сейчас не копится — при появлении движковых
примитивов миграция будет естественной заменой, а не переписыванием с
нуля.

**(c) Форкнуть/патчить модуль локально** — НЕ рекомендуется для
мультиплеер-специфичных частей: настоящие блокеры (главный поток
`PhysicsServer3D`, молодость и баг-churn Clipbox, недоказанный инвариант
мип-резидентности) — это ровно тот класс глубоких, кросс-катаных
внутренних изменений, которые дорого поддерживать как долгоживущий
локальный патч против быстро меняющегося апстрима (`variable_lod/`
регулярно получает багфиксы и рефакторинг). Исключение — **Фаза 0**
(коллайдер → time-spread): маленькая, изолированная, вероятно мерджуемая
апстримом правка, которая прямо помогает собственной host-FPS проблеме
Regolith (перекликается с уже существующими рекомендациями #1/#4 из
`COLLIDER-SQLITE-CACHE-FEASIBILITY.md` §6) — и команда уже располагает
форком и опытом апстрим-патчей именно этого модуля, чтобы довести её до
реального PR.

**Прагматичная рекомендация на ближайший срок:** держать текущий
GDScript coop-слой без изменений архитектуры; при желании — подготовить и
предложить апстриму именно и только Фазу 0 (перенос построения/регистрации
коллайдера в time-spread очередь) как отдельный, самостоятельный PR,
опираясь на уже существующий форк и трек-рекорд. Не начинать фазы 2–6 как
апстрим-контрибуцию в ближайшей перспективе — это оправдано только если
Regolith решит, что мультиплеер для `VoxelLodTerrain` — стратегическое,
долгосрочное направление, в которое стоит вкладывать месяцы апстрим-работы
намеренно, а не попутно. Учитывая прямые слова автора («*not actively
working on multiplayer right now*», issue #602) — рассчитывать на быстрый
встречный интерес мейнтейнера не стоит; любая апстрим-инициатива здесь
реалистично означает «контрибьютор делает почти всю работу сам», а не
«соавторство с Zylann на паритетных началах».

### Сравнение с прочей индустрией (кратко)

Ни один из просмотренных примеров не решает именно ту задачу, которую
блокирует §3: **Veloren** (Rust, open-source) — server-authoritative,
раздельные стримы для «реальных» чанков (per-player view-distance box,
[`server/src/sys/terrain.rs`](https://github.com/veloren/veloren/blob/754dc94c/server/src/sys/terrain.rs))
и **отдельного, некастуемого horizon-map LOD-оверлея** для дальней
дистанции — то есть Veloren обходит проблему «непрерывный LOD с мешами и
коллайдерами по сети», а не решает её: дальний LOD у них — отдельный,
неправимый набор данных, в то время как у `VoxelLodTerrain` LOD>0 —
производная той же самой правимой voxel-пирамиды. **Minecraft**
(проприетарный, упомянут в самой доке `godot_voxel`) — TCP-протокол, но
без LOD-мешей вообще (только view/simulation distance по чанкам), поэтому
не сталкивается со швами/стыковкой LOD через сеть в принципе. Вывод: жёсткая
часть этого RFC (§3.3, §3.4 — консистентный мип LOD с редактируемыми
данными между независимыми процессами) — это то, что ни одна из
просмотренных прод-систем не должна была решать, потому что либо LOD
редактируем локально и не непрерывен (Minecraft), либо LOD не редактируем
и физически отделён от игровых данных (Veloren). Это не готовый рецепт —
это подтверждение, что предлагаемая архитектура (§4) не имеет прямого
референса для копирования, только структурно похожие частичные решения.

---

## Ссылки (полный список новых источников этого RFC)

- <https://github.com/Zylann/godot_voxel> (README, «Areas of interest»)
- <https://github.com/Zylann/godot_voxel/issues/602>
- <https://github.com/Zylann/godot_voxel/issues/151>
- <https://github.com/Zylann/godot_voxel/issues/571>
- <https://github.com/Zylann/godot_voxel/issues/640>
- <https://github.com/Zylann/godot_voxel/issues/124>
- <https://github.com/Zylann/godot_voxel/issues/54>
- <https://github.com/godotengine/godot-proposals/issues/483>
- <https://github.com/Zylann/voxelgame/issues/100>
- <https://github.com/Zylann/voxelgame/issues/101>
- <https://github.com/WithinAmnesia/ARPG>
- <https://voxel-tools.readthedocs.io/en/latest/multiplayer/>
- <https://voxel-tools.readthedocs.io/en/latest/api/VoxelLodTerrain/>
- <https://voxel-tools.readthedocs.io/en/stable/api/VoxelViewer/>
- <https://voxel-tools.readthedocs.io/en/latest/performance/>
- <https://github.com/Zylann/godot_voxel/blob/master/doc/source/generators.md>
- <https://docs.godotengine.org/en/4.6/tutorials/physics/using_jolt_physics.html>
- <https://www.strayspark.studio/blog/godot-46-jolt-physics-migration-guide>
- <https://github.com/veloren/veloren/blob/754dc94c/server/src/sys/terrain.rs>
- <https://deepwiki.com/veloren/veloren/2-client-server-architecture>
- Ранее собранные (переиспользованы, см. `docs/_verify/VOXEL-TOOLS-COOP-DIG.md`
  и `docs/_verify/COLLIDER-SQLITE-CACHE-FEASIBILITY.md` за полным списком)
