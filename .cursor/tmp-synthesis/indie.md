# Разрушение, копание, рыхлый грунт и жидкости — обзор по категориям техник

Структура: **категория → игры → техника → что реально / что фейк → источники → достижимо ли в Godot для малой команды**.

---

## 1. Voxel destruction + физика обломков

### Teardown (Tuxedo Labs) — эталон «всё ломается по-настоящему»

**Техника:**
- Кастомный C++ движок; мир — **тысячи отдельных voxel volumes**, не один глобальный грид.
- Рендер: **raymarch по voxel volumes** на GPU (не triangle mesh).
- Физика: **voxel-vs-voxel collision на CPU**, SIMD + multithreading.
- При разрушении: **flood-fill** находит оторванные куски → каждый кусок становится **отдельным rigid body** (новый volume).
- Multiplayer: **детерминированные команды разрушения** (не передают voxel data по сети); physics — state sync.

**Впечатляет:** настоящее процедурное разрушение без pre-fracture; обломки — полноценные физические тела.

**Фейк / ограничения:** земля под ногами и скалы — **неразрушаемы** (дизайн); вода и ЛЭП — не voxels; GI нет (ambient occlusion + soft shadows через raymarch).

**Источники:**
- [Game Developer — GDC Twitch breakdown](https://www.gamedeveloper.com/design/how-beautiful-voxels-laid-the-way-for-i-teardown-s-i-heist-y-framework)
- [80.lv interview (multiplayer, 2026)](https://80.lv/articles/teardown-developer-breaks-down-multiplayer-and-voxel-destruction-tech/)
- [Voxagon Blog — design notes](https://blog.voxagon.se/2020/11/05/teardown-design-notes.html)
- [Cracking destruction (Smash Hit → plane-splitting)](https://blog.voxagon.se/2014/05/13/cracking-destruction.html)

**Godot для малой команды:** полный Teardown — **нет** (годы + custom engine). Урезанный вариант: SDF carve (Voxel Tools) + spawn `RigidBody3D` mesh-chunks при отрыве куска — **PoC да**, масштаб Teardown — нет.

---

### Medieval Engineers / Space Engineers (Keen, VRAGE)

**Техника:**
- **Grid-based volumetric blocks** с mass/inertia; Havok physics.
- **Structural integrity** — граф поддержки; повреждённые блоки теряют несущую способность → cascade collapse.
- Voxel terrain (SE): **free-form volumetric surface**, mineable, LOD.
- VRAGE3 (SE2): эксперименты с **metaball SDF furrows** при посадке (impulse → сферы в точках контакта).

**Впечатляет:** collapse зданий из блоков; огромные планеты.

**Фейк:** tensile strength упрощён; voxel terrain **не granular** — вырезание, не осыпание; furrows в VRAGE3 — **visual SDF overlay**, не DEM.

**Источники:**
- [VRAGE engine page](https://www.keenswh.com/vrage/)
- [Medieval Engineers features](https://www.medievalengineers.com/features/)
- [VRAGE3 update — Marek Rosa blog](https://blog.marekrosa.org/2023/04/guest-post-jan-hlousek-vrage3/)

**Godot:** grid blocks + Jolt + простой structural graph — **реально** для построек; не для terrain на планетоиде.

---

### Besiege (Spiderling)

**Техника:** **не terrain** — spring-joint connections между блоками; rigidity от mass/scale. «Interlock» — collision-based custom joints. Разрушение = joints ломаются / blocks отваливаются.

**Фейк:** не симуляция материала; community exploits (0D joints, scaling).

**Godot:** `Generic6DOFJoint3D` / Jolt constraints — **да**, для машин; не для regolith.

---

## 2. Particle / cellular sand & fluids (2D и «каждый пиксель»)

### Noita (Nolla Games, Falling Everything engine)

**Техника:**
- **Falling sand / cellular automata** на CPU; каждый пикsel — материал с правилами.
- Мир: chunks **512×512**, активных ~12; внутри — **64×64** + dirty rects.
- Multithreading: **checkerboard 4 passes** (без atomics на shared pixels).
- Update **bottom-up** для гравитации.
- Rigid bodies из pixel clusters: **marching squares → triangulation → Box2D**.
- Off-screen: lazy update (иногда «полка жидкости» падает при входе в кадр).

**Впечатляет:** химия, fire, pressure, emergent behavior.

**Фейk:** не 3D; rigid bodies — **оболочка поверх CA**, не granular DEM.

**Источники:**
- [80.lv technical interview](https://80.lv/articles/noita-a-game-based-on-falling-sand-simulation)
- [GDC Vault — Exploring the Tech and Design of Noita](https://www.gdcvault.com/play/1026180/Exploring-the-Tech-and-Design) (summary: [braindump](https://braindump.jethro.dev/posts/gdc_vault_exploring_the_tech_and_design_of_noita/))
- [Ben Lau notes (Reddit AMA summaries)](https://benlau6.github.io/notes/noita/)

---

### The Powder Toy (open source, GPL)

**Техника:** C++, **particle grid** + pressure/velocity/heat; element callbacks в `Simulation.cpp`; Lua API. Fork с multithreading.

**Godot:** 2D compute shader / GDExtension CA — **PoC** на тысячи пикселей; полный Powder Toy в 3D — overkill для Regolith.

**Источник:** [GitHub — The-Powder-Toy](https://github.com/The-Powder-Toy/The-Powder-Toy)

---

### WorldBox

**Техника:** 2D tile CA + Perlin terrain; falling sand/water/lava как **local rules** на grid (TIGSource devlog).

**Фейк:** «physics» = transition rules, не Navier-Stokes.

**Источник:** [TIGSource thread](https://forums.tigsource.com/index.php?topic=64770.0)

---

## 3. Block voxels + falling blocks (entity-based «песок»)

### Minecraft

**Техника:**
- `FallingBlock` → при потере опоры **scheduled tick** → spawn **`FallingBlockEntity`** (gravity entity).
- При landing: block state или drop item.
- Instant fall в lazy chunks (teleport вниз без entity).

**Впечатляет:** дешёво, предсказуемо, moddable.

**Фейк:** не granular pile; один блок = один entity; нет angle of repose.

**Источники:**
- [Threadstone Wiki — gravity-affected blocks](https://github.com/Threadstone-Wiki/Threadstone-Wiki/blob/main/pages/falling-block/gravity-affected-block.md)
- [Minecraft Wiki — Falling Block](https://minecraft.wiki/w/Falling_Block)

---

### Minetest / Luanti

**Техника:** `falling_node=1` group → `__builtin:falling_node` entity; `core.check_for_falling()` — flood scan соседей.

**Open source:** [builtin/game/falling.lua](https://github.com/minetest/minetest/blob/master/builtin/game/falling.lua)

**Godot:** аналог — при carve voxel column проверять unsupported blocks → spawn rigid body или «instant fall». **Реально** поверх VoxelMesherCubes.

---

### Veloren (Rust, open source)

**Техника:** **block voxels** + **greedy meshing** (не marching cubes); отдельный fluid mesh (water/lava flow); light BFS.

**Digging:** modify voxel chunk → remesh affected chunks.

**Источники:**
- [GitHub — veloren/veloren](https://github.com/veloren/veloren)
- [Terrain rendering (DeepWiki)](https://deepwiki.com/veloren/veloren/5.3-terrain-rendering)

**Godot:** Voxel Tools blocky mode + greedy mesher — близкий стек.

---

## 4. SDF / density voxels + surface extraction (smooth terrain dig)

### Astroneer (System Era)

**Техника:**
- 3D voxel grid с **density scalar** (+ solid / − air).
- Surface: **Marching Cubes** per chunk.
- Deform: subtract/add density в brush → **remesh только dirty chunks** + collision rebuild.

**Впечатляет:** smooth tunnels, natural look.

**Фейк:** нет loose soil physics; выкопанное **исчезает** или становится inventory.

**Источник:** [Game Developer — Astroneer Early Access postmortem](https://www.gamedeveloper.com/design/what-i-astroneer-i-s-devs-learned-while-leaving-early-access)

---

### Enshrouded (Keen Games, Holistic Engine)

**Техника:** proprietary **full voxel world**; negative stamps для caves; voxel brush в editor; persistence только near Flame Altar (~2h wilderness reset).

**Фейк:** детали engine closed; granular flow не заявлен.

**Источники:**
- [YouTube — Creating the world](https://www.youtube.com/watch?v=N0qrbfkcLEg)
- [Technical analysis (Holistic Engine)](https://foro3d.com/en/2026/march/technical-analysis-of-the-holistic-engine-from-enshrouded.html)

---

### Space Engineers (VRAGE2)

**Техника:** voxel asteroids/planets — **cut/sphere/ellipsoid** через `MyVoxelBase`; immobile, no gravity; materials per voxel type.

**Фейk:** cut = boolean, не regolith pile.

---

### 7 Days to Die

**Техника:** voxel chunks + **isosurface mesh** (smoother than MC blocks); heightmap на генерации; runtime voxel edit per chunk.

**Источник:** [MU thesis on terrain deformation](https://is.muni.cz/th/ir767/thesis.pdf)

---

### Scrap Mechanic

**Техника:** **density + material** voxels; `terrainSphereModification()`; convex hull edits; events `server_onVoxelDestruction`.

**API:** [Scrap Mechanic WorldClass](https://scrapmechanic.com/api/class_Game_WorldClass.html)

---

### Satisfactory

**Техника:** **нет deformation** — static meshes. Terraforming потребовал бы полного rebuild (официальный ответ community Q&A).

**Источник:** [Satisfactory Q&A — Digging in terrain](https://questions.satisfactorygame.com/post/67eccb1a6b7c573196362a90)

---

### TerraTech

**Техника:** **нет terrain digging** — destructible scenery (trees, rocks) с damage types; procedural spherical worlds.

**Источник:** [TerraTech damage types](https://terratechgame.com/damage-vs-damageable-types/)

---

## 5. Heightfield mud / tire tracks (2.5D deformation)

### MudRunner / Spintires / SnowRunner (Saber / Pavel Zagrebelnyy)

**Техника (эталон «красиво и дёшево»):**
- Terrain: **16×16 m blocks**, heightfield mesh.
- **Два representation:** CPU physics ≠ GPU render data.
- Texture 1 (25×25): base height, material mix, **alpha = mud substitution mask**.
- Texture 2 (128×128, only muddy blocks): **mud height offset**, GB = mud slide offset, A = track blend.
- CPU рисует **primitives** (wheel penetration, velocity) в RT → GPU displaces mesh.
- Havok traction на heightfield; mud forces — **empirical**, не из RT.
- Wheel tracks: **2-pass parallax** projected mesh.
- Water: geometric waves + **8-bit RGBA propagation shader** (not float textures).
- Mud chunks: rigid bodies как «plants»; mud particles — **decoration only**.

**Впечатляет:** визуально убедительная грязь при 1 km maps.

**Фейк:** «very vague connection to real world physics» — слова lead dev; CPU/GPU desync intentional.

**Источники:**
- [Game Developer — Mud and Water (lead dev, 16 min read)](https://www.gamedeveloper.com/programming/mud-and-water-of-spintires-mudrunner)
- [80.lv breakdown](https://80.lv/articles/breakdown-mud-and-water-of-spintires)
- [Modding guide PDF](https://cdn.focus-home.com/admin/games/spintires_mudrunner/docs/ModdingGuide_Mudrunner.pdf)

**Godot:** `HeightMapShape3D` + `ImageTexture` update + shader displacement — **очень достижимо**; Regolith уже близок (`GranularPatch`).

---

### Valheim

**Техника:** **heightmap modifiers**, не 3D voxels — нельзя пещеры; mod stack height deltas on base heightmap; ~±8 m limit (moddable).

**Фейк:** «terraforming» = 2.5D; на крутых склонах артеfacts.

**Источники:**
- [Unity Discussions — reverse engineering notes](https://discussions.unity.com/t/how-to-make-terrain-and-world-map-like-valheim/881308/3)
- [Heightmaps vs Voxels essay](https://ckempke.github.io/UnityTerrainGeneration/heightmaps_and_voxels/)

---

## 6. Sediment / water как gameplay, не simulation

### Hydroneer

**Техника:** **pressure arithmetic** (intake +50%, −1% per pipe, filters, dirty water → repair timer). **Нет** sediment transport, hydraulic erosion, particle water.

**Фейк:** «sediment» = dirty water stat, не terrain.

**Источники:** [Steam Hydro-Engineering guide](https://steamcommunity.com/sharedfiles/filedetails/?id=2099246044)

---

## 7. Lunar / Mars rover sims

| Проект | Техника | Реальность |
|--------|---------|------------|
| **Исследовательские (arxiv 2024–2026)** | DEM offline → **regression sinkage/slip** → runtime **heightmap pixel edit** + mesh vertex offset; Isaac Sim integration | Tracks **visual + terramechanics params**; не particle soil |
| **Isaac Sim (NVIDIA)** | Granular soil **не в roadmap**; Newton/Warp — future | Форум: [Soil Deformation thread](https://forums.developer.nvidia.com/t/soil-deformation-in-isaac-sim/329569) |
| **Игры (Mars Horizon, etc.)** | Обычно rigid terrain + wheel friction curves | Tracks часто decal или не persistent |

**Источники:**
- [Terrain deformation by grouser wheel (arxiv)](https://arxiv.org/abs/2408.13468)
- [Data-driven terramechanics (2026)](https://doi.org/10.48550/arxiv.2601.04547)

**Вывод для лунного sandbox:** industry standard для real-time = **fake heightfield + Bekker/regression**, не DEM.

---

## 8. Procedural erosion (offline / research, не runtime games)

**Nick's Procedural Hydrology:** particle-based hydraulic erosion на heightmap; momentum-map для meandering — **offline world gen**, не интерактивный копатель.

**Источник:** [Particle-based hydraulic erosion](https://nickmcd.me/2023/12/12/meandering-rivers-in-particle-based-hydraulic-erosion-simulations/)

---

## Сводная таблица «реально vs фейк»

| Категория | Что выглядит real | Что обычно fake |
|-----------|-------------------|-----------------|
| Voxel debris (Teardown) | Connected-component split, voxel collision | Static ground, water surface |
| CA sand (Noita) | Local material rules, chain reactions | 3D volume, structural load |
| Block fall (MC) | Gravity entity | Pile physics, arching |
| SDF dig (Astroneer) | Smooth cavity | Spoil pile, runoff |
| Heightfield mud (MudRunner) | Tracks, sink, slide shader | Continuum mechanics, GPU↔CPU match |
| Fluids in games | Shader + height propagation | Navier-Stokes 3D |
| Lunar rover research | Sinkage regression | Per-grain contact |

---

## Что достижимо малой команде в Godot (приоритеты)

У Regolith уже заложена **правильная гибридная архитектура** (`GRANULAR-V0.md`): **SDF скала (Voxel Tools) + `GranularPatch` heightfield для рыхлого**. Это совпадает с industry pattern «Astroneer dig + MudRunner pile».

### Tier A — core (3–6 мес., 1–2 dev)

1. **Voxel Tools Transvoxel SDF** — carve, collider regen, material index (`VoxelTool.MODE_REMOVE`, `do_sphere`). [Docs](https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/)
2. **`GranularPatch`** — thickness grid, angle-of-repose relax, `HeightMapShape3D` — уже в спеке.
3. **Dig → deposit spoil** на патч (volume conservation), не delete.
4. **Presentation:** grit mesh + VFX stream (declarative `.tscn`) — без physics grains.

### Tier B — polish (ещё 3–6 мес.)

5. **Wheel/track decal** MudRunner-style: RT или `Image` paint по contact points (visual only).
6. **Falling column** (Minecraft-lite): unsupported voxel column → collapse to granular deposit (не entity per grain).
7. **Settle/load** под rover (упрощённый Bekker) — уже в спеке, tune amplitudes.

### Tier C — не для v0

8. Full Teardown debris pipeline.
9. Noita-scale 3D CA fluids.
10. DEM / granular Jolt per-particle.
11. GPU marching cubes each frame (unless compute-heavy port).

### Godot-стек

| Задача | Tool |
|--------|------|
| Planetoid dig | `VoxelLodTerrain` + `VoxelMesherTransvoxel` |
| Loose regolith | Custom `GranularPatch` + Jolt static heightfield |
| Small debris | `RigidBody3D` + convex hull, limited count |
| Mud visual | Shader displacement from `Image` |
| Fluids v0 | Fake: flat mesh + flow direction in texture (MudRunner water) |

---

## Рекомендуемые первоисточники (GDC / postmortem / blogs)

| Тема | URL |
|------|-----|
| Teardown voxel + destruction | [Game Developer GDC Twitch recap](https://www.gamedeveloper.com/design/how-beautiful-voxels-laid-the-way-for-i-teardown-s-i-heist-y-framework) |
| Teardown multiplayer sync | [80.lv 2026](https://80.lv/articles/teardown-developer-breaks-down-multiplayer-and-voxel-destruction-tech/) |
| Noita falling sand | [80.lv](https://80.lv/articles/noita-a-game-based-on-falling-sand-simulation) |
| Astroneer marching cubes | [Game Developer postmortem](https://www.gamedeveloper.com/design/what-i-astroneer-i-s-devs-learned-while-leaving-early-access) |
| MudRunner mud (lead dev) | [Game Developer](https://www.gamedeveloper.com/programming/mud-and-water-of-spintires-mudrunner) |
| VRAGE / SE voxel | [keenswh.com/vrage](https://www.keenswh.com/vrage/) |
| Godot voxel dig | [Voxel Tools overview](https://voxel-tools.readthedocs.io/en/latest/overview/) |
| Lunar wheel tracks (research) | [arxiv 2408.13468](https://arxiv.org/abs/2408.13468) |
| Powder Toy (OSS reference) | [GitHub](https://github.com/The-Powder-Toy/The-Powder-Toy) |
| Veloren meshing (OSS) | [greedy.rs](https://docs.veloren.net/src/veloren_voxygen/mesh/greedy.rs.html) |

---

## Главный вывод

Большинство «реалистичных» игр **комбинируют cheap truth layer + expensive fake layer**:
- **Truth:** heightfield / SDF / block grid (gameplay, collision, persistence).
- **Fake:** shaders, decals, particles, regression formulas (eye candy, traction).

Для лунного sandbox малой командой оптимум — **не Noita в 3D и не Teardown**, а **Astroneer-style SDF crust + MudRunner-style granular patch + Minecraft-style occasional column collapse**, что уже описано в `docs/specs/GRANULAR-V0.md`. Следующий скачок качества — в **visual tracks/settle** (Tier B), не в full physics simulation.

[REDACTED]
