# Строительство — карта кода для обхода и поиска лагов

Отдельная шпаргалка: **где в коде что происходит**, когда игрок целится,
кликает «поставить» или сносит блок. Нужна для ручного профилирования и
понимания «почему лагает прицел / клик / снос», без чтения всего
`PHYSICAL-LANGUAGE.md`.

Контракт поведения — `docs/specs/CONSTRUCTION-V1.md`. Общая карта
`SimulationWorld` — `docs/cheatsheets/simulation-world.md`.

## Как читать

Каждый пункт каталога (1–55) — один шаг цепочки или один симптом/changelog.
У каждого есть:

| Поле | Смысл |
|---|---|
| **Что делает** | Механика по шагам (что обходится, что спрашивается) |
| **Когда тормозит** | Типичные условия лага |
| **Целесообразность** | Оправдан ли шаг / стоит ли трогать при оптимизации |
| **Простая альтернатива** | Более простой GDScript/дизайн или «оставить» |
| **Натив** | Нужен ли C++ / уже есть / не имеет смысла |

**Фазы** ниже идут в порядке игрового опыта: прицел → клик → снос →
побочные эффекты ядра → физика и картинка → changelog → triage по симптомам.

Числа вроде «до 12 проверок плана за один пересчёт прицела» — это
**жёсткие лимиты в коде** (`TOP_K_VALIDATE`, `TOP_K_PREFILTER`), а не
абстрактные метки.

---

## Прицел (превью) — 1–17

Пока активен инструмент «build», каждый physics-кадр крутится цикл:
«нужно ли пересчитывать план?» → «куда ставить?» → «подвинуть полупрозрачный
меш превью».

### 1. `ConstructionPreview._physics_process`

- **Что делает:** Раз в physics-кадр проверяет, что активен инструмент build и игрок может целиться; иначе скрывает превью и выходит. Иначе вызывает пересчёт плана и синхронизацию меша.
- **Когда тормозит:** Постоянная нагрузка только пока открыт build; в остальных режимах почти ноль.
- **Целесообразность:** Движок прицела: без этого превью не обновлялось бы синхронно с камерой и физикой.
- **Простая альтернатива:** Перенести на `_process` — хуже совпадение с physics raycast и pose; или resolve только по событию смены прицела — потеряете плавность. **Оставить.**
- **Натив:** Нет — тонкая обёртка над GDScript-оркестрацией и UI-превью; в C++ нечего ускорять.

### 2. `ConstructionPreview._update_resolution`

- **Что делает:** Берёт луч и попадание из `InteractionQuery`. Для земли запоминает «опорную точку» footprint (чтобы блок не дёргался при микродвижении камеры). Для крепления к сборке — pivot и зафиксированный snap-контекст после первого успешного плана. Собирает ключ контекста и либо пропускает тяжёлый resolve, либо зовёт gateway.
- **Когда тормозит:** Большие archetype (≥64 клеток footprint) используют более грубое квантование луча (шаг 25 см вместо 4 см), чтобы не пересчитывать план каждый кадр при беге.
- **Целесообразность:** Именно здесь решается «пересчитывать план или только двинуть меш».
- **Простая альтернатива:** Всегда вызывать полный resolve — проще код, но лаг при каждом микродвижении камеры. Квантование луча и pivot-hold уже минимальный компромисс. **Оставить.**
- **Натив:** Нет — логика кэша, pivot и квантования на стороне превью; тяжёлое уходит ниже по стеку.

### 3. `ConstructionPreview._resolve_context_key` + сравнение с `_cached_resolve_context_key`

- **Что делает:** Склеивает ключ из: счётчика поколения топологии (`topology_generation`), квантованного луча, выбранного archetype/orientation, id цели, pivot-токенов. Если ключ **не изменился** — полный пересчёт плана можно пропустить; остаётся только обновить положение меша.
- **Когда тормозит:** При медленном движении прицела ключ часто совпадает — код почти не заходит в resolver, только двигает `_mesh_root` по координатам из уже готового плана.
- **Целесообразность:** Если строка совпала — пропускается весь snap/validate/collision; остаётся только `_sync_preview_visuals`. Для больших блоков шаг квантования грубее (25 см vs 4 см).
- **Простая альтернатива:** Кэшировать готовый `placement_plan` в gateway — deep-copy каждый кадр дороже выигрыша. Текущий ключ дешевле. **Оставить.**
- **Натив:** Нет — сравнение строк и `snapped()` в GDScript; native не поможет.

### 4. `ConstructionPreview._refresh_heartbeat_attach_permission` (раз в ~150 ms при неизменном ключе)

- **Что делает:** Ровер может остановиться или тронуться **без** смены луча и без structural-события. Раз в 150 ms код снова спрашивает `world.construction_attach_allowed(assembly_id)` и переводит план между «можно поставить» и «нельзя» (магнит к движущемуся роверу). Не перебирает грани и не вызывает полный snap.
- **Когда тормозит:** Лёгкая проверка скорости; не пересчитывает весь snap.
- **Целесообразность:** Не трогает scan граней и validate — закрывает «ровер остановился, а луч тот же».
- **Простая альтернатива:** Включать скорость ровера в context key — полный resolve при каждом движении. Или polling каждый кадр — лишняя нагрузка. Heartbeat — разумный минимум. **Оставить.**
- **Натив:** Нет — одна лёгкая проверка скорости/тормоза; перенос в C++ не окупится.

### 5. `WorldCommandGateway.resolve_construction_placement`

