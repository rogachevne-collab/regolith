# Материалы террейна и ресурсы луны v1

Статус: доменный контракт (спека). Код ещё не обязан совпадать — при реализации
сначала эта спека, потом fixtures/генератор/бур (инвариант R1).

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` — Resource / Recipe / Store;
- `docs/specs/INDUSTRY-V1.md` — машины, stores, excavation, tick (частично
  **замещается** этой спекой в части каталога предметов и добычи);
- `docs/cheatsheets/voxel-tools.md` — координаты и Voxel Tools;
- реф геймплея: Space Engineers (цветные зоны в voxel-земле);
- реф ISRU: водородное восстановление ильменита + электролиз воды (NASA/ESA).

## Индекс

| Вопрос | Раздел |
|---|---|
| зачем и что меняется относительно Industry v1 | «Цель», «Что ломаем» |
| материал вокселя, зоны, обычный грунт | «Модель: зона = материал вокселя» |
| каталог материалов террейна и параметры добычи | «Каталог TerrainMaterial» |
| что сыплется из бура, стройка, газы | «Каталог предметов» |
| где что лежит на луне | «Распределение на планете» |
| как бур считает добычу | «Добыча и yield» |
| кислород и водород | «Вода, кислород, водород» |
| электролизер | «Машина electrolyzer» |
| цепочки и рецепты | «Переработка» |
| как должно выглядеть | «Визуал» |
| что не делаем | «Не входит» |
| критерии для реализации | «Acceptance для реализации» |

## Цель

Сделать лунный грунт **читаемой ресурсной картой**, как в Space Engineers:

1. Разные зоны отличаются по цвету/материалу.
2. Буришь зону — получаешь **свой** набор руд.
3. Обычный реголит (моря / высокогорья) тоже часть системы, не «пустая земля».
4. Из добытого можно собрать базу и запустить **правдоподобное** производство
   кислорода и водорода.

Короткий игровой смысл:

```text
найти зону → пробурить → перевезти → переработать
  → пластины / балки / механизмы (стройка)
  → вода → электролизер → кислород + водород (жизнь / топливо later)
```

## Что ломаем (breaking change)

Старый Industry v1 dual-path **снимается с канона**. В новом контракте **нет**:

| Было | Стало |
|---|---|
| `raw_regolith` | `ore_mare_regolith` / `ore_highland_regolith` |
| `calcined_oxide`, `metal_ingot` | концентраты + `ingot_iron` / `ingot_titanium` / … |
| `construction_component` как единственный BOM | `plate_*`, `girder`, `conduit`, `mechanism` |
| рецепты `crush_regolith`, `calcine_fines`, `reduce_oxide`, `sinter_component` | таблица в § «Переработка» |

Долгого alias для `raw_regolith` **нет**. Реализация обновит ItemCatalog, рецепты,
BOM архетипов и `test_industry_v1` одним breaking-проходом.

`regolith_fines` **оставляем** — один общий дроблёный промежуточный после crush
(удобный вход в спекание).

## Модель: зона = материал вокселя

Как в Space Engineers: материал — **свойство вокселя**, не отдельный объект на карте.

```text
Воксель
  CHANNEL_SDF        — форма грунта
  CHANNEL_INDICES    — индекс материала (8 bit)
        ↓
TerrainMaterialDef   — цвет, твёрдость, что добывается
        ↓
