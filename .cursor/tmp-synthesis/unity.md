# Исследование: жидкости и рыхлая/сыпучая почва в Unity

> **Примечание:** «TerraFlex» как отдельного плагина не найдено — вероятно имелись в виду **TerraForge Pro**, TerraWorld, TerraSplines или generic runtime terrain deformation.

---

## 1. Лучшие подходы Unity для soil/fluid

В Unity нет одного «универсального» решения. Выбор зависит от масштаба, нужна ли **игровая физика** или только **визуал**, и 2D vs 3D.

### A. Рыхлая почва / песок / отвалы (granular / soil)

| Подход | Суть | Когда брать |
|--------|------|-------------|
| **Cellular automata (falling sand)** | Сетка пикселей/клеток, локальные правила (гравитация, текучесть, реакции) | 2D-песочницы, Noita-like, дешёвый массовый «зерно-вид» |
| **Heightfield / thickness map** | Объём как толщина на сетке + релаксация по углу откоса | Отвалы, осыпи, нагрузка колёс — без миллионов частиц |
| **DEM / granular PBD** | Дискретные «шарики» с контактами, shape matching | Гравий, камни, coarse spoil; дорого для fine regolith |
| **Voxel carve + spoil spawn** | Выемка в вокселях, порода уходит в отдельный слой/RigidBody | Шахты, Hydroneer-like (но Hydroneer — UE4, не Unity) |
| **Decoupled CPU physics + GPU visuals** | Физика упрощённая, рендер богатый (Spintires-паттерн) | Грязь/колеи в off-road |

**Практическая рекомендация для lunar/industry sandbox (как Regolith):**
- **Истина объёма** — thickness/heightfield patch (не SPH на каждое зерно).
- **Активные зёрна** — только презентация (VFX / instanced grit).
- **Dig** — voxel/SDF carve → `deposit()` в granular patch.
- Полноценный DEM-SPH coupling — только для локальных VFX (пролив воды в траншею), не для всей планеты.

### B. Жидкости (water, mud flow, вязкие материалы)

| Подход | Суть | Масштаб |
|--------|------|---------|
| **Stable Fluids / GPU Gems grid (2D/3D Eulerian)** | Velocity + pressure на текстурах, advection + projection | Дым, огонь, локальная вода, shallow effects |
| **SPH / PBD fluids (Obi, custom compute)** | Lagrangian частицы, density constraints | Брызги, лужи, сироп, **не** океаны |
| **FLIP (grid + particles)** | Cataclysm-style, PIC/FLIP blend | Реалистичная 3D жидкость в малой зоне |
| **Shallow water / FFT ocean (KWS2 и аналоги)** | Поверхностные волны, не volumetric fluid | Океаны, реки «на вид» |
| **VFX Graph + external compute** | Симуляция в compute, частицы в VFX | Эффекты, слабая связь с gameplay physics |
| **Pre-baked vector fields (MegaFlow)** | Импорт .FXD/.FGA, advect частиц | Ветер, дым, **не** интерактивная жидкость |

### C. Деформируемый terrain / «грязь под колёсами»

| Подход | Примеры |
|--------|---------|
| **Runtime heightmap stamp** | TerraForge Pro (compute stamps), классический TerrainDeformer |
| **Hybrid voxel + Unity Terrain** | Digger PRO — пещеры, runtime dig без full-voxel мира |
| **Full voxel chunk (Marching Cubes)** | Voxel Digging Master |
| **MudRunner-style decoupling** | Отдельные RT-текстуры для visual mud + эмпирическая CPU-traction |

---

## 2. Open source / Asset Store (с ссылками)

### Open source — жидкости