- **Что делает:** Точка входа превью в симуляцию: вызывает `ConstructionSnapResolver.resolve`, затем `_seat_ground_plan` (посадка на рельеф), затем `_guard_placement_collision` (физика). Собирает тайминги для профайлера.
- **Когда тормозит:** Весь «тяжёлый» путь сидит здесь и ниже по стеку.
- **Целесообразность:** Единая точка входа превью в симуляцию — resolver → seat → collision.
- **Простая альтернатива:** Вызывать resolver/seat/collision напрямую из `ConstructionPreview` — дублирование и разъезд контракта с кликом. **Оставить** как фасад.
- **Натив:** Нет — чистая оркестрация; тяжёлое уже в resolver/kernel/physics.

### 6. `ConstructionSnapResolver.resolve`

- **Что делает:** **Прямое попадание луча по элементу** — один `ConstructionPlacement.plan` и выход (самый частый случай). Иначе — обход магнитных граней вдоль луча, сортировка кандидатов, затем проверка планов. План на voxel-землю строится **только если** магнитных граней нет (или включён ручной cycle).
- **Когда тормозит:** Много сборок в коридоре луча; большой archetype; ручной cycle snap (`construction_cycle_snap`).
- **Целесообразность:** При direct hit — один plan; lazy ground plan экономит seat-raycast на каждое движение.
- **Простая альтернатива:** Всегда сканировать все сборки — дороже на «прицелился в блок». **Оставить.**
- **Натив:** Уже есть — горячий scan делегируется в `_scan_faces_native`; orchestration и direct-hit path остаются в GDScript.

### 7. `ConstructionSnapResolver._collect_face_candidates` → `_scan_faces_native`

- **Что делает:** Собирает снимок мира (`ConstructionPreviewSnapshot.build`), отдаёт в C++ `ConstructionPreviewKernel.scan_magnetic_faces`. Для каждой найденной грани проверяет `construction_attach_allowed`. Затем для лучших граней (не больше **12** полных планов и **32** быстрых проверок занятости клеток) вызывает `ConstructionPlacement.plan`.
- **Когда тормозит:** Много открытых граней вдоль луча; archetype на 100+ клеток (каждый `plan` ≈ полная kernel-валидация).
- **Целесообразность:** Prefilter + TOP_K защищают от худшего кадра; останавливается после первого valid + sticky для hysteresis.
- **Простая альтернатива:** Валидировать все найденные грани — на 100+ клеток archetype это секунды. **Оставить** лимиты.
- **Натив:** Уже есть — `scan_magnetic_faces` в C++; prefilter и `plan` пока GDScript (prefilter специально `.has()` по словарю, не pack).

### 8. `ConstructionSnapResolver._scan_assembly_faces` (запасной путь без native)

- **Что делает:** Для каждой сборки: occupancy index → march луча по сетке с шагом 0.25 m → открытые грани рядом с лучом → геометрический score.
- **Когда тормозит:** Много сборок без GDExtension; большие occupancy.
- **Целесообразность:** Запасной путь без GDExtension; нужен когда native недоступен.
- **Простая альтернатива:** Без fallback превью не работает без extension. Упростить до «только direct hit» — потеряете магнит к граням вдоль луча. **Оставить** как fallback; в проде должен быть native.
- **Натив:** Уже есть — основной путь через `_scan_faces_native`; этот метод — GDScript fallback.

### 9. `ConstructionPreviewSnapshot.build`

- **Что делает:** Для каждой живой сборки: если AABB в grid-space пересекает коридор луча — упаковывает occupancy + позы элементов. Для «одного тела» (`single_group`) — только root transform; иначе `compile_body_groups` + live group transforms + idle-check актуаторов.
- **Когда тормозит:** Multibody-сборки (piston/rotor/hinge): `compile_body_groups` на каждый snapshot. Много роверов в кадре, даже далёкие отсеиваются по AABB.
- **Целесообразность:** AABB-cull и revision-кэш occupancy — разумный компромисс.
- **Простая альтернатива:** Снимать весь мир без AABB-cull — лишняя работа на дальние роверы. **Оставить.**
- **Натив:** Только горячий кусок — упаковку occupancy и march/score имеет смысл держать рядом с `scan_magnetic_faces` в C++; compile_body_groups и idle-check actuator логичнее оставить в симуляции (GDScript).

### 10. `ConstructionPreviewKernelAccess.validate_attach_preview`

- **Что делает:** Сериализует occupancy, structural faces, body groups сборки и footprint нового блока в плоские массивы; один вызов C++ `validate_attach_preview` (overlap, socket match, bridge cycle). Если `topology_revision` сборки не менялся — повторно не упаковывает, берёт уже собранные массивы.
- **Когда тормозит:** Первая валидация после place/dismantle на большой сборке — обход всех faces и упаковка. Повторные прицелы при той же revision — из запомненного набора.
- **Целесообразность:** Один C++ вызов вместо GDScript обхода соседних клеток на больших сборках.
- **Простая альтернатива:** GDScript fallback через соседние клетки — медленнее, уже есть как запасной путь в `validate_place_element`. **Оставить** native primary.
- **Натив:** Да — core validate уже в C++; GDScript только pack (с revision-кэшем) и маппинг результата.

### 11. `ConstructionPlacement.plan`

- **Что делает:** Строит `PlaceElementCommand`: origin/orientation, attach snap context или ground frame, затем **`world.preview_place_element`** (полная kernel-валидация). При `INCOMPATIBLE_CONNECTION` пробует auto-facing (перебор orientation). При успешном attach считает `pose_offset` (точная посадка hub на axle и т.п.).
- **Когда тормозит:** Каждый вызов = validate; auto-facing умножает число validate. Ground plan + seat + collision — отдельно в gateway.
- **Целесообразность:** Нужен для каждого кандидата snap; auto-facing улучшает UX, но дороже.
- **Простая альтернатива:** Убрать auto-facing — красный призрак при «не той» ориентации. **Оставить**, но помнить про умножение validate.
- **Натив:** Только горячий кусок — сам `preview_place_element`/validate; сборка command и auto-facing loop остаются GDScript.