предметы ore_* в Store / loot pile
```

- Источник истины для добычи — **индекс в voxel data**, не цвет шейдера.
- После копки стены карьера сохраняют тот же материал (dig stream уже умеет
  хранить изменённые блоки).
- Формат плагина v1: `VoxelMesherTransvoxel` режим **`TEXTURES_SINGLE_S4`**
  (один индекс на воксель, до 256 типов). См. [Smooth terrains](https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/).
- На terrain нужен `VoxelFormat` с `indices_depth = 8`. Генератор пишет SDF **и**
  INDICES. Смена правил генерации материалов → bump `MoonTerrainParams.GENERATOR_VERSION`.

Обычный фон коры — тоже материалы:

- `mat_mare_regolith` — тёмный реголит морей;
- `mat_highland_regolith` — светлый реголит высокогорий.

Рудные «линзы» — другие индексы с другим цветом и более ценным yield.

## Каталог TerrainMaterial

```text
TerrainMaterialDef {
  id                    # mat_mare_regolith, mat_ilmenite, …
  voxel_index           # 0..255 в CHANNEL_INDICES
  display_name          # для HUD
  visual_slot           # слой Texture2DArray / ключ оттенка
  biome_tags[]          # mare | highland | cold_pocket | any

  hardness              # 0.2 … 1.5; влияет на темп/мощность бура
  density_kg_m3         # масса объёма до collectible_fraction
  collectible_fraction  # доля массы → предметы; остальное пыль (потеря)
  drill_power_mul       # множитель потребления power при резке
  yield_table[] {
    item_id             # ore_* / иногда water-related
    mass_fraction       # доля от collectible массы; сумма ≤ 1
  }
}
```

### Материалы v1

| `id` | index | biome | hardness | density | collectible (дефолт) | основной yield | цвет (задумка) |
|---|---:|---|---:|---:|---:|---|---|
| `mat_mare_regolith` | 0 | mare | 0.45 | 1500 | 0.01 | `ore_mare_regolith` 1.0 | тёмно-серый |
| `mat_highland_regolith` | 1 | highland | 0.50 | 1450 | 0.01 | `ore_highland_regolith` 1.0 | светло-серый |
| `mat_ilmenite` | 2 | mare | 0.85 | 2800 | 0.02 | `ore_ilmenite` 0.85 + mare 0.15 | чёрно-бурый |
| `mat_anorthite` | 3 | highland | 0.80 | 2700 | 0.02 | `ore_anorthite` 0.85 + highland 0.15 | почти белый |
| `mat_olivine` | 4 | highland | 0.75 | 2600 | 0.018 | `ore_olivine` 0.80 + highland 0.20 | оливковый |
| `mat_pyroxene` | 5 | mare | 0.70 | 2500 | 0.018 | `ore_pyroxene` 0.80 + mare 0.20 | коричнево-рыжий |
| `mat_ice_lens` | 6 | cold_pocket | 0.35 | 950 | 0.04 | `ore_ice` 0.90 + фон 0.10 | сине-белый |

Числа — fixtures для playtest; менять вместе с балансом темпа добычи.

**Позже (не v1):** `mat_kreep` и прочие редкие зоны.

Глобальный `IndustryArchetypeProfile.terrain_collectible_fraction` остаётся
fallback'ом; у материала свой `collectible_fraction` **перекрывает** его.

## Каталог предметов

Категории без смены контракта Store: `ore | material | ingot | component | tool | consumable | bottle`.

Вода / O₂ / H₂ в v1 — **bulk** с объёмом «как в баллоне/танке» (условные литры
ёмкости). Отдельный fluid Flow и атмосфера базы — **не** эта спека.

### Руды (`ore`, bulk)

| `item_id` | Откуда | Зачем |
|---|---|---|
| `ore_mare_regolith` | фон морей | дешёвое спекание, общий crush |
| `ore_highland_regolith` | фон высокогорий | светлая керамика |
| `ore_ilmenite` | линзы | железо, титан, **кислород через H₂-reduction** |
| `ore_anorthite` | линзы | алюминий, кремний |
| `ore_olivine` | линзы | магний |
| `ore_pyroxene` | линзы | кремний / флюс |
| `ore_ice` | ледяные карманы | вода → O₂/H₂ напрямую |

### Промежуточные

| `item_id` | category | Роль |
|---|---|---|
| `regolith_fines` | ore | дроблёный hub для sinter |
| `ilmenite_concentrate` | material | обогащённый Fe-Ti |
| `anorthite_concentrate` | material | обогащённый Al-Ca |
| `silicate_slag` | material | хвосты обогащения; можно в sinter |
| `reduced_ilmenite_residue` | material | остаток после H₂-reduction (металл + TiO₂-ish) |
| `water` | consumable | вода (из льда или из reduction) |
| `sintered_basalt` | material | дешёвый спечённый камень |
| `sintered_anorthosite` | material | светлая керамика |

### Слитки (`ingot`, bulk)

| `item_id` | Роль |
|---|---|
| `ingot_iron` | несущие рамы, корпуса |
| `ingot_titanium` | прочные/лёгкие детали |
| `ingot_aluminum` | лёгкая обшивка, ровер |
| `ingot_silicon` | электрика, «стекло», изоляция |
| `ingot_magnesium` | лёгкие сплавы |

### Газы (`consumable`, bulk)

| `item_id` | Роль |
|---|---|
| `oxygen` | дыхание / окислитель (SuitState later) |
| `hydrogen` | восстановление ильменита; топливо later |

Масса/объём на unit — калибруемые fixtures (ориентир в реализации рядом с
прежними Industry числами). Важно: водород **лёгкий по массе**, но занимает
объём танка — `volume_per_unit_l` не нулевой.

### Компоненты стройки (`component`, discrete)

| `item_id` | Куда в базе |
|---|---|
| `plate_basalt` | фундамент, дешёвые стены (`frame_basalt` и аналоги) |
| `plate_metal` | несущие каркасы, корпуса машин |
| `plate_alloy` | лёгкие рамы (ровер, манипуляторы) |
| `girder` | балки, large frame |
| `conduit` | трубы/кабели как модули (`cargo_pipe`, wire supports) |
| `mechanism` | внутренности ротора/поршня/колеса/бура |

Инструменты (`tool_hand_drill` и т.д.) — без изменений смысла; остаются discrete tools.

### Массово-объёмные ориентиры (placeholders)

| `item_id` | unit | mass_per_unit_kg | volume_per_unit_l |
|---|---|---:|---:|
| `ore_*` (реголит фон) | bulk | 2.0 | 2.5 |
| `ore_ilmenite` / `ore_anorthite` / … | bulk | 2.4 | 1.8 |
| `ore_ice` | bulk | 1.0 | 2.2 |
| `regolith_fines` | bulk | 1.5 | 1.8 |
| `*_concentrate` | bulk | 2.2 | 1.2 |
| `silicate_slag` | bulk | 1.8 | 2.0 |
| `reduced_ilmenite_residue` | bulk | 3.0 | 1.0 |
| `water` | bulk | 1.0 | 1.0 |
| `oxygen` | bulk | 0.2 | 2.0 |
| `hydrogen` | bulk | 0.05 | 2.5 |
| `sintered_*` | bulk | 3.0 | 1.5 |
| `ingot_*` | bulk | 4.0 | 0.6 |
| `plate_*` / `girder` / `conduit` / `mechanism` | discrete | 2.0–3.5 | 2.5–4.0 |

## Распределение на планете

Гибрид Space Engineers (глубина залегания) + Factorio (пятна) + лунная геология.

### Биомы

| Биом | Фон | Типичные линзы |
|---|---|---|
| Море (mare) | `mat_mare_regolith` | ilmenite, pyroxene |
| Высокогорье | `mat_highland_regolith` | anorthite, olivine |
| Холодный карман | локальный фон | `mat_ice_lens` |

«Холодный карман» на toy-moon — не обязательно географический полюс: затенённые
участки крупных кратеров / высокие широты по детерминированному правилу от seed.
Игрок должен иметь шанс найти лёд исследованием, не только RNG у ног.

### Алгоритм (логика генератора)

1. По позиции вокселя определить биом (mare/highland — из уже существующей
   дихотомии рельефа).
2. Заполнить solid-воксели фоновым материалом биома.
3. Разложить **пятна** (редко + крупно): hosting-cell на сфере
   (arc ≈ 60–80 м, `LENS_CELL_ARC_M`; direction-scale = `R / arc`, чтобы
   Ø1 km и Ø19 km давали один и тот же метраж) + мягкий радиальный blob;
   coverage на тип руды ~3–5 %, не плотный salt-and-pepper. Привязка к биому.
4. У каждого пятна — **глубина от поверхности** вдоль радиали планеты:
   `start_depth_m` + `thickness_m` (как SE Ore Start/Depth).
5. Кластеры: 2 родственные руды друг под другом (пример mare: pyroxene ближе к
   поверхности, ilmenite глубже).
6. Размер пятна варьирует «богатство»; отдельный purity-enum в v1 не вводим.

Ориентиры глубины (м от поверхности):

| материал | start_depth_m | thickness_m |
|---|---:|---:|
| pyroxene | 2 | 6 |
| ilmenite | 8 | 10 |
| anorthite | 3 | 8 |
| olivine | 10 | 8 |
| ice_lens | 1 | 5 |

### Стартовая зона

В радиусе ~200 м от spawn — **дискретные** гарантированные карманы
(детерминированные offsets от spawn_dir), не заливка всего диска рудой:

- гарантирован фон биома спавна вне карманов;
- ≥1 линза `mat_ilmenite` (радиус ~30 м) + ≥1 мелкий `mat_pyroxene`;
- ≥1 линза `mat_anorthite` (даже если spawn в mare — принудительный карман);
- **либо** ближайший `mat_ice_lens` в разведываемом радиусе (~400–600 м),
  **либо** в стартовом грузе базы есть seed `hydrogen` (см. § bootstrap).

Цель: первый цикл стройки и путь к O₂ не умирают от неудачного seed;
исследование остального шара всё ещё нужно — «где ни копнешь» не работает.

## Добыча и yield

`TerrainExcavationService` по-прежнему:

1. режет SDF;
2. меряет `removed_volume_m3` по occupancy-delta × `voxel_size³`.

Дополнительно (новый контракт):

3. по тем же ячейкам, где matter ушла, собирает веса `material_index`;
4. `TerrainMaterialSource` для каждой доли считает:

```text
mass_kg = removed_volume_m3 × density_kg_m3 × collectible_fraction × weight
для каждой строки yield_table:
  item_mass = mass_kg × mass_fraction
  amount = item_mass / mass_per_unit_kg(item_id)
