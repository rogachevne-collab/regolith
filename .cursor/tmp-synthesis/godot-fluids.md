# Симуляция жидкостей в Godot 4.x: исследовательский отчёт

## 1. Что возможно в Godot сегодня

**Краткий вывод:** в Godot 4.x **нет встроенной симуляции жидкостей** (ни SPH/PBF, ни Navier–Stokes в ядре). Proposal [#2094](https://github.com/godotengine/godot-proposals/issues/2094) открыт с 2021 года; maintainer’ы считают это territory сторонних addon’ов, не core. Встроенные инструменты дают **половину инфраструктуры** (GPU-частицы, SDF-коллизии, compute shaders), но не физику жидкости.

| Категория | Что есть из коробки | Чего нет |
|---|---|---|
| **Частицы** | `GPUParticles3D/2D`, `CPUParticles3D/2D`, custom `shader_type particles` с `render_mode keep_data` | SPH/PBF solver, давление, вязкость, surface tension |
| **Коллизии частиц** | `GPUParticlesCollisionSDF3D`, `HeightField3D`, box/sphere — **только для GPUParticles**, статичные SDF | Связь с `PhysicsServer3D`/Jolt; runtime-rebake SDF |
| **Compute** | `RenderingDevice` + GLSL compute (Forward+/Mobile) | Готовый FluidNode |
| **PhysicsServer** | Rigid/Character/Soft bodies, joints | Fluid body, pressure field, two-phase flow |
| **SoftBody3D** | Ткань/резина (Jolt быстрее GodotPhysics) | Жидкость; `pressure_coefficient` — «мешок с воздухом», не вода |

**Экосистема:** зрелые решения — community addon’ы (GPU SPH, Rapier+Salva, droplet+RigidBody+Jolt), шейдерные «воды» (Gerstner, FFT ocean, heightfield ripples), 2D Navier–Stokes на CPU/GPU.

---

## 2. Техники: плюсы и минусы

### 2.1 Встроенные частицы (GPUParticles / CPUParticles)

**Суть:** визуальные брызги/струи через `ParticleProcessMaterial` или custom particle shader.

| Плюсы | Минусы |
|---|---|
| Нативно, документировано | Не жидкость: нет сохранения объёма, нет meniscus |
| `keep_data` + custom shader — state между кадрами | GPUParticles **не видят** Jolt-коллизии |
| SDF collision для GPUParticles (bake в редакторе) | SDF **статичен**, не следует за voxel carve |

- Документация: [Particle shaders](https://docs.godotengine.org/en/4.4/tutorials/shaders/shader_reference/particle_shader.html), [Particle collision](https://docs.godotengine.org/en/stable/tutorials/3d/particles/collision.html)
- Tutorial: [Godot 4: Particle shader in 3D](https://www.youtube.com/watch?v=Fmc11en7baU)

**CPU vs GPU:** `CPUParticles` — motion на CPU, render на GPU; тысячи частиц max. `GPUParticles` — десятки тысяч для VFX, но без fluid solver.

---

### 2.2 Droplet simulation (RigidBody + cohesive forces + Jolt)

**Суть:** каждая «капля» — `RigidBody3D`; сервер притягивает соседей → иллюзия surface tension.

| Плюсы | Минусы |
|---|---|
| Работает с **Jolt** out of the box | ~2000–3200 droplet’ов (benchmark автора) |
| Двусторонняя связь с rigid bodies | O(n²) или spatial hash вручную |
| Простая интеграция в gameplay | Не масштабируется до «реки»/«озера» |

Проекты:
- [thompsop1sou/godot-fluid-sim](https://github.com/thompsop1sou/godot-fluid-sim) (~1000–3200 droplets с Jolt)
- [thompsop1sou/freezable-fluid-sim](https://github.com/thompsop1sou/freezable-fluid-sim) — заморозка/таяние
- Форк: [ramblingstranger/godot-fluid-sim](https://github.com/ramblingstranger/godot-fluid-sim)

**Для Regolith:** годится для **демо-уровня** (пролив кислорода, капли воды из регенератора), не для regolith flow.

---

### 2.3 GPU SPH / PBF (compute shaders, RenderingDevice)

**Суть:** Smoothed Particle Hydrodynamics на GPU — density, pressure, viscosity, spatial hashing.

| Плюсы | Минусы |
|---|---|
| **32k+** частиц на mid-range GPU | Требует Forward+ / Vulkan |
| SDF collision (texture 3D) | SDF bake **статичен** — проблема с voxel terrain |
| MultiMesh / ray-march rendering | **Не интегрирован** с Jolt PhysicsServer |
| MIT addon’ы появляются | Молодая экосистема, мало battle-tested проектов |

Проекты:
- [deni10000/Godot-3D-SPH-Fluid-Simulation](https://github.com/deni10000/Godot-3D-SPH-Fluid-Simulation) + [Asset Library](https://godotengine.org/asset-library/asset/5116) (32k+ particles, MIT)
- [sebastianregelmann/realtime-fluid-sim](https://github.com/sebastianregelmann/realtime-fluid-sim) — Godot 4.5 Mono, density texture + ray-march refraction
- [aklos/godot-flip-water-simulation](https://github.com/aklos/godot-flip-water-simulation) — FLIP (C++ GDExtension, WIP)
- [3c0tr/LitWithParticles](https://github.com/3c0tr/LitWithParticles) — Navier–Stokes + lighting, Godot 4.4

**CPU reference:** Obi Fluid (Unity, C++ multithreaded) ≈ **6000** particles; GPU compute ≈ **60k** на старом FirePro, **100k+** на RTX 3060 ([proposal #2094](https://github.com/godotengine/godot-proposals/issues/2094)). GPU vs CPU SPH — порядка **10–30×** ([WeldForm benchmark](https://www.youtube.com/watch?v=pMO-51zlaBs)).

**CPU Godot demos (legacy):**
- [SIsilicon/SPHater-Godot-Demo](https://github.com/SIsilicon/SPHater-Godot-Demo) — Godot 3, pure GDScript SPH
- [Chaosus/GodotFluidCPU](https://github.com/Chaosus/GodotFluidCPU) — 2D GDExtension C++, last push 2023

---

### 2.4 Rapier + Salva (единственный «настоящий» fluid в PhysicsServer-подобном API)

**Суть:** [godot-rapier-physics](https://github.com/appsinacup/godot-rapier-physics) = Rapier (rigid) + [Salva](https://github.com/dimforge/salva) (SPH fluids). Узлы `Fluid2D`/`Fluid3D`, two-way coupling с rigid bodies.

| Плюсы | Минусы |
|---|---|
| Настоящая fluid physics + rigid coupling | **Заменяет** physics engine → **конфликт с Jolt** |
| 2D зрелее 3D ([форум 2025](https://forum.godotengine.org/t/is-liquid-simulation-possible-in-godot/122167)) | Salva **не имеет** Jolt backend ([issue #334](https://github.com/appsinacup/godot-rapier-physics/issues/334)) |
| DFSPH, multiphase, viscosity models | Два physics engine одновременно — нереалистично |
| Документация: [godot.rapier.rs/fluids](https://godot.rapier.rs/docs/documentation/fluids/) | 3D Fluid3D — баги с количеством points (community reports) |

**Вывод для Regolith:** Rapier+Salva **не совместим** с выбором Jolt + granular architecture. Только если отдельная сцена/мини-игра без Jolt.

---

### 2.5 Grid Navier–Stokes (2D, heightfield / texture)

**Суть:** velocity + density fields на сетке; pressure projection (Gauss–Seidel / Jacobi). Классика Stam 1999.

| Плюсы | Минусы |
|---|---|
| Красивый 2D «аквариум» / side-view | **2D**, не 3D volume |
| CPU реализация понятна | CPU медленный на больших grid |
| GPU: 23–46+ compute passes | Сложная sync/barrier логика |
| Хорош для UI/VFX/2D games | Не coupling с 3D Jolt |

Ресурсы:
- Блог + код: [Navier-Stokes explained with Godot](https://myzopotamia.dev/navier-stokes-fluid-simulation-explained-with-godot) → [rskupnik/godot-fluid-simulation-demo](https://github.com/rskupnik/godot-fluid-simulation-demo)
- [Maaack/2D-Fluid-Simulation](https://github.com/Maaack/2D-Fluid-Simulation) — Godot 3, GPU multi-pass
- Forum: [alternating compute passes for NS](https://forum.godotengine.org/t/run-alternating-compute-shader-passes/130872)

---

### 2.6 Heightfield / shader water (не fluid simulation)

**Суть:** анимированная поверхность без сохранения объёма — Gerstner waves, noise displacement, depth-based coloring.

| Плюсы | Минусы |
|---|---|
| Дёшево, красиво | Нет переливания, нет slosh в контейнере |
| Buoyancy через shared wave math | Объекты «плавают на шейдере», не на fluid |
| Infinite ocean tricks | Не подходит для лунного regolith |

Проекты:
- [Chrisknyfe/boujie_water_shader](https://github.com/Chrisknyfe/boujie_water_shader) — Gerstner + infinite ocean
- [Flarkk/Godot-Water-Shader-Prototype](https://github.com/Flarkk/Godot-Water-Shader-Prototype) — Gerstner + fluid-simulated details
- [godotshaders.com — Water shader 3D](https://godotshaders.com/shader/water-shader-3d-godot-4-3/)
- Tutorial: [How To Create A Water Shader](https://www.youtube.com/watch?v=7L6ZUYj1hs8)
- Buoyancy: [Gerstner Waves + Buoyancy](https://www.seacreaturegame.com/blog/gerstner-waves-with-buoyancy-godot)

**Interactive ripples (heightfield simulation, не Newtonian fluid):**
- Official: [compute/texture demo](https://github.com/godotengine/godot-demo-projects/tree/master/compute/texture) — wave equation на GPU
- [Kextex IWS](https://kextex.itch.io/interactive-water-in-godot-4) — compute + voxel buoyancy, pools/lakes
- [JorisAR/GDWaterKart](https://github.com/JorisAR/GDWaterKart) — FFT waves + ripples + explosions (Mario Kart style)

---

### 2.7 FFT Ocean (Tessendorf)

**Суть:** спектральные ocean waves через FFT compute; CDLOD mesh.

| Плюсы | Минусы |
|---|---|
| Кинematographic ocean | **Не fluid** — open boundary, no volume |
| GPU FFT, buoyancy hooks | Godot 4.3+, compute-heavy |
| CDLOD без popping | Бессмысленно на луне (нет океанов) |

- [tessarakkt/godot4-oceanfft](https://github.com/tessarakkt/godot4-oceanfft) (~538★)
- Basis: [achalpandeyy/OceanFFT](https://github.com/achalpandeyy/OceanFFT)

---

### 2.8 Metaballs / ray marching

**Суть:** smooth union SDF сфер → «каплеобразная» поверхность; часто поверх SPH density field.

| Плюсы | Минусы |
|---|---|
| Красивый cohesive look | Дорого (64+ ray steps) |
| Работает без mesh topology | Нужен density field (SPH output) |
| Godot shader примеры | Сложно с PBR + shadows + MSAA |

- [godotshaders.com — Metaballs](https://godotshaders.com/shader/metaballs/)
- Ray marching tutorials: [D5Rg3cbOQ9c](https://www.youtube.com/watch?v=D5Rg3cbOQ9c), [68G3V5Yr8FY](https://www.youtube.com/watch?v=68G3V5Yr8FY)
- [sebastianregelmann/realtime-fluid-sim](https://github.com/sebastianregelmann/realtime-fluid-sim) — density texture + volume ray march

Proposal #2094: reduz предпочёл **отдельный FluidNode**, не расширение particles; metaballs + particles — community consensus для rendering layer.

---

### 2.9 SoftBody3D + pressure (ложный след)

`SoftBody3D` с `pressure_coefficient > 0` — «надутый мешок», не жидкость. Jolt soft bodies **лучше** GodotPhysics ([docs](https://docs.godotengine.org/en/stable/classes/class_softbody3d.html)), но это cloth/rubber domain.

---

### 2.10 PhysicsServer: ограничения для fluids

| Ограничение | Детали |
|---|---|
| **Нет fluid API** | `PhysicsServer3D` — rigid, soft, areas, joints only |
| **GPUParticles изолированы** | Свой collision pipeline; не видят Jolt bodies |
| **SDF collision static** | `GPUParticlesCollisionSDF3D` bake в editor; voxel carve runtime — mismatch |
| **HeightField collision** | `HeightMapShape3D` — **статичен**; Regolith granular уже использует это правильно |
| **SoftBody ≠ fluid** | Pressure — volume constraint mesh, не incompressible flow |
| **No physics interpolation for soft bodies** | Нужен higher tick rate |
| **Dual physics engines** | Rapier fluids + Jolt rigid — architecturally broken |

Документация Jolt: [Using Jolt Physics](https://docs.godotengine.org/en/latest/tutorials/physics/using_jolt_physics.html) — rigid/character/soft, **без fluids**.

Compute shaders: [official tutorial](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html) — TDR risk, `sync()` stalls CPU, prefer `Texture2DRD` без readback.

---

## 3. Ресурсы (ссылки)

### Официальная документация Godot
- [Compute shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html)
- [Particle shaders](https://docs.godotengine.org/en/4.4/tutorials/shaders/shader_reference/particle_shader.html)
- [3D particle collision (SDF/HeightField)](https://docs.godotengine.org/en/stable/tutorials/3d/particles/collision.html)
- [GPUParticlesCollisionSDF3D](https://docs.godotengine.org/en/stable/classes/class_gpuparticlescollisionsdf3d.html)
- [SoftBody3D + Jolt recommendation](https://docs.godotengine.org/en/stable/classes/class_softbody3d.html)
- [Using Jolt Physics](https://docs.godotengine.org/en/latest/tutorials/physics/using_jolt_physics.html)
- [Compute texture demo (ripples)](https://github.com/godotengine/godot-demo-projects/tree/master/compute/texture)

### Proposals / community
- [Add real-time fluid simulation #2094](https://github.com/godotengine/godot-proposals/issues/2094)
- [Forum: Is liquid simulation possible?](https://forum.godotengine.org/t/is-liquid-simulation-possible-in-godot/122167)
- [Forum: compute passes for Navier-Stokes](https://forum.godotengine.org/t/run-alternating-compute-shader-passes/130872)

### GPU SPH / 3D fluid
- [deni10000/Godot-3D-SPH-Fluid-Simulation](https://github.com/deni10000/Godot-3D-SPH-Fluid-Simulation)
- [sebastianregelmann/realtime-fluid-sim](https://github.com/sebastianregelmann/realtime-fluid-sim)
- [aklos/godot-flip-water-simulation](https://github.com/aklos/godot-flip-water-simulation)
- [3c0tr/LitWithParticles](https://github.com/3c0tr/LitWithParticles)

### Jolt-compatible droplet fluid
- [thompsop1sou/godot-fluid-sim](https://github.com/thompsop1sou/godot-fluid-sim)
- [thompsop1sou/freezable-fluid-sim](https://github.com/thompsop1sou/freezable-fluid-sim)

### Rapier + Salva fluids
- [appsinacup/godot-rapier-physics](https://github.com/appsinacup/godot-rapier-physics)
- [Salva library](https://github.com/dimforge/salva)
- [Fluids docs](https://godot.rapier.rs/docs/documentation/fluids/)

### 2D Navier–Stokes / CPU fluid
- [myzopotamia.dev tutorial](https://myzopotamia.dev/navier-stokes-fluid-simulation-explained-with-godot)
- [rskupnik/godot-fluid-simulation-demo](https://github.com/rskupnik/godot-fluid-simulation-demo)
- [Chaosus/GodotFluidCPU](https://github.com/Chaosus/GodotFluidCPU)
- [MauroPle/godot-v4-fluid-water-2D-simulator](https://github.com/MauroPle/godot-v4-fluid-water-2D-simulator)

### Water shaders / ocean (visual)
- [tessarakkt/godot4-oceanfft](https://github.com/tessarakkt/godot4-oceanfft)
- [JorisAR/GDWaterKart](https://github.com/JorisAR/GDWaterKart)
- [Chrisknyfe/boujie_water_shader](https://github.com/Chrisknyfe/boujie_water_shader)
- [Flarkk/Godot-Water-Shader-Prototype](https://github.com/Flarkk/Godot-Water-Shader-Prototype)
- [Kextex IWS (itch.io)](https://kextex.itch.io/interactive-water-in-godot-4)
- [ueshita/godot-floatable-body](https://github.com/ueshita/godot-floatable-body) — pseudo-buoyancy в Area3D

### Metaballs / ray marching
- [godotshaders.com/metaballs](https://godotshaders.com/shader/metaballs/)

### Tutorials / talks (не GDC Godot-specific, но релевантны)
- [Godot Fluid Simulation Shader (YouTube)](https://www.youtube.com/watch?v=M90uh9AF_6Y) — viewport-based 2D fluid
- [GDC: Go With the Flow (Fluid)](https://www.gdcvault.com/play/1012447/Go-With-the-Flow-Fluid) — industry reference
- [Stam: Real-Time Fluid Dynamics for Games (PDF)](http://graphics.cs.cmu.edu/nsp/course/15-464/Spring11/papers/StamFluidforGames.pdf)
- [PixelJunk Shooter optimization (Gamasutra)](https://www.gamasutra.com/blogs/RobWare/20151026/257309/Optimising_PixelJunk_Shooter_and_giving_it_the_Ultimate_look.php)

### Legacy
- [SIsilicon/SPHater-Godot-Demo](https://github.com/SIsilicon/SPHater-Godot-Demo) — Godot 3 CPU SPH
- [Dynamic Water Web Demo (GLES2)](https://john-wigg.dev/DynamicWaterDemo/)

---

## 4. Realistic quality ceiling для lunar sandbox

**Лунный regolith — не Newtonian fluid.** Это сыпучий/granular материал с angle of repose (~33°), усадкой под нагрузкой, edge spill. Regolith уже моделируется через `GranularPatch` (heightfield thickness map), не SDF и не SPH — и это **физически корректнее**, чем любой fluid solver из экосистемы Godot.

| Сценарий | Реалистичный потолок качества | Метод |
|---|---|---|
| **Отвал, осыпь, просыпь** | Хорошо (PoC уже есть) | Granular heightfield + VFX grains |
| **Мелкая «струя» пыли** | Хорошо | GPUParticles + dust shader |
| **Локальный пролив воды/пропеллента** | Средне: сотни–тысячи «капель», stylized | Droplet+Jolt или GPU SPH в bounded box |
| **Slosh в баллоне/баке** | Средне–низко | SPH в малом volume; SDF rebake проблема |
| **Озеро/река на луне** | N/A (нет открытых водоёмов) | — |
| **Полноценная coupling с rover/Jolt** | Низко без custom work | Fluid solver ≠ PhysicsServer |

**Жёсткие ограничения sandbox-масштаба:**
1. **Planetoid 1 km** — локальные эффекты only; глобальной fluid sim нет.
2. **Voxel terrain streaming** — SDF для SPH статичен; dynamic collision с carve — unsolved out of box.
3. **Jolt как единственный 3D physics** — fluid solvers живут **parallel universe** (GPU или отдельный engine).
4. **Performance budget** — GPU SPH 32k particles ≈ dedicated effect; granular + voxel + Jolt уже нагружают CPU/GPU.
5. **Low gravity (1.62 m/s²)** — SPH tuning (surface tension, cohesion) нужен custom; generic water presets не подходят.

**Quality ceiling в одной фразе:** cinematic локальные эффекты (налить воду в чашку, брызги при утечке) — **да**; physically-correct large-scale fluid gameplay на лунной поверхности — **нет** в Godot без major custom R&D.

---

## 5. Рекомендации для Regolith (Godot 4.5+, Jolt, voxel terrain)

### 5.1 Не смешивать домены

| Домен | Правильная модель в Regolith | Не делать |
|---|---|---|
| **Regolith / spoil / отвал** | `GranularPatch` heightfield ([GRANULAR-V0](docs/specs/GRANULAR-V0.md)) | SPH, Navier–Stokes, Rapier fluids |
| **Fluid/gas/thermal Flow** (future, [INDUSTRY-V1](docs/specs/INDUSTRY-V1.md)) | Bulk simulation / graph nodes, не per-pixel 3D NS | Полноценный 3D fluid engine в core loop |
| **VFX dust stream** | Declarative VFX (`granular_stream_vfx.tscn`) | GPUParticles как истина объёма |

Regolith flow **уже решён правильнее**, чем любой Godot fluid addon.

### 5.2 Если понадобится жидкость (вода из льда, O₂/H₂ leak)

**Tier 1 — gameplay truth (рекомендуется):**
- Bulk resource graph: pressure, flow rate, leak events — без particle sim.
- Визуал: GPUParticles burst + decal/puddle shader (static mesh on surface).
- Coupling с Jolt: trigger zones, force impulses, не per-particle.

**Tier 2 — localized «жидкий» момент (cutscene / demo):**
- **Droplet + Jolt** ([godot-fluid-sim](https://github.com/thompsop1sou/godot-fluid-sim)) — если <3000 bodies, нужна Jolt coupling.
- Или **GPU SPH in box** ([deni10000 SPH](https://github.com/deni10000/Godot-3D-SPH-Fluid-Simulation)) — bounded volume, pre-baked SDF контейнера; **не** с dynamic voxel.

**Tier 3 — не рекомендуется для Regolith:**
- Переключение на Rapier+Salva — ломает Jolt + granular + project invariants (R6: только Voxel Tools как GDExtension dep).
- Full ocean/FFT — irrelevant на луне.

### 5.3 Jolt integration strategy

```
┌─────────────────────────────────────────┐
│  Jolt PhysicsServer (rigid, character,  │
│  soft body, granular HeightMapShape)    │
└─────────────────┬───────────────────────┘
                  │ forces / triggers
┌─────────────────▼───────────────────────┐
│  Optional: GPU SPH zone (RenderingDevice)│
│  — isolated, no PhysicsServer RID       │
│  — visual + approximate reaction forces │
└─────────────────────────────────────────┘
```

- **Не пытаться** прокинуть SPH particles в `PhysicsServer3D`.
- Reaction forces: sample GPU density at probe points → apply `apply_central_force` на `RigidBody3D` (как buoyancy probes в Gerstner tutorials).
- Для leak VFX: event-driven, не continuous sim.

### 5.4 Voxel terrain compatibility

| Technique | Voxel carve runtime | Verdict |
|---|---|---|
| Granular heightfield | ✅ patch-local, уже работает | **Keep** |
| GPUParticlesCollisionSDF3D | ❌ static bake | Только prefab-контейнеры |
| GPU SPH + SDF | ❌ static | Re-bake impractical per dig |
| Droplet + Jolt mesh collider | ⚠️ static trimesh ok; voxel collider expensive | Small volumes only |

При dig/carve меняется **скала (SDF)**, не fluid container — granular patch deposit/spill уже покрывает «куда делся материал».

### 5.5 Performance guidance (CPU vs GPU)

| Approach | Particles/cells | CPU load | GPU load | Jolt sync |
|---|---|---|---|---|
| Granular patch relax | 100×100 cells | Low–medium | Low (heightfield mesh) | ✅ HeightMapShape |
| Droplet Jolt | ~2k | High (O(n²) or hash) | Low | ✅ native |
| CPU SPH GDScript | ~500–2k | Very high | Low | ❌ |
| GPU SPH compute | 32k–100k | Low (if no readback) | High | ❌ manual probes |
| Gerstner water shader | N/A (vertices) | Low | Medium | ⚠️ fake buoyancy |
| Navier–Stokes 2D grid | 256² | Medium | Medium–high | ❌ |

**Правило:** держать sim data на GPU (`Texture2DRD`); `rd.sync()` каждый кадр — убийца FPS.

### 5.6 Concrete next steps (если fluid scope откроется)

1. **Спека first (R1):** отдельный PoC в `docs/specs/` — «Fluid Flow v0» как bulk graph, не SPH.
2. **Pilot:** official [compute/texture](https://github.com/godotengine/godot-demo-projects/tree/master/compute/texture) ripples для **puddle decal** на статичной плоскости.
3. **Evaluate:** fork `deni10000` SPH в isolated test scene; benchmark с voxel scene loaded; measure TDR/frame time.
4. **Do not:** migrate physics to Rapier; не conflate granular spoil с liquid sim.

---

## Приложение: открытые Godot-проекты с «fluid» (реальные имена)

| Проект | Тип | URL |
|---|---|---|
| **GDWaterKart** | FFT ocean + interactive ripples + buoyancy | [github.com/JorisAR/GDWaterKart](https://github.com/JorisAR/GDWaterKart) |
| **godot4-oceanfft** | Tessendorf FFT ocean | [github.com/tessarakkt/godot4-oceanfft](https://github.com/tessarakkt/godot4-oceanfft) |
| **Interactive Water (Kextex/IWS)** | Compute pools, voxel buoyancy | [kextex.itch.io](https://kextex.itch.io/interactive-water-in-godot-4) |
| **3D SPH (deni10000)** | GPU SPH addon | [github.com/deni10000/Godot-3D-SPH-Fluid-Simulation](https://github.com/deni10000/Godot-3D-SPH-Fluid-Simulation) |
| **realtime-fluid-sim** | SPH + ray-march volume | [github.com/sebastianregelmann/realtime-fluid-sim](https://github.com/sebastianregelmann/realtime-fluid-sim) |
| **godot-fluid-sim** | Droplet + Jolt cohesion | [github.com/thompsop1sou/godot-fluid-sim](https://github.com/thompsop1sou/godot-fluid-sim) |
| **godot-rapier-physics** | Salva 2D/3D fluids | [github.com/appsinacup/godot-rapier-physics](https://github.com/appsinacup/godot-rapier-physics) |
| **LitWithParticles** | NS fluid + photon lighting | [github.com/3c0tr/LitWithParticles](https://github.com/3c0tr/LitWithParticles) |
| **boujie_water_shader** | Gerstner infinite ocean | [github.com/Chrisknyfe/boujie_water_shader](https://github.com/Chrisknyfe/boujie_water_shader) |
| **floatable-body** | Area-based pseudo-fluid buoyancy | [github.com/ueshita/godot-floatable-body](https://github.com/ueshita/godot-floatable-body) |
| **2D Fluid Sim (Maaack)** | GPU NS multi-pass | [github.com/Maaack/2D-Fluid-Simulation](https://github.com/Maaack/2D-Fluid-Simulation) |
| **Navier-Stokes demo (rskupnik)** | CPU NS tutorial code | [github.com/rskupnik/godot-fluid-simulation-demo](https://github.com/rskupnik/godot-fluid-simulation-demo) |

**GDC-style Godot-specific talks:** dedicated GDC session по Godot fluids **не найдена**. Ближайшее: community YouTube ([Fluid Simulation Shader](https://www.youtube.com/watch?v=M90uh9AF_6Y), [GPU Cloth Progress](https://www.youtube.com/watch?v=Jhk88li-btI)), industry reference [GDC Go With the Flow](https://www.gdcvault.com/play/1012447/Go-With-the-Flow-Fluid).

---

**Bottom line для Regolith:** Godot 4.x не даёт turnkey fluid physics с Jolt. Для лунного песка granular heightfield — правильный и уже реализованный путь. Newtonian fluid — niche addon (GPU SPH или droplet demo), только для life-support/industry сценариев, изолированно от voxel truth layer.

[REDACTED]
