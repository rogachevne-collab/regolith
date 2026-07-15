# Kinetic Interaction v2

Статус: спека-план. Шесть работ поверх закрытого v1 (см.
`KINETIC-INTERACTION-V1.md`), от доводки до нового tier. Каждая секция —
самостоятельный PR; порядок — по приоритету ниже. Кодовые имена модулей — по
состоянию репо на момент написания.

Родительские документы:

- `docs/specs/KINETIC-INTERACTION-V1.md` — контракт `J`, batch, carve v2 (mesh);
- `docs/specs/IMPACT-DESTRUCTION-V0.md` — базовый удар;
- `docs/PHYSICAL-LANGUAGE.md` — «Граница владения», «Кинетический удар»;
- `docs/cheatsheets/vfx-design.md`, `vfx-authoring.md` — для V2-3;
- `docs/specs/INDUSTRY-V1.md` § Voxel scale — для carve-работ.

## Приоритет

| # | Работа | Размер | Зависимости | Статус |
|---|--------|--------|-------------|--------|
| V2-1 | Честный carve-бюджет | часы | — | ✅ реализовано |
| V2-2 | Grind-борозда sustained | часы | — | ✅ реализовано |
| V2-3 | VFX удара | ~день | — | план |
| V2-4 | Лут от кинетики | ~день | V2-1 | ✅ реализовано |
| V2-5 | Tier 2: давление / yield | дни | V2-1; желательно после V2-4 | план |
| V2-6 | Урон игроку | дни | V2-5 не нужен; после V2-3 логично | план |

---

## V2-1 — Честный carve-бюджет

**Проблема.** `WorldCommandGateway.apply_terrain_carve(op, _volume_budget_m3)`
игнорирует параметр бюджета: `V_MAX_M3 = 2.0 м³/кадр` из v1 не enforce'ится.
Каскад entries за кадр (или один крупный mesh-стамп) может вырезать больше.

**Контракт.**

- Бюджет передаётся в `TerrainExcavationService.excavate` полем запроса
  `volume_budget_m3` (default `INF`).
- Excavation **оценивает** объём стампа до применения:
  - sphere: `sphere_volume_m3(radius) · sdf_scale`;
  - path: сумма сфер сегментов (грубая верхняя оценка допустима);
  - mesh: объём OBB стампа `size.x·size.y·size.z · sdf_scale`
    (без margin; верхняя оценка).
- Если оценка > остатка бюджета — стамп **уменьшается**, не отбрасывается:
  sphere/path — масштаб радиусов `∛(budget/estimate)`; mesh — масштаб
  transform basis тем же коэффициентом. Ниже
  `TerrainImpactCarver.minimum_measurable_radius_m` — отказ (`0.0`).
- Фактический `removed_volume_m3` (уже считается по before/after SDF)
  возвращается как и сейчас; `_flush_batch` продолжает вычитать факт.
- Damage элементов бюджетом carve **не** ограничивается (инвариант v1).

**Модули.** `world_command_gateway.gd` (проброс), `terrain_excavation_service.gd`
(оценка + downscale), `terrain_impact_carver.gd` (helper оценки объёма op).

**Acceptance.**
1. Один кадр, N entries суммарной оценкой > `V_MAX_M3` → фактический
   суммарный `removed_volume_m3` ≤ `V_MAX_M3 · 1.15` (допуск на SDF-дискрет).
2. Damage от entries после исчерпания бюджета не теряется (регрессия v1).
3. Headless: тест в `test_impact_destruction` (несколько entries, проверка
   суммы объёмов).

---

## V2-2 — Grind-борозда sustained-канала

**Проблема.** Sustained-упор (пистон/бур давит, carriage ползёт) бьёт сферой в
одну точку с cooldown 80 мс — точечная эрозия вместо борозды по ходу движения.

**Контракт.**

- `ImpactResolverService` хранит по batch_key sustained-канала последнюю
  carve-точку (`_last_sustained_contact: Dictionary`).
- Если расстояние prev→current ∈ [`0.5·voxel`, `4·voxel`] — эмитится
  `build_path_op([prev, current], [r, r], strength)` вместо сферы
  (механика идентична траншеям ручного бура). Иначе — сфера, как сейчас.
- Радиус — от collider'а ударника (как в sphere op), направление bite —
  carve_direction v1.
- Запись очищается при `applied_force_n → 0`, overload, смене element_id и
  по таймауту `> 0.5 с` без эмита.
- Бюджет — общий (V2-1).

**Модули.** `impact_resolver_service.gd` (`emit_actuator_sustained_entry` +
состояние), `terrain_impact_carver.gd` (без изменений — `build_path_op` есть).