| Проект | URL | Заметки |
|--------|-----|---------|
| **keijiro/StableFluids** | https://github.com/keijiro/StableFluids | Jos Stam Stable Fluids, compute, эталон для 2D |
| **Scrawk GPU-GEMS 2D/3D** | https://github.com/Scrawk/GPU-GEMS-2D-Fluid-Simulation , https://github.com/Scrawk/GPU-GEMS-3D-Fluid-Simulation | GPU Gems port, MIT |
| **Scrawk PBD-Fluid** | https://github.com/Scrawk/PBD-Fluid-in-Unity | ~70K частиц @60 FPS (автор) |
| **Victor2266/The-Fluid-Toy** | https://github.com/Victor2266/The-Fluid-Toy | SPH + marching cubes + screen-space, MIT |
| **Gornhoth/Unity-SPH** | https://github.com/Gornhoth/Unity-Smoothed-Particle-Hydrodynamics | Mono / Compute / ECS сравнение |
| **abecombe/FLIP-Fluid-for-Unity** | https://github.com/abecombe/FLIP-Fluid-for-Unity | FLIP + HDRP + VFX Graph |
| **lamp-cap/Unity_FLIP_Fluid_Simulation** | https://github.com/lamp-cap/Unity_FLIP_Fluid_Simulation | 4M particles, 256³ grid, RTX 4070 |
| **Warriorroq/RealtimeFluidSimulation** | https://github.com/Warriorroq/RealtimeFluidSimulation | URP, модульный pipeline |
| **Deniz-ARAS/GPU-Fluid-Sim** | https://github.com/Deniz-ARAS/GPU-Fluid-Sim | 2D stable fluids, compute |
| **IRCSS/Compute-Shaders-Fluid-Dynamic** | https://github.com/IRCSS/Compute-Shaders-Fluid-Dynamic- | Обучающий pipeline + blog |
| **fluviofx/fluviofx** | https://github.com/fluviofx/fluviofx | Fluid в VFX Graph (early dev, патч VFX) |
| **SID37/air-fluid** | https://github.com/SID37/air-fluid | Interactive fluid для VFX Graph |

### Open source — granular / sand / PBD

| Проект | URL | Заметки |
|--------|-----|---------|
| **qoopen0815/ParticlePhysics** | https://github.com/qoopen0815/ParticlePhysics | Sand-like granular (BeYiMu2005 paper) |
| **JohannHotzel/unified-solver** | https://github.com/JohannHotzel/unified-solver | Unified XPBD: fluid + soft + cloth |
| **JohannHotzel/Molecules** | https://github.com/JohannHotzel/Molecules | GPU XPBD, thousands of particles |
| **andywiecko/PBD2D** | https://github.com/andywiecko/PBD2D | 2D PBD + Burst |
| **lochrist/UniPowder** | https://github.com/lochrist/UniPowder | Powder Toy clone, ECS |
| **etopuz/UniSand** | https://github.com/etopuz/UniSand | 2D sand CA (WIP) |
| **neonmoe/sandcastles** | https://github.com/neonmoe/sandcastles | PROCJAM toy, Unity ECS |

### Asset Store / коммерческие

| Продукт | URL | Назначение |
|---------|-----|------------|
| **Obi Physics Suite** | https://assetstore.unity.com/packages/tools/physics/obi-physics-suite-313315 | Fluid, Rope, Softbody, Granular |
| **Obi Fluid** | https://assetstore.unity.com/packages/tools/physics/obi-fluid-63067 | SPH/PBD fluid, splashes |
| **KWS2 Dynamic Water** | https://assetstore.unity.com/packages/tools/particles-effects/kws2-dynamic-water-system-323662 | Океан, shallow water, foam |
| **MegaFlow** | https://assetstore.unity.com/packages/tools/particles-effects/mega-flow-24340 | Vector fields (не FLIP!) |
| **Digger PRO** | https://assetstore.unity.com/packages/tools/terrain/digger-pro-voxel-terrain-sculpting-149753 | Runtime voxel dig |
| **TerraForge Pro URP** | https://assetstore.unity.com/packages/tools/terrain/terraforge-pro-urp-386220 | GPU snow/mud/sand trail stamps |
| **Voxel Digging Master** | https://assetstore.unity.com/packages/templates/packs/voxel-digging-master-366534 | Marching Cubes mining framework |
| **Falling Sand Template (Kamgam)** | https://assetstore.unity.com/packages/templates/systems/falling-sand-game-template-pixel-simulation-267575 | CA + Jobs/Burst |
| **TerraSplines** | https://assetstore.unity.com/packages/tools/terrain/terrasplines-spline-terrain-editor-343912 | Spline terrain sculpt |