```

Несколько материалов в одном stamp → несколько предметов пропорционально весам.  
Пустота / повторный бур пустоты → пустой yield (как сейчас).

Ручной бур: yield → player store, остаток → loot pile (pile хранит один
преобладающий `item_id` **или** несколько стеков — реализация: минимум primary
item; лучше multi-stack pile, если уже позволяет модель).

Стационарный бур: в internal buffer; при `storage_full` — политика Industry
(carve/stop — как в актуальном INDUSTRY-V1 на момент реализации; не расширять
silent discard).

`hardness` / `drill_power_mul` в v1 реализации:

- либо замедляют cadence / уменьшают эффективный bite;
- либо повышают `power_w` draw;
- точная формула — в коде рядом с drill services, числа из каталога.

## Вода, кислород, водород

Два реальных пути. Без «электролиза всего реголита», без He-3, без molten-salt
магии.

### Путь A — лёд (простой)

```text
мат. лёд → ore_ice
     → melt_ice (Processor) → water
     → electrolyze_water (Electrolyzer) → oxygen + hydrogen
```

Понятно игроку: нашёл лёд → растопил → разложил воду током.

### Путь B — ильменит + водород (классика ISRU)

Реальная схема (упрощённо в игре):

```text
FeTiO₃ + H₂  →  Fe + TiO₂ + H₂O
2 H₂O        →  2 H₂ + O₂
```

В рецептах:

```text
ore_ilmenite → beneficiate_ilmenite → ilmenite_concentrate (+ slag)
ilmenite_concentrate + hydrogen
     → reduce_ilmenite_h2 (Processor)
     → water + reduced_ilmenite_residue
