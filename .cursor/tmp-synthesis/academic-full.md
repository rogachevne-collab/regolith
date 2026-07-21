# Исследование методов симуляции сыпучих материалов и жидкостей для игр

> Контекст Regolith: проект уже использует **heightfield/thickness map** (`GranularPatch`) — не DEM/MPM. Это осознанный выбор для real-time на планетоиде; ниже — альтернативы и исследовательский контекст.

---

## 1. Сравнительная таблица методов

| Критерий | **DEM** (Discrete Element Method) | **SPH** (Smoothed Particle Hydrodynamics) | **MPM** (Material Point Method) | **Heightfield / thickness map** |
|---|---|---|---|---|
| **Что моделирует** | Отдельные зёрна/кластеры с контактами | Жидкости как сглаженные частицы | Единый континуум: песок, снег, вода, твёрдое | 2D поле высоты/толщины на сетке |
| **Масштаб** | Микро: каждое зёрно | Мезо: «blob» жидкости | Макро-континуум с историей деформации | Макро: поверхность слоя |
| **Физика** | Hertz/Coulomb контакты, угол откоса из трения | Уравнения Навье–Стокса, сжимаемость | Drucker-Prager, Hencky strain, elastoplasticity | Гравитационный перенос, angle of repose, shallow water |
| **Контакт с телами** | Нативный (силы на каждое зёрно) | Сложный (границы, ghost particles) | Хороший (через grid + CPIC) | Через heightmap collider / load |
| **Объём/масса** | Точный (если зёрна не теряются) | Приближённый (сжимаемость) | Сохраняется (континуум) | Точный на клетку (thickness × area) |
| **Память** | O(N зёрен), очень дорого | O(N частиц) | O(N частиц + grid) | O(cells) — минимум |
| **Real-time (consumer GPU)** | ~10⁴–10⁵ зёрен (PBD/Flex); 10⁶+ offline | ~10⁴–10⁵ (PBF/Flex); offline — миллионы | ~10⁴–10⁵ (55K @ 60fps, 4×V100); consumer ~10³–10⁴ | **10⁵–10⁶+ клеток** легко |
| **Offline VFX** | Миллионы зёрен (Chrono DEM-Engine: 150M на 2×A100) | Миллионы (Houdini, custom) | 10–100M частиц (<1 мин/кадр, GPU) | Пре-расчёт + bake |
| **Типичное применение в играх** | Локальные кучи, Flex granular | Вода (PBF, не чистый SPH) | Пока почти только R&D / VFX | Terrain, отвалы, снег, вода (shallow) |
| **Главный плюс** | Физическая точность, инженерная валидация | Красивые жидкости, брызги | Sand+fluid+solid в одном солвере | Скорость, детерминизм, масштаб |
| **Главный минус** | O(N²) контакты, малый dt | «Прыгучесть», дорогая несжимаемость | Дорогой grid transfer, offline bias | Нет 3D flow, нет отдельных зёрен |

**Гибриды (часто лучший компромисс для игр):**
- **DEM + heightfield** (Zhu & Yang 2010, BCRE): активные частицы на поверхности, статика — в heightfield (8–30% частиц vs чистый DEM).
- **PBD LR + HR upsampling** (WSCG 2022): физика на малом числе частиц, визуал — миллионы «декоративных».
- **Heightfield sand+water** (SIGGRAPH Asia 2023): shallow water + elastoplastic sand на GPU в real-time.

---

## 2. Какие методы в каких играх