### Документация / статьи / talks

| Ресурс | URL |
|--------|-----|
| **Noita GDC** — «Exploring the Tech and Design of Noita» | https://www.youtube.com/watch?v=prXuyMCgbTc |
| **Ignitement fluid breakdown (Unity blog)** | https://unity.com/blog/real-time-fluid-simulation-fire-vfx-ignitement-breakdown |
| **Spintires mud (Game Developer)** | https://www.gamedeveloper.com/programming/mud-and-water-of-spintires-mudrunner |
| **80.lv Spintires breakdown** | https://80.lv/articles/breakdown-mud-and-water-of-spintires |
| **GPU Gems Ch.38 (Stable Fluids GPU)** | https://developer.nvidia.com/gpugems/gpugems/part-vi-beyond-triangles/chapter-38-fast-fluid-dynamics-simulation-gpu |
| **NVIDIA Cataclysm FLIP** | https://developer.nvidia.com/cataclysm-flip-solver-gpu-particles |
| **MDPI: Large-Scale SPH in Unity** | https://doi.org/10.3390/app15179706 |
| **SPH-DEM soil seepage (research)** | https://raymondmcguire.github.io/seepage_flow/resources/sca2021_preprint.pdf |
| **Sand Game Template manual** | https://kamgam.com/unity/SandGameManual.pdf |
| **Digger runtime docs** | https://github.com/ofux/Digger-Documentation/blob/master/Runtime.md |

### Игры (референсы)

| Игра | Движок | Что изучать |
|------|--------|-------------|
| **Noita** | Custom C++ | CA + Box2D rigid chunks, checkerboard threading |
| **Sandcastle** (TBA) | Unity (Bubblebird) | Moisture/pressure/compaction — детали закрыты | https://sandcastlegame.com/ |
| **Hydroneer** | **UE4 + PhysX** (не Unity!) | Voxel dig + каждый самородок = physics body | https://hydroneer.com/ |
| **Spintires / MudRunner** | VeeEngine + Havok | Decoupled mud: CPU traction + GPU RT deformation |
| **Ignitement** | Unity | 2D stable fluids для gameplay damage |

---

## 3. Характеристики производительности

### Жидкости (ориентиры из публикаций и README)

| Метод | Типичный масштаб @60 FPS | Узкое место |
|-------|--------------------------|-------------|
| **Stable Fluids 2D** (1024²) | ~стоимость 2–3 post-FX | ~60 Graphics.Blit/кадр (Scrawk: «surprisingly» 60 FPS) |
| **Ignitement** | 1024² density + 512² velocity | Blit passes, AsyncGPUReadback для gameplay |
| **Obi Fluid GPU** | Small–medium (тысячи–десятки тысяч) | Particle count, surface meshing |
| **Scrawk PBD Fluid** | ~70K particles | GPU neighbor search |
| **SPH compute (типичный)** | 50K–100K interactive | Spatial hash, memory bandwidth |
| **SPH DOTS/Burst CPU** | 25K–50K @60 FPS (литература) | CPU multithread, меньше частиц чем GPU |
| **MDPI Unity SPH (2025)** | до **1M particles** interactive (GPU + count sort + scan) | Surface reconstruction отдельно |
| **FLIP (lamp-cap, RTX 4070)** | **4M particles**, grid 256×128×128 | High-end GPU only |
| **MegaFlow** | Pre-baked fields, mobile OK | Нет real-time fluid solve |
| **KWS2 ocean** | Large zones | Shallow water + FFT; particles time-sliced @15 Hz sim |

### Granular / soil