### 12. `ConstructionCommandService.validate_place_element`

- **Что делает:** Проверяет store, revision, occupancy overlap, structural connections (native или GDScript fallback через соседние клетки), bridge/driven-head rules, wheel/piston/rotor/hinge ветки.
- **Когда тормозит:** Большой footprint; много соседей; multibody bridge check.
- **Целесообразность:** Финальная проверка «можно ли записать в мир»; дублируется на preview и на click — намеренно (мир мог измениться).
- **Простая альтернатива:** Упростить до «только overlap» — сломает socket matching и bridge cycle. **Оставить.**
- **Натив:** Уже есть — attach path через `validate_attach_preview`; wheel/driven ветки и store checks — GDScript по необходимости.

### 13. `WorldCommandGateway._seat_ground_plan`

- **Что делает:** Только **новая сборка на земле** (`assembly_id == 0`): по углам collider'ов ищет **самую низкую** точку рельефа под footprint (physics ray + voxel SDF), сдвигает continuous root вниз на ~2 cm embed. Grid topology не трогает.
- **Когда тормозит:** 5 sample-лучей × collider corners; voxel raycast на неровной луне.
- **Целесообразность:** Без seat призрак не совпадёт с финальной посадкой на склонах и сфере.
- **Простая альтернатива:** Садить по одной точке hit — блок висит/врезается. **Оставить** для ground.
- **Натив:** Нет — тонкая обёртка над Godot physics ray и VoxelTool; выигрыш минимален.

### 14. `WorldCommandGateway._guard_placement_collision`

- **Что делает:** `ConstructionPlacementCollision.evaluate`: `intersect_shape` по каждому collider финальной позы — блокирует пересечение с другой конструкцией, игроком, terrain (для physical elements). Grid kernel этого не видит.
- **Когда тормозит:** Много collider'ов у archetype; плотная сцена.
- **Целесообразность:** Нужен, потому что occupancy overlap не видит игрока и динамику.
- **Простая альтернатива:** Полагаться только на occupancy overlap — игрок и динамика пройдут. **Оставить**; на click повторяется намеренно.
- **Натив:** Нет — Godot PhysicsDirectSpaceState; перенос collider loop в C++ дал бы мало против engine API.

### 15. `ConstructionPreview._sync_preview_visuals`

- **Что делает:** Если сменился archetype/orientation/valid — подставляет **уже собранный** набор mesh-узлов (строится один раз в origin ZERO). Каждый кадр только меняет `_mesh_root` (положение и поворот) + `global_transform` из плана (включая `pose_offset`).
- **Когда тормозит:** Смена valid/invalid копирует duplicate из запомненного набора (не полная пересборка с нуля). Первый выбор блока — `_build_mesh_nodes` (piston/rover/drill visuals).
- **Целесообразность:** Split cache/transform — главный выигрыш build mode (см. п.38).
- **Простая альтернатива:** Пересобирать mesh каждый кадр — уже убрали. **Оставить.**
- **Натив:** Нет — presentation layer Godot; `_build_mesh_nodes` грузит `.tscn`, это не hot path каждого кадра.

### 16. `ConstructionPreview._warm_current_selection` / `_warm_archetype`

- **Что делает:** При смене блока в toolbar — заранее собирает valid+invalid mesh-наборы, чтобы при первом прицеле не ждать загрузки сцен.
- **Когда тормозит:** Большие visual_scene / много collider preview meshes при первом выборе.
- **Целесообразность:** Убирает hitch при первом прицеле после смены блока.
- **Простая альтернатива:** Lazy build при первом `_sync_preview_visuals` — заметный hitch. **Оставить** deferred warm.
- **Натив:** Нет — одноразовая загрузка сцен и материалов; не профиль прицела.

### 17. `ToolController` + `_preview.resolved_plan`

- **Что делает:** В режиме `construction_mode == place` клик передаёт **уже готовый** `placement_plan` в gateway (не пересчитывает snap заново на клике).
- **Когда тормозит:** —
- **Целесообразность:** Клик не пересчитывает snap — берёт план, который игрок видел.
- **Простая альтернатива:** Resolve заново на клике — удвоение самого дорогого пути. **Оставить** pass-through; gateway всё равно повторяет collision и validate.
- **Натив:** Нет — копирование словаря и маршрутизация команды; узкое место не здесь.

**Профилирование прицела:** класс `ConstructionPerf` (`scripts/simulation/runtime/construction_perf.gd`) умеет печатать разбивку ms/s по этапам; сейчас **`ENABLED := false`** — включать только локально на время поиска узких мест.

---

## Клик «поставить» — 18–23

### 18. `ToolController._emit_command_for_action`

- **Что делает:** При ЛКМ/ПКМ в режиме place кладёт `parameters["placement_plan"] = resolved_plan.duplicate(true)` (полная копия словаря) и шлёт `construction_apply` в gateway.
- **Когда тормозит:** Копия большого plan dict — обычно быстрее повторного resolve.
- **Целесообразность:** Клик не пересчитывает snap/validate, а только передаёт результат прицела. `duplicate(true)` — страховка от мутаций плана между кадрами.
- **Простая альтернатива:** Передавать ссылку без копии (риск гонок) или тонкий «токен плана» — сложнее и хрупче, выигрыш сомнителен.
- **Натив:** Чистый GDScript-маршрутизация; C++ тут не вызывается.

### 19. `WorldCommandGateway._construction_apply`

- **Что делает:** Если передан valid `placement_plan` — сразу `_apply_place_plan`. Иначе (context mode) — `preview_construction` заново + place или repair по hit.
- **Когда тормозит:** Клик без plan (context на элементе) = **второй** полный preview pipeline.
- **Целесообразность:** Разветвление оправдано: place + непустой `placement_plan` идёт сразу в `_apply_place_plan`.
- **Простая альтернатива:** В place mode жёстко требовать plan (уже так); для context mode — отдельная команда без дублирования place-логики.
- **Натив:** На быстром пути native не трогается. На медленном — **double work**: второй полный resolve (snap → validate → seat → collision), если клик пришёл без plan или в context mode.

