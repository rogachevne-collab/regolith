# Middleware для fluid/granular симуляции в играх

Обзор для **indie-проекта на Godot 4.x**. Для lunar sandbox с рыхлым материалом (как в `docs/specs/GRANULAR-V0.md`) важнее не «красивая вода», а **масса, угол откоса, просыпание** — это другой класс задач, чем SPH/Navier-Stokes.

---

## Краткий вывод для indie Godot

| Категория | Варианты | Реалистичность для Godot |
|---|---|---|
| **Готово сегодня** | [Godot Rapier Physics](https://github.com/appsinacup/godot-rapier-physics) (Salva), compute shader демо, свой granular-патч | Высокая |
| **Возможно, но дорого** | Taichi AOT + GDExtension, PhysX 5 PBD, Bullet rigid grains | Средняя (месяцы работы) |
| **Только UE/Unity** | Zibra, Obi, Cocuy, Fluid Ninja, Havok | Низкая (порт ≠ интеграция) |
| **Deprecated / Omniverse-only** | FleX, legacy PhysX fluids, Flow | Не для нового Godot-проекта |
| **Рендер, не физика** | OpenVDB, ZibraVDB | Для дыма/огня, не для regolith |

**Для regolith/granular** лучший путь — **кастомная симуляция** (heightfield/thickness + relaxation, MPM offline → bake, или hybrid), а не готовый «fluid middleware».

---

## 1. NVIDIA FleX

| | |
|---|---|
| **Статус** | **Deprecated** — legacy SDK, без поддержки ([NVIDIA FleX](https://developer.nvidia.com/flex-example)) |
| **Godot** | Нет готовой интеграции. Теоретически GDExtension-обёртка над C API; на практике никто не поддерживает |
| **Лицензия** | Бесплатно для разработки, проприетарная EULA NVIDIA |
| **Качество** | Высокое для **unified PBD**: fluid + granular + cloth + soft body в одном солвере; GPU (CUDA/D3D) |
| **Игры** | Killing Floor 2, Batman: Arkham Knight (UE FleX branch), Fallout 4 (debris patch), NVIDIA VR Funhouse; Unity — [uFlex](https://assetstore.unity.com/packages/tools/utilities/uflex-59843) |

**Legacy-инфо:** FleX — единственный «коробочный» unified solver, где песок и вода взаимодействуют в одной particle-системе. NVIDIA заявила перенос идей в PhysX 5, но **не 1:1 замена** ([GitHub Discussion #129](https://github.com/NVIDIA-Omniverse/PhysX/discussions/129)). UE4 FleX branch ([NvPhysX/UnrealEngine tree FleX](https://github.com/NvPhysX/UnrealEngine/tree/FleX)) мёртв.

**Для Godot:** не рекомендуется. Deprecated, NVIDIA-only GPU, нет community wrapper.

---

## 2. NVIDIA Flow + Omniverse Physics

### NVIDIA Flow

| | |
|---|---|
| **Статус** | **Активен** в Omniverse как extension `omni.flowusd` — **Eulerian smoke/fire**, не жидкость ([Flow docs](https://nvidia-omniverse.github.io/PhysX/flow/index.html)) |
| **Godot** | Нет. HLSL compute, Vulkan/DX12, USD pipeline |
| **Лицензия** | Часть Omniverse; исходники в [NVIDIA-Omniverse/PhysX/flow](https://github.com/NVIDIA-Omniverse/PhysX/tree/main/flow) |
| **Качество** | Отличный дым/огонь; sparse voxel grid, NanoVDB export |
| **Игры** | Omniverse/Isaac Sim/VFX pipelines, не standalone games |

### Omniverse PhysX (PBD particles)

| | |
|---|---|
| **Статус** | **Активен** — PhysX 5.4+ PBD: fluid, **granular media**, cloth ([Particle Simulation docs](https://docs.omniverse.nvidia.com/extensions/latest/ext_physics/physics-particles.html)) |
| **Godot** | Нет. USD + Kit или `ovphysx` (Python/C, USD-native) |
| **Лицензия** | SDK source: **BSD-3** ([PhysX License](https://nvidia-omniverse.github.io/PhysX/physx/5.6.1/docs/License.html)); prebuilt wheels — Omniverse License |
| **Качество** | Высокое для AAA-sim; PBD fluid+granular + rigid coupling; **CUDA GPU обязателен** для particles |
| **Игры** | Robotics/sim (Isaac Sim), не коммерческие indie games |

**Для Godot:** PhysX 5 open source, но интеграция = custom `PhysicsServer3DExtension` + CUDA context. Месяцы работы; console ports сняты ([NVIDIA blog PhysX 5](https://developer.nvidia.com/blog/open-source-simulation-expands-with-nvidia-physx-5-release/)). Omniverse — не game runtime.

---

## 3. Havok Destruction + Havok Cloth

### Havok Destruction

| | |
|---|---|
| **Статус** | **Discontinued** как standalone ([Wikipedia](https://en.wikipedia.org/wiki/Havok_(software))) |
| **Godot** | Нет |
| **Лицензия** | Проприетарная, контакт через Microsoft |
| **Качество** | Pre-fractured rigid debris — **не granular regolith** |
| **Игры** | Red Faction, старые UE3-тайтлы |

### Havok Cloth

| | |
|---|---|
| **Статус** | **Активен** — Havok 2025.2 ([havok.com](https://www.havok.com/havok-cloth/)) |
| **Godot** | Нет. UE plugin через private GitHub |
| **Лицензия** | Physics/Navigation: **$50 000/title** при budget ≤ $20M ([pricing blog](https://www.havok.com/blog/pricing-update/)); Cloth — отдельно, по запросу |
| **Качество** | AAA cloth/hair/banners |
| **Игры** | Assassin's Creed, Halo, The Last of Us и др. |

**Для Godot:** не для indie. Cloth ≠ granular; Destruction = rigid chunks.

**Альтернатива destruction:** [NVIDIA Blast](https://github.com/NVIDIAGameWorks/Blast) (open source, BSD) — pre-fractured rigid, engine-agnostic; Godot-интеграции нет, но проще FleX/Havok.

---

## 4. PhysX particles & fluids (historical)

| Эра | API | Статус |
|---|---|---|
| PhysX 3.3 | `PxParticleFluid`, SPH | Deprecated в 3.4 ([deprecated list](https://docs.nvidia.com/gameworks/content/gameworkslibrary/physx/apireference/files/deprecated.html)) |
| PhysX 3.4 | FleX как альтернатива | Deprecated particles |
| PhysX 4.x | Particles **удалены** ([Issue #410](https://github.com/NVIDIAGameWorks/PhysX/issues/410)) |
| PhysX 5.x | `PxPBDParticleSystem` | Активен, CUDA GPU ([Particle System docs](https://nvidia-omniverse.github.io/PhysX/physx/5.4.0/docs/ParticleSystem.html)) |

**Игры (legacy):** Dark Cloud 2, Star Wars: The Force Unleashed, старые NVIDIA PhysX demos.

**Для Godot:** legacy PhysX 3.4 theoretically embeddable, но dead-end. PhysX 5 PBD — см. §2.

---

## 5. Bullet Physics (soft body / debris)

| | |
|---|---|
| **Статус** | **Активен** — [bullet3](https://github.com/bulletphysics/bullet3), Apache 2.0 |
| **Godot** | Встроен в Godot 3.x; в Godot 4 заменён на Jolt. Нет fluid/granular API |
| **Лицензия** | **Zlib** — бесплатно |
| **Качество** | Soft body (cloth/rope/jelly); **granular = thousands of rigid bodies** — research-only ([DOI paper](https://doi.org/10.1201/b17395-285)) |
| **Игры** | GTA, Red Dead (RAGE uses Bullet-derived), Blender, PyBullet robotics |

**Soft body:** `btSoftBody` — deformable meshes, не sand.

**Granular hack:** каждое зерно = `btRigidBody`. Работает для сотен–тысяч grains в research; для игрового regolith — плохо масштабируется.

**Godot:** custom GDExtension physics server — возможно, но Godot 4 уже на Jolt; Bullet не даёт fluid/granular из коробки.

---

## 6. OpenVDB (volumetric)

| | |
|---|---|
| **Статус** | **Активен** — Academy Award OSS ([openvdb.org](https://www.openvdb.org/)) |
| **Godot** | Нет native. Можно GDExtension + NanoVDB; community minimal |
| **Лицензия** | **MPL 2.0** |
| **Качество** | Хранение/render sparse volumes (smoke, SDF); **не симулятор** |
| **Игры/движки** | Houdini → UE 5.3+ Sparse Volume Textures; [eidosmontreal/unreal-vdb](https://github.com/eidosmontreal/unreal-vdb) |

**Для Godot:** полезен для **VFX/bake** (дым, пылевое облако из offline sim), не для interactive regolith physics. Flow экспортирует NanoVDB ([Flow sparse docs](https://nvidia-omniverse.github.io/PhysX/flow/index.html)).

---

## 7. Коммерческие плагины (Cocuy, Zibra, Obi, Fluid Ninja)

> «Cocoon» в индустрии не найден; вероятно имелся в виду **Cocuy** (2D GPU fluid для Unity).

### Cocuy (Unity)

| | |
|---|---|
| **Статус** | Активен — [Asset Store](https://assetstore.unity.com/packages/vfx/particles/cocuy-the-fluid-simulator-33564) |
| **Godot** | Нет |
| **Лицензия** | ~$20–40 (Asset Store) |
| **Качество** | 2D grid fluid (fire/water/smoke), GPU |
| **Игры** | Indie Unity VFX |

### Zibra Liquids / Smoke & Fire

| | |
|---|---|
| **Статус** | Активен — [zibra.ai](https://www.zibra.ai/zibra-liquid-smoke-effects) |
| **Godot** | Нет. UE + Unity only |
| **Лицензия** | Unity ~$50; UE full ~$150 ([80.lv](https://80.lv/articles/a-new-tutorial-series-on-using-zibra-liquids-in-unreal-engine)); free tier ограничен |
| **К quality** | AAA-realtime 3D liquid, AI SDF collisions, foam |
| **Игры** | Indie Unity/UE showcases |

### Obi Fluid (Unity)

| | |
|---|---|
| **Статус** | Активен — [Asset Store](https://assetstore.unity.com/packages/tools/physics/obi-fluid-63067) |
| **Godot** | Нет |
| **Лицензия** | ~$60–100 |
| **К quality** | CPU/GPU PBF/SPH, two-way rigid coupling, dripping/splash |
| **Игры** | Indie puzzle/action |

### Fluid Ninja LIVE (UE)

| | |
|---|---|
| **Статус** | Активен — [Fab/Marketplace](https://www.unrealengine.com/marketplace/en-US/product/fluidninja-live) |
| **Godot** | Нет |
| **Лицензия** | Marketplace (~$50–100) |
| **К quality** | 2D fluid sim → RT; sand/water/smoke **visual**, не full 3D physics |
| **Ограничение** | **No multiplayer replication** |

**Для Godot:** все — Unity/UE lock-in. Порт на Godot = переписать рендер + physics bridge.

---

## 8. Taichi Lang (custom sims)

| | |
|---|---|
| **Статус** | **Активен** — [taichi-lang.org](https://www.taichi-lang.org/), Apache 2.0 |
| **Godot** | Нет готового плагина. Путь: Taichi → **AOT module** → C++ GDExtension ([Taichi C++ tutorial](https://docs.taichi-lang.org/docs/master/tutorial)) |
| **Лицензия** | **Apache 2.0** |
| **К quality** | **Лучший OSS для MPM sand/snow/water** — MLS-MPM, GPU, миллионы particles |
| **Репозитории** | [taichi_mpm](https://github.com/yuanming-hu/taichi_mpm), [taichi_elements](https://github.com/taichi-dev/taichi_elements), [taichi_blend](https://github.com/taichi-dev/taichi_blend) |
| **Игры** | Research/demos; не shipped AAA titles |

**MPM sand:** Drucker-Prager elastoplasticity, friction angle — близко к regolith. [taichi_elements](https://github.com/taichi-dev/taichi_elements) — water, sand, snow, elastic.

**Godot integration path:**
1. Прототип в Python/Taichi
2. Export AOT (Vulkan/CUDA)
3. GDExtension wrapper: step sim → sync positions → MultiMesh/SDF
4. Coupling с Jolt через collision callbacks

**Сложность:** высокая (2–4 мес. для production-ready). Зато полный контроль и indie-friendly license.

**Смежное:** [Genesis World](https://github.com/Genesis-Embodied-AI/genesis-world) — unified MPM/SPH/PBD, Python, robotics; не game engine plugin.

---

## 9. Compute shader frameworks (Godot-native)

Godot 4: **RenderingDevice** API + `.glsl` compute shaders (`.gdshader` — visual only, R3).

| Проект | Тип | Ссылка |
|---|---|---|
| Jules5 GPU fluid | 3D GPU Navier-Stokes | [github.com/Jules5/godot-fluid-simulation](https://github.com/Jules5/godot-fluid-simulation) |
| realtime-fluid-sim | 3D particles + raymarch | [github.com/sebastianregelmann/realtime-fluid-sim](https://github.com/sebastianregelmann/realtime-fluid-sim) |
| fluid-sim-godot | Compute erosion/fluid | [github.com/Willenbrink/fluid-sim-godot](https://github.com/Willenbrink/fluid-sim-godot) |
| LitWithParticles | 2D NS + lighting | [github.com/3c0tr/LitWithParticles](https://github.com/3c0tr/LitWithParticles) |
| CPU NS tutorial | Educational | [myzopotamia.dev](https://myzopotamia.dev/navier-stokes-fluid-simulation-explained-with-godot) / [rskupnik/godot-fluid-simulation-demo](https://github.com/rskupnik/godot-fluid-simulation-demo) |

**Unity/UE reference implementations** (портировать алгоритмы, не код):
- [Warriorroq/RealtimeFluidSimulation](https://github.com/Warriorroq/RealtimeFluidSimulation) — SPH + marching cubes
- [abecombe/FLIP-Fluid-for-Unity](https://github.com/abecombe/FLIP-Fluid-for-Unity) — FLIP 3D
- [The-Mooncake/ComputeFluidSim](https://github.com/The-Mooncake/ComputeFluidSim) — UE plugin, Jacobi 3D grid

**Для granular:** grid-based NS ≠ sand. Для sand на GPU нужен **MPM/PBD granular** (свой compute) или heightfield relaxation (как в Regolith).

---

## 10. Godot-специфичные интеграции

### Godot Rapier Physics + Salva ⭐ лучший готовый fluid для Godot

| | |
|---|---|
| **Статус** | Активен — [appsinacup/godot-rapier-physics](https://github.com/appsinacup/godot-rapier-physics) |
| **Godot** | **GDExtension drop-in** physics server; `Fluid2D` / `Fluid3D` nodes |
| **Лицензия** | Apache 2.0 (Rapier/Salva) |
| **К quality** | SPH liquids (viscosity, surface tension, elasticity); **не sand/regolith** |
| **Docs** | [godot.rapier.rs/docs](https://godot.rapier.rs/docs/documentation/fluids/) |
| **Asset Store** | [Rapier 2D](https://godotengine.org/asset-library/asset/2267), [Rapier 3D](https://godotengine.org/asset-library/asset/3084) |

3D fluids — experimental ([progress tracker](https://godot.rapier.rs/docs/progress/)). Salva = **liquid SPH**, не granular angle-of-repose.

### Legacy: godot-rapier-2d (C++)

[AntonBergaker/godot-rapier-2d](https://github.com/AntonBergaker/godot-rapier-2d) — 2D only, superseded appsinacup version.

### Droplet hack

[ramblingstranger/godot-fluid-sim](https://github.com/ramblingstranger/godot-fluid-sim) — RigidBody3D droplets + cohesive forces; GDExtension C++. Дешёво, не масштабируется.

### PhysicsServer3DExtension

Godot 4 поддерживает custom physics servers ([PR #59140](https://github.com/godotengine/godot/pull/59140), [docs](https://docs.godotengine.org/en/stable/classes/class_physicsserver3dextension.html)). Путь для PhysX/Taichi/Bullet — **нет готовых maintained projects**.

### Jolt (текущий default Regolith)

Jolt — rigid/deformable limited; **нет fluid/granular**. Для regolith Regolith использует **GranularPatch** поверх SDF, не middleware.

---

## Сравнительная таблица: granular vs liquid

| Middleware | Liquid | Granular/sand | Godot | Indie cost |
|---|---|---|---|---|
| **Regolith GranularPatch** | — | ✅ heightfield + relaxation | ✅ native | Free |
| **FleX** | ✅ | ✅ unified PBD | ❌ | Free (deprecated) |
| **PhysX 5 PBD** | ✅ | ✅ | ❌ (months) | Free (BSD) |
| **Salva/Rapier** | ✅ SPH | ❌ | ✅ GDExtension | Free |
| **Taichi MPM** | ✅ | ✅ best fidelity | ⚠️ custom | Free |
| **Bullet rigid grains** | ❌ | ⚠️ hack | ⚠️ | Free |
| **Zibra/Obi** | ✅ | ❌ | ❌ | $50–150 |
| **Fluid Ninja** | visual | visual sand | ❌ | ~$50 |
| **OpenVDB** | render only | — | ⚠️ | Free |

---

## Рекомендации для indie Godot (regolith focus)

### Tier 1 — использовать сейчас
1. **Продолжать GranularPatch** (`docs/specs/GRANULAR-V0.md`) — правильная абстракция для lunar regolith: volume conservation, angle of repose, Jolt heightfield collision.
2. **Godot Rapier + Salva** — если нужна **вода/гидравлика** (бур, leak), не песок.
3. **Compute shaders** — локальные VFX (пыль, струя при бурении), decoupled от gameplay truth.

### Tier 2 — если нужен full 3D sand MPM
- **Taichi elements → AOT → GDExtension** — единственный реалистичный OSS path к FleX-quality sand без Unity/UE.
- Прототип offline (Houdini MPM / Taichi) → bake VDB/particles для cutscenes; runtime — упрощённый patch.

### Tier 3 — не тратить время
- FleX (deprecated, no support)
- Havok ($50k+)
- Zibra/Obi port on Godot
- Omniverse/Flow as game runtime
- OpenVDB as physics engine

---

## Полезные ссылки (Godot integration attempts)

| Ресурс | URL |
|---|---|
| Godot Rapier Physics | https://github.com/appsinacup/godot-rapier-physics |
| Rapier fluids docs | https://godot.rapier.rs/docs/documentation/fluids/ |
| GDExtension physics API | https://docs.godotengine.org/en/stable/classes/class_physicsserver3dextension.html |
| Godot GPU fluid (Jules5) | https://github.com/Jules5/godot-fluid-simulation |
| Godot droplet fluid | https://github.com/ramblingstranger/godot-fluid-sim |
| Taichi AOT + C++ | https://docs.taichi-lang.org/docs/master/tutorial |
| Taichi MPM sand | https://github.com/yuanming-hu/taichi_mpm |
| PhysX 5 OSS | https://github.com/NVIDIA-Omniverse/PhysX |
| NVIDIA FleX legacy | https://developer.nvidia.com/flex |
| FleX ≠ PhysX parity | https://github.com/NVIDIA-Omniverse/PhysX/discussions/129 |

---

**Итог:** для indie Godot с lunar regolith **нет turnkey middleware** уровня FleX. Ближайшие готовые куски — **Salva (жидкость)** и **compute shader VFX**. Для gameplay-critical granular (отвал, угол естественного откоса, просыпание) — **custom simulation**, как уже заложено в Regolith, с опциональным Taichi MPM для R&D или cinematic quality.

[REDACTED]