**Acceptance.**
1. Пистон с бором, медленный горизонтальный/вертикальный ход под нагрузкой →
   непрерывная канава, не цепочка отдельных ямок (проверка в игре, playground).
2. Стоящий на месте упор — прежнее поведение (сфера, затухание к overload).
3. Headless: два последовательных sustained-эмита с малым смещением дают
   path-op (юнит на выбор формы op).

---

## V2-3 — VFX удара

**Проблема.** Carve и damage работают, но удар «немой»: ни пыли, ни обломков —
слабый player feedback.

**Контракт (R4: декларативные `.tscn` в `scenes/vfx/`, без логики).**

- Новая композиция `scenes/vfx/kinetic_impact_burst.tscn`:
  `GPUParticles3D` one-shot (пыль + комья), параметризуется через
  `presentation`-слой: `amount_ratio`/`scale` от `strength`, ориентация —
  `contact_normal`.
- Источник события: `ImpactResolverService` после `_apply_entry` с
  `strength > 0` эмитит **сигнал** `impact_applied(contact_world,
  contact_normal, strength, carved_m3)` — presentation подписывается;
  simulation не знает о VFX (граница владения v1).
- Presentation-слой (`scripts/presentation/…`) спавнит burst с пулом
  (макс ~8 живых, LRU) и отсекает по расстоянию до игрока (> 60 м — скип).
- Sustained-канал: не чаще 4 Гц на batch_key (иначе дым-машина).
- Шейдеры — только текстом (R3), сверка с `vfx-design.md` (палитра пыли
  реголита, низкая гравитация 1.62 — частицы летят выше и дольше).

**Acceptance.**
1. Drop-демо playground: видимый burst пыли в точке удара, размер растёт со
   strength; в логах чисто (проверка в игре + скриншот).
2. Слабое касание < `I_MIN` — без VFX.
3. Sustained grind — редкие затяжные клубы, не сплошной поток.
4. Headless-тестов нет (R2 — презентация верифицируется в игре).

---

## V2-4 — Лут от кинетики

**Проблема.** Кинетически вырезанный реголит исчезает (v1 приняла это
осознанно). Игрок не получает ничего за slam/таран — а ручной бур получает.

**Контракт.**

- Порог: лут только при `J_effective ≥ I_LOOT` (новая константа
  `ImpactResolver.I_LOOT := 12.0 Н·с` — между `I_MIN` и `I_REF`; удары «в мусор»
  не фармятся).
- Масса: `TerrainMaterialSource.yield_for_removed_volume(carved_m3,
  KINETIC_COLLECTIBLE_FRACTION)`; `KINETIC_COLLECTIBLE_FRACTION := 0.35` —
  удар разбрасывает грунт, КПД ниже бура (у бура 1.0). Баланс — крутилка.
- Доставка: **world loot pile** через существующий
  `SimulationWorld.add_world_loot_pile(contact_world, resource_id, mass_kg)` —
  НЕ в инвентарь игрока (нагибаться/собирать, как прочий лут). Пайплайн тот же,
  что у экскавации gateway.
- Источник: `_apply_terrain_carve` возвращает carved_m3 → `_apply_entry`
  после carve вызывает yield. Только terrain-партнёр; sustained-канал тоже
  даёт лут (бур на пистоне = машинная добыча, fraction та же).
- Спека v1 «Материал грунта» помечается заменённой этим разделом.

**Модули.** `impact_resolver.gd` (`I_LOOT`), `impact_resolver_service.gd`
(yield после carve), `terrain_material_source.gd` (fraction-параметр уже есть).

**Acceptance.**
1. Slam с `J ≥ I_LOOT` → pile `raw_regolith` у кратера, масса ≈
   `carved_m3 · 1500 · 0.35`.
2. `I_MIN ≤ J < I_LOOT` → carve есть, лута нет.
3. Headless: тест yield-порога и массы в `test_impact_destruction`.
4. Регрессия: добыча ручного/стационарного бура не изменилась.

---

## V2-5 — Tier 2: давление и yield материала

**Проблема.** v1 — единый скаляр `J`: игла и плита с одинаковым импульсом бьют
одинаково. Нет понятия «продавить материал».

**Контракт (первый срез, без FEM).**

- Новая величина на контакт: `P = F_eff / A_contact`, где
  `F_eff = J_effective / Δt_physics`, `A_contact` — площадь пятна:
  для box-коллайдера — площадь грани, ближайшей к `contact_normal`
  (по доминирующей оси нормали в локале коллайдера), клэмп снизу
  `A_MIN := (0.5·voxel)²`.