water → electrolyze_water (Electrolyzer) → oxygen + hydrogen
```

Водород в цикле **почти возвращается**. Net-добыча с Path B — **кислород** из
оксида + металлический остаток. Водород нужен как рабочее тело цикла.

### Откуда берётся первый водород (bootstrap)

Без магии. Один из вариантов обязателен:

1. **Seed с Земли:** в стартовом cargo / player — небольшой запас `hydrogen`
   (хватает на несколько циклов reduce, пока не появится свой H₂ из электролиза).
2. **Сначала лёд:** Path A даёт H₂ → дальше крутишь ильменит где угодно в mare.

Если нет ни seed, ни льда — Path B **не стартует**. Это осознанный constraint.

### Что не делаем для газов в v1

- трубы fluid Flow, давление, утечки;
- баллоны как unique instances (достаточно bulk в store);
- пополнение SuitState из `oxygen` (можно повесить later на те же item_id);
- сжижение / zero-boil-off storage как отдельная механика.

## Машина electrolyzer

Электролиз — **отдельная установка**, не рецепт на `processor`.

```text
archetype_id: electrolyzer
роли: Processor-like (выполняет только recipes с machine = electrolyzer)
```

### Поведение

- Принимает только рецепты машины `electrolyzer` (в v1 — `electrolyze_water`).
- Нужен electric power и cargo path (как processor): pull `water`, push
  `oxygen` / `hydrogen`.
- Включена/выключена через `SetMachineEnabledCommand`.
- При `no_power` / `storage_full` — те же правила, что у processor
  (стоп, без silent discard выхода).

### Порты (минимум)

| порт | тип | смысл |
|---|---|---|
| `power_in` | electric | питание |
| `cargo_in` | cargo | вода (и совместимый I/O) |
| `cargo_out` | cargo | кислород, водород |

Допустимо один `cargo_io`, если так проще в Construction ports — главное, чтобы
электролизер участвовал в cargo graph как потребитель воды и поставщик газов.

### BOM / строительство

Черновик BOM (реализация подставит числа):

- `plate_metal` × N
- `conduit` × M
- `mechanism` × 1

Ставится как стационарный industry-блок на фундаменте/фрейме, рядом с
processor и складом.

### Ёмкость буфера (ориентир)

| владелец | capacity_l |
|---|---:|
| `electrolyzer` internal | 80 |

## Переработка

### Карта цепочек

```text
фон mare/highland ─ crush_* ─ regolith_fines
        ├─ sinter_basalt ─────────→ sintered_basalt → plate_basalt
        └─ sinter_anorthosite ───→ sintered_anorthosite → (панели / тот же plate_basalt
                                                           или отдельный recipe later)