### 20. `WorldCommandGateway._apply_place_plan`

- **Что делает:** **Повторный** `_guard_placement_collision` (игрок/мир могли сдвинуться с момента превью). Перезаписывает `store_id` на локального игрока. Вызывает `SimulationWorld.apply_structural_command_now(place)`.
- **Когда тормозит:** Дублирует collision pass — намеренно; узкое место при тяжёлом collider mesh.
- **Целесообразность:** **Double collision guard** — намеренный и нужный: grid kernel не видит игрока и движущиеся тела.
- **Простая альтернатива:** Пропустить повторный collision «если plan свежий» — быстрее, но вернёт баг «красное превью / зелёный клик» и проникновение в динамику.
- **Натив:** Collision — Godot `intersect_shape`, не C++ kernel. После guard идёт `apply_structural_command_now` → ещё одна **kernel-validate** в `place_element` (отдельный слой, не collision).

### 21. `ConstructionCommandService.place_element`

- **Что делает:** Повторно `validate_place_element` (финальная проверка перед записью в мир). Списывает material из store. Создаёт element, rigid joints по connections, terrain contact probe для не-first blocks, `IndustryStoreService.sync_element_storage` **только нового** элемента, `assembly.bump_revision`, `_notify_topology_changed(assembly_id)`.
- **Когда тормозит:** Validate снова — обязательно; первый place на большой базе + cargo ports → пересчёт cargo/industry.
- **Целесообразность:** Финальная **double validate** перед записью в мир — обязательна: между превью и кликом могли измениться материалы, revision, occupancy, attach rules.
- **Простая альтернатива:** Пропустить validate при неизменном `topology_generation` — частичная оптимизация, но не покрывает store/material и гонки. Убрать validate нельзя.
- **Натив:** `validate_place_element` может идти через native attach validate; на клике это **третий** полный kernel-pass после preview validate и **второго** collision guard.

### 22. `ConstructionCommandService.record_placement_terrain_contact`

- **Что делает:** Для construction-archetype на **стационарной** сборке: physics probe «касается terrain?» → флаг + anchor joint если нужно. На роверах пропускается.
- **Когда тормозит:** Extra physics probe на place в базу у земли.
- **Целесообразность:** Только для **не первого** блока стационарной construction-сборки (не ровер): каждый ground-touch блок якорится сам.
- **Простая альтернатива:** Отложить probe до split/reconcile — дешевле клик, но блок может кратко «висеть». Якорить все construction-блоки без probe — неверно для висящих частей базы.
- **Натив:** Чистый GDScript + physics probe (`TerrainAnchorProbe`); не kernel validate и не collision guard.

### 23. `RuntimeConnectivity.materialize_ground_start_anchors`

- **Что делает:** Первый блок новой сборки: создаёт anchor joints на canonical ground face.
- **Когда тормозит:** —
- **Целесообразность:** Только **первый блок новой сборки** на земле: anchor joints сразу после `_seat_ground_plan`, `terrain_contact = true` без probe.
- **Простая альтернатива:** Всегда probe, как в п.22 — лишняя физика на первом блоке. Отложить anchors до physics projection — риск «оторвания» до якорения.
- **Натив:** Чистый GDScript, создание `SimulationJoint.anchor` в runtime graph; C++ не участвует. **Дополнение** к п.22: первый блок якорится по контракту, последующие — через probe.

---

## Снос — 24–27

### 24. `WorldCommandGateway._dismantle_element`