| Метод | Масштаб | Узкое место |
|-------|---------|-------------|
| **Falling sand CA (Kamgam)** | 320×180 default; 30 FPS на старых mobile / 60 на новых | Resolution², Jobs/Burst |
| **Noita** | 512×512 chunks × ~12 active; 64×64 checker passes | CPU pixel sim, не ECS per grain |
| **Obi Granular** | Coarse gravel, не fine sand | Particle count, collisions |
| **Hydroneer nuggets** | Каждый nugget = physics → **FPS collapse** при 10K+ в одном контейнере | PhysX contact explosion |
| **Heightfield relax (Regolith-style)** | 100×100 cells @25 cm — дёшево | Угол откоса, не individual grains |
| **Spintires mud** | Active 16×16 m blocks near truck | CPU empirics + GPU RT stamps |

### Terrain deformation

| Метод | Характер |
|-------|----------|
| **Digger PRO async** | Burst/Jobs queue, без freeze если `ModifyAsyncBuffered` |
| **TerraForge stamps** | Compute RT ping-pong, trail blur |
| **Full voxel MC** | Bounded volume, chunk rebuild cost |

**Общий вывод по perf:** в real-time игре **рендер fluid surface** часто дороже, чем сам solver. **Gameplay truth** почти никогда не держат на million-particle SPH — либо grid/thickness, либо decoupled fake.

---

## 4. Что реалистично перенести в Godot (Regolith)

Godot 4.5 + Jolt + Voxel Tools + custom GDScript уже ближе к **Spintires / heightfield / voxel** паттерну, чем к Obi.

### Высокая переносимость (рекомендуется)

| Техника | Godot mapping |
|---------|---------------|
| **Thickness/heightfield granular patch** | Уже в `GRANULAR-V0`: `GranularPatch`, relax, `HeightMapShape3D` |
| **Stable Fluids 2D/3D на compute** | Godot `RenderingDevice` compute shaders — HLSL→GLSL порт, keijiro/Scrawk как референс |
| **Ignitement pattern** | Multi-pass fullscreen / compute + `RD` textures; gameplay readback через async |
| **Spintires mud decoupling** | CPU: traction/sinkage; GPU: shader displacement / splat RT — без Havok-specific API |
| **Dig → spoil deposit** | Voxel carve (`VoxelTool`) → `GranularPatch.deposit()` — уже контракт проекта |
| **Presentation-only grains** | GPUParticles3D / VFX scenes (R4 declarative) |
| **Noita rigid bridge** | Jolt `ConcavePolygonShape` / triangulation из marching squares — для локальных clumps |
| **Cellular automata sand** | `PackedByteArray` + threaded GDScript или compute; Jobs/Burst → WorkerThreadPool |

### Средняя переносимость (нужна инженерия)

| Техника | Сложность в Godot |
|---------|-------------------|
| **SPH/PBD fluids (Obi-like)** | Нет готового аналога; порт compute pipeline (The-Fluid-Toy, unified-solver) |
| **FLIP 3D** | Compute + marching cubes mesh; тяжёлый R&D |
| **VFX Graph integration** | Нет VFX Graph → частицы через custom renderer или GPUParticles |
| **Screen-space fluid** | Есть в Godot через custom shaders (forward+) |
| **MegaFlow vector fields** | Texture3D + particle custom integrator — straightforward |

### Низкая переносимость / не стоит тащить целиком

| Техника | Почему |
|---------|--------|
| **Obi asset as-is** | Проприетарный, Unity-specific rendering passes |
| **Unity Terrain + Digger hybrid** | Godot terrain другой; лучше Voxel Tools |
| **DOTS/ECS/Burst** | Нет Burst; эквивалент — compute GPU или C++ GDExtension |
| **Hydroneer per-nugget PhysX** | Антипаттерн для Godot/Jolt at scale |
| **Full DEM-SPH soil research** | Overkill для lunar sandbox; только cinematic |

### Стратегия для Regolith (из контекста `GRANULAR-V0`)

```
Voxel SDF (скала) → carve → GranularPatch (истина объёма)
                              ↓
                    HeightMapShape3D + settle_load
                              ↓
                    VFX grit (не влияет на физику)
```