| Игра / продукт | Метод | Детали |
|---|---|---|
| **Noita** (Nolla Games) | **Cellular automata** (falling sand) | Не DEM/MPM. 64×64 chunks, dirty rects, checkerboard multithreading. [GDC 2019](https://www.youtube.com/watch?v=prXuyMCgbTc) |
| **Powder Game / The Powder Toy** | CA falling sand | Классика жанра, rule-based pixels |
| **No Man's Sky** | **Voxel SDF** | Деформация terrain = изменение density, не granular flow. [GDC 2017](https://www.gamedeveloper.com/programming/video-how-continuous-world-generation-works-in-i-no-man-s-sky-i-) |
| **Planet Coaster 2** | **Shallow water equations** (2D heightfield) | Не SPH: ripples, flow, foam на поверхности бассейнов. [Game Developer deep dive](https://www.gamedeveloper.com/programming/deep-dive-crafting-detailed-and-dynamic-water-in-planet-coaster-2) |
| **Journey / Flower** | Shader + particles | Визуальный песок, не физическая симуляция зёрен |
| **Dreams** (Media Molecule) | BubbleBath splats | Нет granular physics; CSG + impressionistic rendering |
| **Teardown** | Voxel destruction | Разрушаемые воксели, не сыпучесть |
| **Astro Bot, Astro's Playroom** | Particles + baked | Декоративные эффекты |
| **Flex demos / UE4 Flex** | **PBF + PBD granular** | Macklin et al.; до ~1.3M particles, потом нестабильность. Deprecated |
| **uFlex (Unity)** | FleX PBF/PBD | Fluids + granular + cloth в одном контейнере |
| **WorldBox, Sand:box** | CA / simple particles | Rule-based |
| **Space Engineers** | Voxel + simple physics | Нет regolith flow |
| **Kerbal Space Program** | Heightmap terrain | Без regolith simulation |
| **Regolith** (этот проект) | **Thickness map + angle of repose relax** | `GranularPatch`: heightfield collider, spoil patches, VFX grains |

**Offline VFX (не игры, но эталон):**
- Disney **Frozen** snow — MPM (Stomakhin et al. SIGGRAPH 2013)
- DreamWorks sand — MPM + GPU + Adaptive Particle Activation (Klar et al. 2018)
- Houdini **Vellum Grains** — DEM-like grains on surfaces

**NASA / space sims (не игры, но релевантно Regolith):**
- **Project Chrono** — DEM/CRM/SCM для rover mobility (VIPER, RASSOR, Curiosity)
- **NASA IPEx** bucket drum — DEM оптимизация scoop geometry
- **Colorado School of Mines SAMPLR** — DEM для PSR regolith interaction

---

## 3. Open source код

### MPM / MLS-MPM
| Репозиторий | Описание | Лицензия |
|---|---|---|
| [taichi-dev/taichi](https://github.com/taichi-dev/taichi) + [mpm88.py](https://github.com/taichi-dev/taichi/blob/master/python/taichi/examples/simulation/mpm88.py) | 88 строк MLS-MPM | Apache 2.0 |
| [yuanming-hu/taichi_mpm](https://github.com/yuanming-hu/taichi_mpm) | SIGGRAPH 2018 MLS-MPM + CPIC, sand/snow/water | MIT |
| [phys-sim-book/solid-sim-tutorial/11_mpm_sand](https://github.com/phys-sim-book/solid-sim-tutorial/tree/main/11_mpm_sand) | 2D sand tutorial | — |
| [GPU MPM (Gao et al.)](https://pages.cs.wisc.edu/~sifakis/papers/GPU_MPM.pdf) | SPGrid, 10M particles <1 мин/кадр | Paper + refs |

### DEM
| Репозиторий | Описание |
|---|---|
| [projectchrono/chrono](https://github.com/projectchrono/chrono) + [DEM-Engine](https://github.com/projectchrono/DEM-Engine) | Dual-GPU DEM, lunar rover demos, 150M elements на A100 |
| [Chrono::GPU](https://projectchrono.org/) | Monodisperse spheres, mesh coupling |
| [LAMMPS granular](https://www.lammps.org/) | Research DEM, не real-time |

### PBD / Fluids / Unified
| Репозиторий | Описание |
|---|---|
| [InteractiveComputerGraphics/PositionBasedDynamics](https://github.com/InteractiveComputerGraphics/PositionBasedDynamics) | PBD + PBF, C++/Python |
| [NVIDIA FleX](https://developer.nvidia.com/flex) | **Deprecated** (2020+), но GitHub mirror есть |
| [noprobelm/bevy_falling_sand](https://github.com/noprobelm/bevy_falling_sand) | CA falling sand для Bevy |
| [mmacklin.com/uppfrta](https://mmacklin.com/uppfrta_preprint.pdf) | Unified PBD paper + reference impl в FleX |

### Commercial (не open, но API)
| Продукт | Метод |
|---|---|
| [Algoryx AGX Dynamics](https://www.algoryx.se/) | NDEM + `agxTerrain` |
| Houdini Vellum Grains | DEM-like |
| Unreal Chaos | Нет native granular; сторонние плагины |

---

## 4. Feasibility для real-time игры на consumer hardware

### Realistic budget (RTX 3060–4070, 60 fps, ~2 ms physics budget)

| Метод | Feasible? | Типичный масштаб | Комментарий |
|---|---|---|---|
| **Heightfield/thickness** | ✅ Да | 256²–1024² cells | Лучший ROI для terrain/spoil. Regolith path |
| **CA falling sand** | ✅ Да | 512²–2048² active pixels | Noita-style; CPU-bound, но оптимизируемо |
| **PBD/PBF granular (Flex-style)** | ⚠️ Ограниченно | 5K–50K particles | Локальные кучи, песочница; piles OK с position friction |
| **SPH fluids** | ⚠️ Ограниченно | 10K–100K (PBF) | Чистый SPH слишком bouncy; PBF лучше |
| **MPM sand** | ❌ Hero only | 5K–20K (1 GPU consumer) | 55K@60fps = 4×V100 + оптимизация; не для open world |
| **DEM** | ❌ Offline / co-sim | 10K real-time; 10⁶+ offline | Chrono: 1M×1M steps ≈ 1 час на 2×RTX 3080 |

### Практические рекомендации для lunar sandbox

```
┌─────────────────────────────────────────────────────────┐
│  Open world (km scale)                                  │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Heightfield/thickness patches (GranularPatch)   │   │
│  │ — relax, spill, settle_load, angle of repose      │   │
│  └─────────────────────────────────────────────────┘   │
│                         ↓ spill events                    │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Local hero zone (optional, 10m radius)          │   │
│  │ — PBD grains OR MPM OR DEM offline bake         │   │
│  └─────────────────────────────────────────────────┘   │
│                         ↓                                 │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Presentation: VFX particles, grit mesh          │   │
│  │ — не влияют на физику (Regolith GRANULAR-V0)     │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

**Для Regolith specifically:**
- Heightfield + thickness — правильный выбор для host-authoritative коопа (детерминизм, объём).
- DEM/MPM — для **offline validation** параметров (угол откоса, sinkage curves Apollo/Surveyor), не для runtime.
- Chrono CRM (continuum + SPH discretization) — middle ground для rover terramechanics research (RTF 30–200×, не real-time).

---

## 5. Ключевые papers, demos, videos

### Must-read (granular + fluids)

| Работа | Год | Метод | Ссылка |
|---|---|---|---|
| **Animating Sand as a Fluid** (Zhu & Bridson) | 2005 | FLIP + friction | [ACM TOG](https://dl.acm.org/doi/10.1145/1073204.1073743) |
| **Drucker-Prager Elastoplasticity for Sand** (Klár et al.) | 2016 | MPM sand | [ACM TOG](https://doi.org/10.1145/2897824.2925906) |
| **A Moving Least Squares MPM** (Hu et al.) | 2018 | MLS-MPM + Taichi | [GitHub](https://github.com/yuanming-hu/taichi_mpm) |
| **GPU Optimization of MPM** (Gao et al.) | 2018 | GPU MPM | [PDF](https://pages.cs.wisc.edu/~sifakis/papers/GPU_MPM.pdf) |
| **Unified Particle Physics for Real-Time** (Macklin et al.) | 2014 | PBD + granular friction | [PDF](https://mmacklin.com/uppfrta_preprint.pdf) |
| **Real-time GPU Granular** (Bell et al.) | 2005 | DEM tetrahedral grains | [PDF](http://wnbell.com/media/2005-07-SCA-Granular/BeYiMu2005.pdf) |
| **Sand Surface Flow** (Zhu & Yang) | 2010 | DEM + heightfield BCRE | [PDF](https://www.cs.dartmouth.edu/~bozhu/papers/sand_surface_flow.pdf) |
| **Interactive HR Granular** | 2022 | PBD + upsampling | [arXiv](https://arxiv.org/abs/2308.01629) |
| **Real-time Height-field Sand+Water** | 2023 | 2.5D shallow | [ACM](https://doi.org/10.1145/3610548.3618159) |
| **Principles towards Real-Time MPM** | 2021 | Multi-GPU MPM | [arXiv](https://arxiv.org/abs/2111.00699) |
| **PBI: PBD + inelasticity** | 2024 | XPBD ≈ MPM sand | [arXiv](https://arxiv.org/abs/2405.11694) |
| **Multi-species Sand+Water** (Tampubolon et al.) | 2017 | Two-grid MPM | [SIGGRAPH](https://doi.org/10.1145/3072959.3073651) |

### Tutorials / surveys (аналог "Practical Guide")

| Ресурс | Содержание |
|---|---|
| [Position-Based Simulation Methods in CG](https://mmacklin.com/EG2015PBD.pdf) (EG 2015) | PBD/PBF tutorial, Bender et al. |
| [Macklin PBD Tutorial slides](https://matthias-research.github.io/pages/publications/PBDTutorial2017-slides-1.pdf) | FleX, granular friction |
| [Snow and Ice Animation Methods](https://onlinelibrary.wiley.com/doi/full/10.1111/cgf.15059) (CGF 2024) | Survey snow/granular/MPM |
| [PBD Grains blog](https://karthikriyer.github.io/blog/2024/pbd-grains/) | Hands-on PBD sand |
| [GTC 2022 Real-Time MPM slides](https://raymondyfei.github.io/gpu_mpm/GTC_slides.pdf) | GPU optimization principles |
| [phys-sim-book solid-sim-tutorial](https://github.com/phys-sim-book/solid-sim-tutorial) | Step-by-step MPM/FEM |

### Lunar regolith research

| Работа | Метод | Ссылка |
|---|---|---|
| Chrono DEM-Engine for extraterrestrial rovers | DEM | [arXiv 2311.04648](https://arxiv.org/abs/2311.04648) |
| NASA IPEx bucket drum DEM | DEM | [NASA ASCEND 2024](https://www.nasa.gov/wp-content/uploads/2024/08/ascend24-ipex-trl-5-design-overview.pdf) |
| Chrono lunar sensor simulation | SCM/CRM/DEM | [arXiv 2410.04371](https://arxiv.org/abs/2410.04371) |
| Gravitational offset misleading (lunar mobility) | CRM + SPH terrain | [NSF PAR](https://par.nsf.gov/servlets/purl/10611079) |
| CSM SAMPLR PSR rover-regolith DEM | DEM | [space.mines.edu](https://space.mines.edu/projects/) |
| Bucket drum optimization (ISRU) | DEM | [ScienceDirect 2025](https://www.sciencedirect.com/science/article/pii/S0022489825000291) |

### Videos / talks

| Видео | Тема |
|---|---|
| [Noita GDC 2019](https://www.youtube.com/watch?v=prXuyMCgbTc) | Falling sand at scale |
| [No Man's Sky GDC](https://www.youtube.com/watch?v=C9RyEiEzMiU) | Voxel world gen |
| [Taichi MPM demo](https://github.com/yuanming-hu/taichi_mpm) | MLS-MPM sand/snow |
| [NVIDIA FleX demos](https://developer.nvidia.com/flex) | PBF fluids + granular |
| [DreamWorks MPM production](https://research.dreamworks.com/wp-content/uploads/2018/07/42-0258-klar-Edited.pdf) | APA, GPU sand |

---

## Выводы для Regolith

1. **Academic gold standard для regolith** — DEM (Chrono) и CRM; RTF 100–14000×, не для 60 fps gameplay.
2. **VFX gold standard для sand** — MPM + Drucker-Prager; offline или hero zones ~10⁴ particles.
3. **Game industry standard** — heightfield/thickness + CA/PBD для локальных эффектов; Regolith уже на правильном пути.
4. **Не существует** готового «full MPM/DEM open world lunar sandbox» — все production решения гибридные.
5. **Следующий шаг R&D** (если нужен): offline Chrono DEM для калибровки `angle_of_repose`, `settle_load`, `density_scale` в `GranularPatch`; не замена runtime.

---

*Источники: ACM TOG/SIGGRAPH papers, Project Chrono, Taichi, NVIDIA FleX docs, NASA/CSM lunar ISRU publications, GDC talks (Noita, No Man's Sky), Game Developer deep dives.*

[REDACTED]