ore_ilmenite ─ beneficiate ─ concentrate (+ slag)
        ├─ reduce_ilmenite_h2 (+ hydrogen) → water + residue
        │         └─ electrolyzer → oxygen + hydrogen
        └─ residue / ветка → ingot_iron, ingot_titanium

ore_anorthite ─ beneficiate ─ concentrate → smelt → ingot_aluminum, ingot_silicon
ore_olivine ─ smelt → ingot_magnesium (+ slag)
ore_pyroxene ─ refine → ingot_silicon (+ slag)

ore_ice ─ melt_ice → water → electrolyzer → oxygen + hydrogen

ingots + sinter ─ craft_* → plate_metal / plate_alloy / girder / conduit / mechanism
```

### Рецепты (канон v1)

Числа duration/power — placeholders.

| `recipe_id` | machine | вход → выход | power_w | duration_s |
|---|---|---|---:|---:|
| `crush_mare` | processor | 1 `ore_mare_regolith` → 1 `regolith_fines` | 200 | 6 |
| `crush_highland` | processor | 1 `ore_highland_regolith` → 1 `regolith_fines` | 200 | 6 |
| `sinter_basalt` | processor | 2 `regolith_fines` → 1 `sintered_basalt` | 250 | 8 |
| `sinter_anorthosite` | processor | 2 `regolith_fines` → 1 `sintered_anorthosite` | 250 | 8 |
| `beneficiate_ilmenite` | processor | 2 `ore_ilmenite` → 1 `ilmenite_concentrate` + 0.5 `silicate_slag` | 300 | 10 |
| `beneficiate_anorthite` | processor | 2 `ore_anorthite` → 1 `anorthite_concentrate` + 0.5 `silicate_slag` | 300 | 10 |
| `melt_ice` | processor | 1 `ore_ice` → 1 `water` | 150 | 5 |
| `reduce_ilmenite_h2` | processor | 1 `ilmenite_concentrate` + 1 `hydrogen` → 1 `water` + 1 `reduced_ilmenite_residue` | 500 | 14 |
| `electrolyze_water` | **electrolyzer** | 1 `water` → 0.5 `oxygen` + 1 `hydrogen` | 400 | 8 |
| `smelt_iron` | fabricator | 1 `reduced_ilmenite_residue` → 0.7 `ingot_iron` + 0.2 `ingot_titanium` | 600 | 12 |
| `smelt_aluminum` | fabricator | 1 `anorthite_concentrate` → 0.5 `ingot_aluminum` + 0.3 `ingot_silicon` | 650 | 14 |
| `smelt_magnesium` | fabricator | 2 `ore_olivine` → 0.4 `ingot_magnesium` + 1 `silicate_slag` | 550 | 12 |
| `refine_silicon` | fabricator | 2 `ore_pyroxene` → 0.6 `ingot_silicon` + 0.8 `silicate_slag` | 500 | 10 |
| `craft_plate_basalt` | fabricator | 2 `sintered_basalt` → 1 `plate_basalt` | 300 | 8 |
| `craft_plate_metal` | fabricator | 2 `ingot_iron` → 1 `plate_metal` | 400 | 10 |
| `craft_plate_alloy` | fabricator | 1 `ingot_aluminum` + 1 `ingot_titanium` → 1 `plate_alloy` | 450 | 12 |
| `craft_girder` | fabricator | 1 `ingot_iron` + 1 `sintered_basalt` → 1 `girder` | 400 | 10 |
| `craft_conduit` | fabricator | 1 `ingot_aluminum` + 1 `ingot_silicon` → 1 `conduit` | 350 | 9 |
| `craft_mechanism` | fabricator | 1 `ingot_iron` + 0.5 `ingot_titanium` + 0.5 `ingot_silicon` → 1 `mechanism` | 500 | 12 |

Инвариант Path B (замкнутый цикл на 1 concentrate):

```text
reduce:       −1 H₂,  +1 water, +1 residue
electrolyze:  −1 water, +1 H₂, +0.5 O₂
────────────────────────────────────────
net:          ΔH₂ = 0,  ΔO₂ = +0.5,  +residue
```

Водород после первого seed не расходуется; копится кислород и металлоостаток.
При желании playtest может ввести крошечную потерю H₂ (например return 0.95) —
но дефолт спеки: **полный возврат**.

Опционально позже: `sinter_from_slag` (slag + fines → sintered_*), чтобы хвосты
не были бесполезны.

### Миграция BOM архетипов

При реализации заменить `construction_component` в `build_requirements`:

| класс архетипов | новый BOM (направление) |
|---|---|
| foundation / frame_basalt / дешёвые стены | `plate_basalt`, `girder` |
| frame / large_frame | `girder`, `plate_metal` |
| processor / fabricator / cargo_store | `plate_metal`, `conduit`, `mechanism` |
| electrolyzer | `plate_metal`, `conduit`, `mechanism` |
| drill / actuators / wheels | `plate_alloy` или `plate_metal` + `mechanism` |
| power_* | `plate_metal`, `conduit` |

Точные количества — в `.tres` fixtures; спека задаёт **какие** item_id допустимы.

## Визуал

- Mesher: `TEXTURES_SINGLE_S4`, шейдер читает `CUSTOM1` (индексы/веса) по доке
  Voxel Tools; текстуры — `Texture2DArray` или тонированные варианты текущего
  rock/dust/mare набора.
- Зоны должны читаться **с поверхности** и на стенах карьера после копки.
- Нельзя выводить gameplay-материал только из procedural albedo без записи в
  `CHANNEL_INDICES`.

Палитра — см. таблицу материалов. Цель: «увидел бурое пятно → ильменит», как
цветные патчи руды в SE.

## Связь с Industry / Construction

| Тема | Где канон после этой спеки |
|---|---|
| ItemCatalog руд/слитков/газов/компонентов | **эта спека** |
| рецепты ISRU + electrolyzer | **эта спека** |
| TerrainMaterial + yield | **эта спека** |
| Voxel scale, raycast, carve geometry | INDUSTRY-V1 § Voxel scale (без смены) |
| cargo/electric graph, stores, tick | INDUSTRY-V1 |
| place/weld/repair команды | CONSTRUCTION-V1 (BOM item_id обновляются) |

`TerrainMaterialSource` перестаёт быть «всегда raw_regolith»: принимает веса
материалов и отдаёт список `{resource_id, mass_kg}`.

## Не входит

- KREEP и прочие редкие зоны;
- Mixel4-блендинг материалов, кисть терраформинга;
- molten regolith electrolysis / FFC / carbothermal с привозным углеродом;
- He-3;
- ore detector UI (можно later по тем же indices);
- fluid pipes / Atmosphere / SuitState refill;
- Mk2 efficiency tiers;
- полная экономическая балансировка чисел.

## Acceptance для реализации

Реализация этой спеки закрыта, когда:

1. Спека в репо; INDUSTRY-V1 / PHYSICAL-LANGUAGE / slice ссылаются сюда.
2. ItemCatalog и RecipeCatalog соответствуют таблицам; legacy ids удалены.
3. Есть archetype `electrolyzer` + рецепт `electrolyze_water` только на нём.
4. Генератор пишет `CHANNEL_INDICES`; фон mare/highland + линзы + ice pockets;
   bump `GENERATOR_VERSION`.
5. Бур (ручной и стационарный) начисляет typed ores по сэмплу материалов.
6. Path A (лёд→вода→O₂/H₂) и Path B (ильменит+H₂→вода→O₂/H₂) проходят через
   stores без dup/loss; bootstrap H₂ соблюдён.
7. Хотя бы один end-to-end: зона → руда → компонент стройки; и отдельно:
   вода → electrolyzer → oxygen/hydrogen.
8. Визуально зоны отличимы в запущенной игре; aim/drill не сломаны (R7).
9. Headless: новый тест каталога/yield + обновлённый industry gate;
   `./tests/run_tests.sh` зелёный.
10. Нет gameplay test-сцен под HUD (R2).

## Порядок реализации (подсказка, не эта поставка)

1. Каталоги предметов/материалов/рецептов + breaking fixtures.
2. Archetype `electrolyzer`.
3. Генерация INDICES + starting overlay.
4. Excavation → multi-yield.
5. Шейдер зон.
6. BOM миграция архетипов.
7. Playtest коэффициентов H₂-цикла и темпа добычи.