Это **ближе к Spintires + industry heightfield**, чем к Obi Fluid. Для **локальной воды/шлама** — отдельный compute SPH bubble, не глобальный сим.

---

## 5. Standout-техники, которые стоит изучить

### 1. Noita: два мира физики + мост
- Pixel CA — **не ECS per grain** (слишком медленно).
- Rigid chunks: **Marching Squares → Douglas-Peucker → triangulation → Box2D**.
- Parallel update: **checkerboard 64×64 crosses**, 4 passes — без race conditions.
- **GDC talk обязателен:** https://www.youtube.com/watch?v=prXuyMCgbTc

### 2. Spintires/MudRunner: разделение truth/render
- CPU: penetration depth → traction (эмпирика, не Navier-Stokes).
- GPU: multi-channel RT (height, mud mask, track blend, offset slide).
- Active blocks 16×16 m — **LOD по симуляции**, не только по мешу.
- Статья: https://www.gamedeveloper.com/programming/mud-and-water-of-spintires-mudrunner

### 3. Ignitement: fluid как gameplay collider
- 2D stable fluids дешевле particles.
- `AsyncGPUReadback` → CPU threshold → damage zones.
- Урок: **sim resolution << screen resolution** достаточно для gameplay.

### 4. GPU Gems / Stable Fluids pipeline
- Helmholtz-Hodge decomposition, Jacobi pressure, vorticity confinement.
- keijiro/StableFluids — минимальный читаемый референс для Godot port.

### 5. FLIP (Cataclysm lineage)
- PIC/FLIP blend, MAC grid, density projection для volume conservation.
- abecombe + lamp-cap — modern Unity implementations.
- Полезно для **локального пролива воды**, не для regolith bulk.

### 6. Unified XPBD (Macklin)
- Один solver для fluid + soft + granular constraints.
- JohannHotzel/unified-solver — архитектурный референс «single kernel pipeline».

### 7. SPH-DEM coupling (research)
- Darcy seepage, capillary bridges, moisture saturation → визуально «настоящая» почва.
- Для Sandcastle-like wet sand — если когда-нибудь нужен moisture model поверх thickness map.

### 8. Hydroneer как антипаттерн
- Voxel dig OK; **каждый самородок = RigidBody** → exponential FPS death.
- Урок: aggregate state (crucible holds «liquid gold») vs simulate every grain.

### 9. VFX Graph bridge pattern
- External compute → RenderTexture → VFX sample (FluvioFX/AirFluid).
- В Godot: compute → texture → particle shader sample.

### 10. Heightfield relax vs particle DEM (Regolith already chose correctly)
- Угол repose + volume conservation на grid — **O(cells × iterations)**, deterministic, coop-safe.
- Particle soil — nondeterministic, expensive, hard to sync multiplayer.

---

## Сводная матрица «что для чего»

| Задача Regolith-like | Unity best bet | Godot path |
|---------------------|----------------|------------|
| Отвал / осыпь / угол repose | Heightfield / Kamgam CA (2D ref) | **GranularPatch** ✓ |
| Бур → spoil | Voxel + particle spawn | carve + deposit ✓ |
| Колёса в рыхлом | Spintires-style settle | settle_load + Jolt ✓ |
| Локальная вода/шлам | Obi / The-Fluid-Toy SPH | Compute SPH module |
| Океан / база | KWS2 | Отдельная water spec, не granular |
| Пещеры | Digger PRO | Voxel Tools ✓ |
| Fine sand castle physics | Sandcastle (closed) / research SPH-DEM | Moisture layer on thickness map (future) |

---

**Итог:** Unity-экосистема богата **GPU fluid** (Stable Fluids, SPH, FLIP, Obi) и **2D sand CA** (Noita lineage), но для **open-world lunar soil** industry-паттерн — **не million particles**, а **voxel dig + heightfield/thickness granular + decoupled VFX**. Это совпадает с текущим контрактом Regolith (`GRANULAR-V0`) и переносимо из Spintires/MudRunner + compute fluid modules, а не из целого Obi/Hydroneer stack.

[REDACTED]