- **Что делает:** Собирает `DismantleElementCommand` с `expected_assembly_revision`, вызывает `apply_structural_command_now`.
- **Когда тормозит:** —
- **Целесообразность:** Низкая — тонкий вход: lookup элемента/сборки, `DismantleElementCommand` с `expected_assembly_revision`, `apply_structural_command_now`. Сам по себе не профилируется.
- **Простая альтернатива:** Не трогать; при лаге сноса смотреть ниже по стеку (#25–27, projection/cargo).
- **Натив:** Нет смысла — нет тяжёлых циклов, только marshalling команды.

### 25. `ConstructionCommandService.dismantle_element`

- **Что делает:** Проверяет revision → `TopologyMutationService.remove_element_from_topology` с refund 50%.
- **Когда тормозит:** —
- **Целесообразность:** Низкая — O(1) проверки revision/store и делегат в `_remove_element_from_topology` с refund 50%. Узкое место не здесь.
- **Простая альтернатива:** Оставить как есть; stale-revision уже отсекает гонки без лишней работы.
- **Натив:** Не нужен — refund по `installed_materials` тривиален.

### 26. `TopologyMutationService.remove_element_from_topology`

- **Что делает:** Удаляет joints элемента, считает mechanical connected components оставшихся. **Без split** — обновляет `element_ids`, `_reconcile_terrain_anchors_for_assemblies`, bump revision, `_notify_topology_changed(assembly_id)`, event `assembly_changed` с `removed_occupied_cells`. **Split** — новые assembly_id, reassign joints, **полный** `_notify_topology_changed()` без id, event `assembly_split`. Пустая сборка → `assembly_removed`.
- **Когда тормозит:** **Split** — самый дорогой снос: сброс preview/occupancy данных **по всему миру**, cargo rebuild, physics split handler, visual rebuild нескольких сборок.
- **Целесообразность:** Высокая при **split**; без split — умеренная (локальный путь). Три ветки: пустая сборка → `assembly_removed`; связность сохранена → `assembly_changed` + локальный `_notify_topology_changed(id)` + `removed_occupied_cells` для точечных visuals; **split** → самый дорогой снос.
- **Простая альтернатива:** **Без split:** уже оптимален — одна сборка, локальный notify, event с клетками для `_try_remove_projected_element`. **Split:** цена — `mechanical_connected_components` + `SurvivorPolicy`, создание N−1 сборок, reassign joints/elements, `reconcile_terrain_anchors` по всем затронутым id, **`_notify_topology_changed()` без id** (сброс occupancy/body-group/native attach **всех** роверов), затем cargo/industry sync и `_handle_split` в physics/visuals. Выигрыш — не split'ить лишний раз (избегать «мостовых» блоков) и позже — global notify только по списку id вместо полного clear.
- **Натив:** Частично: CC по joints/elements можно ускорить в C++, но доминирует не алгоритм, а **global invalidate + projection/cargo**; native CC не снимет split-лаг.

### 27. `ConstructionCommandService.reconcile_terrain_anchors_for_assemblies`

- **Что делает:** После сноса/split: для стационарных construction-сборок — probe terrain contact, add/remove anchor joints, возможен ещё один `_notify_topology_changed`.
- **Когда тормозит:** База с многими ground-touch блоками + изменённый terrain.
- **Целесообразность:** Средняя–высокая для **стационарных баз** с многими construction-блоками у земли; на роверах и пустых сборках почти no-op (`should_reconcile_assembly` отсекает mobile). Вызывается после каждого сноса без split и после split по **всем** новым/выжившим сборкам; при смене anchor joints — ещё один `_notify_topology_changed` + bump revision.
- **Простая альтернатива:** Reconcile только ground-touch элементов вокруг снятой клетки, не всей сборки; кэшировать `terrain_contact` и не probe'ить блоки без соседних изменений terrain; отложить reconcile на конец batch structural commands.
- **Натив:** Слабо: bottleneck — **physics probe** (`TerrainAnchorProbe`) и `RuntimeConnectivity.reconcile_terrain_anchors`, не перебор в GDScript; native поможет только если упаковать probe+diff anchors в один C++ вызов, но ROI ниже, чем у split/global notify.

---

## Побочные эффекты симуляции (топология → cargo → industry) — 28–33

### 28. `SimulationWorld._notify_topology_changed(affected_assembly_id)`

- **Что делает:** Инкремент `topology_generation`. Локально (id > 0): сброс body-group данных, occupancy index, native attach pack **только этой** сборки. Globally (id = 0, split/merge): сброс всего. Всегда: `GridSurfaceUtil.clear_world_face_lookup_cache()`. Затем `_mark_derived_dirty()`.
- **Когда тормозит:** Split/merge бьёт по preview-данным **всех** роверов. Локальный place — только одна сборка.
- **Целесообразность:** Да. После мутации топологии нужно инвалидировать кэши validate/preview. Локальный вызов с `assembly_id > 0` — только **одна сборка**; `id = 0` (split/merge) — **все сборки**. Плюс всегда глобально: `topology_generation++` и `clear_world_face_lookup_cache()` (**весь мир**).
- **Простая альтернатива:** Уже частично есть revision-check на attach pack; можно расширить lazy-invalidate occupancy/body-group «по revision при чтении» и не трогать соседние сборки даже при global notify, если split не затрагивает их id.
- **Натив:** Attach pack уже в C++; сброс словарей GDScript — дёшев. Face lookup cache — отдельный кандидат, но не hot path клика place frame.

### 29. `SimulationWorld._recompute_derived_now`

- **Что делает:** `IndustryNetwork.prune_dangling_links`, purge stale industry runtime, `ensure_player_inventory`, **`CargoGraph.sync`**. Вызывается сразу или отложенно при `batch depth == 0`.
- **Когда тормозит:** См. cargo ниже.
- **Целесообразность:** Да, как единая точка «derived state после топологии»: prune links — обход **всех electric links**; purge industry — ключи **`_industry_elements`**; player inventory — один store; `CargoGraph.sync` — см. п.30.
- **Простая альтернатива:** Разделить: prune links только при dismantle/split; cargo sync только если dirty-сборки cargo-capable; player inventory — один раз при bootstrap, не на каждый place.
- **Натив:** Мало смысла целиком; prune по ~десяткам links — GDScript ок. Тяжёлая часть — cargo (п.31).

### 30. `CargoGraph.sync`

- **Что делает:** Для каждой сборки с изменившимся revision: если **нет** operational cargo-портов — только помечает revision, **без** перескана рёбер. Иначе — полный `rebuild`.
- **Когда тормозит:** Place frame рядом с роверами без cargo — мало работы. Place/снос cargo store, processor, fabricator — rebuild.
- **Целесообразность:** Разумно. Обход **всех живых сборок** (`list_assemblies`): сравнение `topology_revision` с кэшем. Place frame без cargo → O(число сборок), без rebuild.
- **Простая альтернатива:** Передавать `affected_assembly_id` из `_notify_topology_changed` и проверять только dirty id + соседние cargo-элементы (1-hop), а не весь список сборок.
- **Натив:** Решение «rebuild или stamp» — тривиально; выигрыш мал, пока rebuild редкий (frame place).

### 31. `CargoGraph.rebuild` + `CargoConnectivity.find_adjacent_cargo_edges`

- **Что делает:** Собирает все operational элементы с cargo-портами; для **каждого порта** смотрит клетку `port_cell + direction` — O(число портов), не O(n²) по элементам. При rebuild — **полный** scope мира.
- **Когда тормозит:** Много operational cargo-узлов в одной базе.
- **Целесообразность:** Корректно, но при любом cargo-trigger — **полный** rebuild мира: `clear()`, stamp revision **всех сборок**, обход **всех элементов** → фильтр operational + cargo port. Scope — **весь мир**, не одна сборка.
- **Простая альтернатива:** Инкрементальный rebuild: удалить/добавить рёбра только у изменённой сборки и её face-соседей; полный rebuild — fallback при split/merge.
- **Натив:** Главный кандидат: bulk `cell_owner` + port probe + edge dedup в C++ при больших базах (сотни cargo-узлов).

### 32. `IndustryStoreService.sync_element_storage`

- **Что делает:** На place — только новый element (keyed store / internal buffer если archetype требует). **`sync_all_elements`** — только restore/bind, не каждый place.
- **Когда тормозит:** —
- **Целесообразность:** Да. Работа **только с одним переданным element**: keyed store (capacity) если operational + archetype store; `industry_buffer` alloc если нужен.
- **Простая альтернатива:** Уже минимальна; можно отложить buffer alloc до первого recipe tick.
- **Натив:** Нет смысла — пара dict/archetype lookup на элемент.

### 33. `SimulationWorld.apply_structural_command_now`

- **Что делает:** Очередь structural commands; при batch depth > 0 пересчёт производных данных откладывается до конца пакета.
- **Когда тормозит:** Пакетные команды (blueprint spawn) откладывают cargo/industry sync.
- **Целесообразность:** Да как синхронный entry point: allocate `command_id` → `_execute_structural_command`. `_mark_derived_dirty` / `_emit_structural_event` **откладывают** cargo/industry recompute и events при `_structural_batch_depth > 0`. Одиночный клик place — batch depth 0 → recompute сразу.
- **Простая альтернатива:** Авто-batch вокруг multi-place blueprint без явного begin/end; или async queue для UI, но place уже синхронный по контракту.
- **Натив:** Оркестрация; натив имеет смысл только если переносить туда цепочку validate+mutate+notify целиком, что избыточно.

---

## Физика и картинка — 34–37

Реагируют на `structural_event`, не на превью.

### 34. `SimulationPhysicsProjection._on_structural_event`

- **Что делает:** `assembly_spawned` / изменение: сначала пробует **точечное** `_try_append_placed_element` или `_try_remove_projected_element` (добавить/убрать collider на существующем RigidBody без пересборки). Если не вышло — `_reproject_assembly`. Split → `_handle_split`.
- **Когда тормозит:** Точечный путь: single-body rover без wheels/actuators — быстро. Не вышло → full reproject (Jolt bodies, joints, contacts). Multibody / piston / wheels — почти всегда full или multibody append.
- **Целесообразность:** Да — главный рычаг против «contact graph storm» на place/dismantle. Инкремент: single-body без wheels/actuators; multibody — если `_multibody_topology_matches`. Full reproject: `assembly_spawned`, провал try-пути, смена топологии actuators/wheels, mounted-сборка, `assembly_split`/`assembly_merged`, снос endpoint'а на multibody.
- **Простая альтернатива:** Всегда `_reproject_assembly` на любой `assembly_changed` — проще, но каждый frame-блок на L25+ = уничтожение/создание тел, joints, warm-start Jolt.
- **Натив:** Текущая схема уже «нативная» для Godot/Jolt: collider append на существующее тело без `queue_free` body. Полный reproject неизбежен при смене числа rigid groups или joint graph.

### 35. `ElementVisualProjection._on_structural_event`

- **Что делает:** Та же стратегия: `_try_append_placed_element` / `_try_remove_projected_element` (обновить face masks соседей по `removed_occupied_cells`), иначе `_rebuild_assembly`. Split/merge — rebuild нескольких id.
- **Когда тормозит:** Full rebuild L25+ rover = сотни mesh nodes; точечный place/dismantle frame на стоящем rover — целевой быстрый путь.
- **Целесообразность:** Да — зеркало physics-стратегии для мешей. Инкремент: один элемент + refresh face masks соседей. Full `_rebuild_assembly`: `assembly_spawned`, провал try, `assembly_split`/`assembly_merged`, `element_state_changed` кроме damage/repair/weld.
- **Простая альтернатива:** Всегда `_rebuild_assembly` — один код-путь, но на большом ровере каждый place = полный обход `assembly.element_ids` и `_clear_assembly_visuals`.
- **Натив:** Incremental — правильный уровень для Godot (дочерние `MeshInstance3D` на physics body). Full rebuild остаётся для piston/rover-module веток; вынос в C++ мало даёт.

### 36. `PistonVisualProjection` / `IndustryPortProjection` / `IndustryNetworkProjection`

- **Что делает:** Слушают те же events; обновляют piston meshes, port markers, electric link lines. **Piston:** rebuild только если `_event_touches_piston_visuals`. **IndustryNetwork:** на place/changed — ничего (позы wire в `_process`); full `rebuild_all` — split/merge/remove/link. **IndustryPort:** diff-маркеры через `_apply_marker_state`.
- **Когда тормозит:** Много industry-портов на изменённой сборке; UI портов открыт на большой базе.
- **Целесообразность:** Разная, но согласованная. Frame на стоящем ровере **без** piston = skip piston rebuild. Wires уже оптимальны: StaticBody3D + lazy mesh regen. Port markers — лёгкий diff.
- **Простая альтернатива:** Rebuild всех трёх слоёв на каждый `assembly_changed` — проще отладка, но именно это давало hitch на L25.
- **Натив:** Piston visuals привязаны к joint records physics — без incremental filter неизбежен full teardown piston meshes. Wires и port markers — не hot path construction.

### 37. `SimulationPhysicsProjection.sync_body_motion_now`

- **Что делает:** Не construction напрямую, но после exit vehicle и т.п. — форсирует sync pose; влияет на `construction_attach_allowed` к следующей 150 ms проверке.
- **Когда тормозит:** —
- **Целесообразность:** Да, но узко: форс-запись pose/velocity из live `RigidBody` в `assembly.motion`. Вызывается при exit vehicle — чтобы kernel сразу видел реальную скорость. Full reproject здесь **не** происходит.
- **Простая альтернатива:** Полагаться на `_physics_process` motion sync — но между exit и следующим physics tick `assembly.motion` может быть stale, attach к «едущему» роверу даст ложный deny/allow.
- **Натив:** Это и есть правильная граница projection→kernel: один capture + write. Отдельный C++ не нужен.

---

## Сводка: один кадр прицела vs один клик

```text
[каждый physics frame, tool=build]
  InteractionQuery — луч и попадание
    → ConstructionPreview (ключ контекста; при совпадении — без resolve)
      → WorldCommandGateway.resolve_construction_placement
        → ConstructionSnapResolver (scan + до 12× ConstructionPlacement.plan)
          → validate_place_element (native kernel или GDScript)
        → _seat_ground_plan (ground only)
        → _guard_placement_collision
      → ConstructionPreview._sync_preview_visuals (положение меша / готовые mesh-узлы)

[клик place с готовым plan]
  ToolController → construction_apply + placement_plan
    → _apply_place_plan
      → _guard_placement_collision (ещё раз)
      → apply_structural_command_now → place_element
        → validate_place_element (ещё раз)
        → mutate topology + sync_element_storage
        → _notify_topology_changed → cargo/industry sync
        → structural_event → physics + visuals
```

---

## Что уже починили (human changelog) — 38–48

### 38. Превью не пересобирает mesh каждый кадр

- **Целесообразность:** Да — главный источник лишней работы в build mode убран; при неизменном выборе блока остаётся только transform.
- **Простая альтернатива:** По сути сделано; остаток — первый выбор archetype (`_build_mesh_nodes`, warm) и переключение valid/invalid (duplicate из кэша, не полная пересборка).
- **Натив:** Не нужен — это presentation-слой.

### 39. Повторный resolve при неизменном прицеле

- **Целесообразность:** Да — типичный кадр «прицел стоит» больше не гоняет snap/validate; heartbeat 150 ms закрывает движущийся ровер без полного resolve.
- **Простая альтернатива:** Можно event-driven attach вместо опроса, но текущий компромисс прост и дешёв; риск — до ~150 ms задержки «прилипания» после остановки ровера.
- **Натив:** Не трогать — выигрыш уже в пропуске resolve; тяжесть остаётся при смене ключа.

### 40. Магнитный scan

- **Целесообразность:** Да — C++ scan по snapshot + AABB-отсечение резко снижает стоимость коридора луча; fallback нужен без GDExtension.
- **Простая альтернатива:** Без native — не упростить радикально; узкое место смещается в `ConstructionPreviewSnapshot.build` (multibody, много сборок).
- **Натив:** Имеет смысл только если профиль покажет snapshot/pack дороже самого scan — пока оставить.

### 41. Лимиты на дорогие планы

- **Целесообразность:** Да — жёсткий потолок (12 validate / 32 prefilter) защищает от худшего кадра; пропуск ground plan при выигравшей грани — логично.
- **Простая альтернатива:** Уже минимальная политика; остаточный риск — «не тот» snap, если лучшая грань за пределами top-K или при `construction_cycle_snap`.
- **Натив:** Не про натив — это budget/correctness trade-off, менять только по симптомам в игре.

### 42. Быстрая проверка overlap

- **Целесообразность:** Да — `.has()` по occupancy при той же revision дешевле повторной упаковки на каждую грань.
- **Простая альтернатива:** Слой prefilter исчерпан; top-кандидаты всё равно идут в полный validate — это нормально.
- **Натив:** Оставить как есть; быстрый путь в GDScript, тяжёлый — в native validate (п.43).

### 43. Native attach validate

- **Целесообразность:** Да — один C++ вызов + кэш pack по `topology_revision` убирает повторную сериализацию при том же прицеле.
- **Простая альтернатива:** Первый validate после place/dismantle на большой сборке всё ещё дорог; incremental pack — только если это реально в профиле.
- **Натив:** Дальше копать только при доказанном pack-bound; иначе оставить.

### 44. Локальный topology notify

- **Целесообразность:** Да — place/dismantle одной сборки не сбрасывает preview/occupancy чужих роверов; закрывает «лагает рядом, но не на ровере».
- **Простая альтернатива:** Split/merge и terrain reconcile по-прежнему global — это ожидаемо и отдельный класс лагов (снос базы).
- **Натив:** Локализация сброса preview pack — достаточна; global path не трогать без новой архитектуры.

### 45. Cargo graph

- **Целесообразность:** Да — O(порты) neighbor probe вместо тяжёлого полного скана; skip sync без cargo-портов на изменённой сборке — большой выигрыш для frame/структурных блоков.
- **Простая альтернатива:** Place рядом с cargo-базой всё ещё может триггерить `rebuild` — нужен incremental edge update, не упрощение текущего fix.
- **Натив:** Не нужен — граф и так линейный по портам.

### 46. Store sync на place

- **Целесообразность:** Да — очевидная и безопасная оптимизация; `sync_all_elements` только где нужен restore/bind.
- **Простая альтернатива:** Сделано; остаточный риск минимален.
- **Натив:** Не применимо.

### 47. Точечные physics/visuals

- **Целесообразность:** Да — целевой fast path для одного frame на single-body стоящем rover без wheels/pistons; иначе fallback на full reproject — корректно.
- **Простая альтернатива:** Узкий fast path — multibody, колёса, piston почти всегда full rebuild; расширять только точечно по частым кейсам из профиля клика.
- **Натив:** Не про C++ kernel — Jolt/projection; натив не приоритет.

### 48. Double collision guard на клике

- **Целесообразность:** Да — kernel не видит игрока и динамику; повтор в `_apply_place_plan` нужен для корректности («превью зелёное — клик ставит»).
- **Простая альтернатива:** Объединять или кэшировать guard рискованно (мир сдвигается между кадром и кликом); узкое место — тяжёлые collider mesh, не сам факт дубля.
- **Натив:** Batch `intersect_shape` — только если collision стабильно в top профиля клика; иначе оставить как есть.

---

## Куда смотреть дальше — 49–55

### 49. Лагает **только прицел**, FPS падает в build mode

- **Сначала отделить симптом:** сидишь в ровере / build tool **не** активен, небо OK а FPS падает на любом блоке сборки → это **не** construction preview (в seat preview выключен). Смотри `docs/cheatsheets/interaction-read-model.md` и `InteractionQuery._target_metadata` / `list_joints`. Контракт: `PLAYER-INTERACTION-V1` § Interaction Read-Model.
- **Первые подозреваемые (именно build + ghost):** `ConstructionSnapResolver._collect_face_candidates`, `ConstructionPreviewSnapshot.build`, `validate_attach_preview` pack, `_seat_ground_plan`, `_guard_placement_collision`. Включить `ConstructionPerf.ENABLED` локально.
- **Целесообразность:** Сначала убедиться что активен build и идёт resolve; затем `ConstructionPerf.ENABLED` и разбивка; проверить cache по `_cached_resolve_context_key`.
- **Простая альтернатива:** Грубее квантование луча / реже полный resolve при медленном прицеле; уменьшить число сборок в snapshot (AABB); не держать ручной cycle snap без нужды; временно ставить простой archetype для локализации узкого места.
- **Натив:** Да — для build scan/validate; для seat/interaction-card lag натив не первый рычаг.

### 50. Лагает **клик**, прицел плавный

- **Первые подозреваемые:** `_apply_place_plan` collision; второй `validate_place_element`; `_notify_topology_changed` + `CargoGraph.rebuild`; точечный append не сработал → full `_reproject_assembly`.
- **Целесообразность:** Клик не пересчитывает snap (plan уже есть) — смотреть collision, validate, notify/cargo, projection fallback.
- **Простая альтернатива:** Убедиться, что клик идёт с `placement_plan` (не context-mode с повторным `preview_construction`); для frame на single-body rover — довести точечный physics/visual append; place без cargo-цепочки рядом с базой.
- **Натив:** Слабо — узкое место обычно collision, cargo/industry sync и projection, не magnetic scan.

### 51. Лагает **снос** большой базы

- **Первые подозреваемые:** Split в `TopologyMutationService`; global notify; `reconcile_terrain_anchors`; full visual/physics rebuild.
- **Целесообразность:** `remove_element_from_topology` — был ли **split** (global `_notify_topology_changed`, cargo rebuild, несколько assembly); terrain reconcile; full rebuild вместо `_try_remove_projected_element`.
- **Простая альтернатива:** Профилировать один снос с split vs без; для perf-работы — оптимизировать split/global path, не preview; игроку — сносать так, чтобы не резать связность (если применимо).
- **Натив:** Нет — доминируют топология, cargo, terrain anchors, Jolt reproject и mesh rebuild.

### 52. Лаг после place **рядом с ровером**, но не на нём

- **Первые подозреваемые:** Проверить, что `_notify_topology_changed` вызван с `assembly_id`, а не global (0); cargo edges; full reproject соседа.
- **Целесообразность:** Регресс: place на **другой** сборке не должен будить весь мир — audit scope notify и соседних эффектов.
- **Простая альтернатива:** Если баг — починить scope notify; если легитимно (cargo bridge между базой и ровером) — ожидаемо дороже, смотреть `CargoGraph.rebuild` только для затронутых revision.
- **Натив:** Нет — сначала audit scope побочных эффектов place, не C++ scan.

### 53. Превью «не прилипает» к остановившемуся роверу

- **Первые подозреваемые:** `_refresh_heartbeat_attach_permission` (150 ms) + `construction_attach_allowed` (скорость vs parking brake).
- **Целесообразность:** Не полный snap, а stale `_cached_resolve_context_key` без смены луча после остановки + attach policy.
- **Простая альтернатива:** Чуть чаще heartbeat или invalidate ключа при переходе attach_allowed false→true; проверить порог скорости / brake в attach policy.
- **Натив:** Нет — логика разрешения крепления и кэш превью, не perf scan.

### 54. Превью красное, клик всё равно ставит

- **Первые подозреваемые:** `_apply_place_plan` должен снова `validate_place_element` и `_guard_placement_collision`; устаревший plan без второго guard.
- **Целесообразность:** Рассинхрон valid в превью и финального place: preview показывает invalid, а plan dict всё ещё `valid: true`.
- **Простая альтернатива:** На клике жёстко отклонять невалидный plan и не place без свежего validate+collision; синхронизировать invalid превью с флагом plan.
- **Натив:** Нет — баг корректности/контракта gateway, не ускорение kernel.

### 55. Native off (нет GDExtension)

- **Первые подозреваемые:** `_scan_assembly_faces` (march по occupancy каждой сборки) + GDScript `validate_place_element` вместо native scan/validate — бьёт по **прицелу** на многих сборках.
- **Целесообразность:** Ожидаемый fallback — GDScript march + validate; профиль прицела будет хуже native on.
- **Простая альтернатива:** Собрать/включить GDExtension (`regolith_construction_preview`); до этого — меньше сборок в кадре, проще archetype, не сравнивать perf с native on.
- **Натив:** Да — это прямой и правильный рычаг; без него оптимизация GDScript fallback вторична.

---

Спеки и соседние шпаргалки: `docs/specs/CONSTRUCTION-V1.md`, `docs/cheatsheets/simulation-world.md`, `docs/specs/INDUSTRY-V1.md`.