- Материалы получают `yield_pressure_pa`:
  - terrain (реголит): константа в `TerrainMaterialSource`
    (`REGOLITH_YIELD_PA`, старт ~40 кПа — тюнинг в игре);
  - элементы: поле в `ElementArchetype` (default по материалу frame/plate).
- Эффекты:
  - `P < yield` партнёра → carve/damage партнёру **гасятся** множителем
    `(P/yield)²` (клэмп [0,1]) — тупой предмет вязнет;
  - `P ≥ yield` → как v1 (без бонуса в первом срезе);
  - глубина bite mesh-стампа масштабируется `clamp(P/yield, 0.5, 2.0)` —
    острые/узкие грани прогрызают глубже.
- Дизайн-принцип v1 сохраняется: никаких safe-clamp скорости; Tier 2 меняет
  только **распределение** реакции, не защищает от reckless.
- `I_MIN`/`I_REF`/бюджет не трогаются.

**Модули.** `impact_resolver.gd` (площадь пятна, множители),
`impact_resolver_service.gd` (прокладка `A_contact` из collider+normal),
`terrain_material_source.gd`, `element_archetype.gd` (+ ресурсы архетипов),
спека-приложение с таблицей yield.

**Acceptance.**
1. Плита плашмя и ребром с одинаковым `J`: ребро режет заметно глубже,
   плашмя — мельче v1 (проверка в игре).
2. Элемент с высоким yield (armor-frame, если введён) от слабого тычка не
   теряет integrity, от драматичного slam — теряет.
3. Headless: юниты на `A_contact` (грань по нормали), множитель `(P/yield)²`,
   монотонность по F.
4. Регрессия: acceptance v1 №1-8 не ломаются (пороговые значения подобрать
   так, чтобы текущие демо-стенды сохраняли поведение).

---

## V2-6 — Урон игроку от кинетики

**Проблема.** Игрок неуязвим: летящая сборка/carriage проходит сквозь клетку
классификации («игнор в v1»).

**Контракт.**

- Классификация v1 расширяется: партнёр `CharacterBody3D` игрока (группа
  `player` или ссылка из bootstrap) — новый исход `player_hit`, эмитится тем
  же batch (cooldown на пару), **без** carve и без damage элементу ударника
  ниже `I_MIN`.
- Урон здоровью: `hp = clamp(J_effective / I_REF, 0, 1)² · K_PLAYER_DAMAGE`
  (`K_PLAYER_DAMAGE := 35.0` hp при референсном ударе; смертельно от ~2×I_REF —
  тюнинг). Та же квадратичная кривая, что у элементов — единый язык силы.
- Доставка: `SuitState.apply_damage(amount, source)` (новый метод;
  `SuitState` уже владеет `health`) — только через главный поток,
  `call_deferred` из flush. Simulation не знает о HUD; HUD читает SuitState
  как сейчас.
- Игрок-«ударник» (упал на постройку) — НЕ в этой работе: только тело
  сборки → игрок. Падение самого игрока — отдельная существующая механика.
- Iframe: cooldown пары batch_key (80 мс) + личный кулдаун игрока 250 мс,
  чтобы скольжение вдоль тела не тикало каждый кадр.

**Модули.** `impact_resolver.gd` (классификация `player_hit`),
`impact_resolver_service.gd` (маршрут + кулдаун), `suit_state.gd`
(`apply_damage`), HUD — без изменений (уже отображает health).

**Acceptance.**
1. Ровер тараном по игроку на скорости → health падает пропорционально `J`;
   слабое касание — 0.
2. Никакого carve/самоповреждения сборки от контакта с игроком (регрессия v1).
3. Кулдаун: непрерывный прижим не убивает мгновенно, тикает ≤ 4 Гц.
4. Headless: юнит формулы урона; поведение — в игре (R2).

---

## Верификация (общая)

- Ядровые формулы/пороги — `./tests/run_one.sh test_impact_destruction`
  (V2-1, V2-2, V2-4, V2-5, V2-6-формула).
- Feel/VFX/борозды/давление — запущенная игра, playground
  `scenes/test_kinetic_playground.tscn` (+ новые стенды: плита плашмя/ребром
  для V2-5, таран игрока для V2-6). Финал — человек.
- Полный гейт `./tests/run_tests.sh` перед каждым «готово».

## Не входит в v2

- FEM, fracture-меши, деформация коллайдеров;
- debris-тела грунта как rigid bodies (только VFX-частицы);
- урон игроку от его собственного падения (существующая механика) и от
  ручных инструментов;
- сетевые/мультиплеерные соображения.
