# Granular / Fluid — research synthesis

Сводка исследований middleware и подходов для granular/fluid в контексте
Regolith (Godot 4.8, Jolt, indie, лунный regolith). См. также `GRANULAR-V0.md`.

---

## Middleware (дополнение)

Дата: 2026-07-20. Фокус: **доступность для indie-разработчика на Godot** — лицензия,
готовый GDExtension, кроссплатформенность, зрелость API для granular (не только
«красивая вода»).

### Сводная таблица

| Middleware | Статус (2025–26) | Granular / fluid | Godot GDExtension | Стоимость (indie) | Игры / применение |
|---|---|---|---|---|---|
| **NVIDIA FleX** | Legacy, unsupported | Unified PBD: fluid, cloth, soft, granular, phase transitions | Нет; CUDA-only; WIP `beiller/godot_physx` не про FleX | Бесплатно (legacy download) | Killing Floor 2, Fallout 4 (patch 1.3 debris), NVIDIA VR Funhouse, TouchDesigner |
| **NVIDIA Flow** | Активен; open source (apr 2025) | Sparse voxel **gas** (дым/огонь), не liquid/granular | Нет; HLSL/DX11–12, интеграция с нуля | BSD-3, бесплатно | Omniverse/Isaac Sim VFX; не игровой runtime |
| **NVIDIA PhysX 5.6** | Активен; GPU code open source (apr 2025) | PBD particles: fluid, **granular (sand)**, cloth; FEM soft body; Flow smoke | Нет официального; `beiller/godot_physx` — эксперимент; нужен custom PhysicsServer | BSD-3, бесплатно | Omniverse, Isaac Sim, O3DE; legacy: Borderlands 2, Mirror's Edge (rigid); particles — сим-стек NVIDIA |
| **Havok Physics** | Активен (Microsoft) | Havok Particles: lightweight fluid/VFX/destruction, не continuum granular | SDK «any engine», но **нет Godot-биндинга**; интеграция = months | **$50k/product** (budget ≤$20M); не indie | Helldivers 2, Elden Ring (nav), Destiny 2 (cloth), Halo, Skyrim (legacy) |
| **Bullet 3** | Поддерживается; soft body PBD + deformable CG | Soft body/cloth; granular только DIY (нет native sand) | Был в Godot 3; **удалён из Godot 4**; GDExtension с нуля | zlib, бесплатно | GTA, Red Dead (частично), research/DEM; Godot — исторический backend |
| **OpenVDB** | Активен (ASWF); Apache 2.0 | **Хранение/CSG** sparse volumes; не real-time granular solver | Нет native import; community: VDB→Texture3D + raymarch; GDExtension возможен | Бесплатно | Feature film (DreamWorks); в играх — baked VDB / ZibraVDB, не симуляция |
| **Taichi Lang** | Активен; Apache 2.0 | MPM (sand/snow/water), SPH; research-grade | Нет Godot plugin; Unity C-API (Vulkan only); GDExtension = Taichi AOT + compute bridge | Бесплатно | taichi_elements demos; Unity Taichi-UnityExample; Blender addon (experimental) |
| **Zibra Effects** | Активен | Real-time liquid/smoke/fire (SDF colliders); **не regolith/granular bulk** | **Только UE + Unity** | Indie **$120** lifetime (rev ≤$100k); ZibraVDB free (≤$100k) | Echoes of Somewhere, Hydrolab (AR); marketing cites AC/Subnautica как genre refs |
| **PositionBasedDynamics** | Активен; MIT | PBD fluids + rigid; granular через friction model (Macklin et al.) | Нет; C++ lib → custom GDExtension | Бесплатно | База для SPlisHSPlasH; academic real-time sand demos |
| **SPlisHSPlasH** | Активен v2.17; MIT | SPH fluid + deformable solids; не dedicated granular | Нет; offline/batch или heavy wrapper | Бесплатно | Research tool; EPA game-engine study; экспорт Partio/VTK |
| **Obi Fluid** (Unity) | Активен | PBD fluid + **Granular blueprint** (sphere particles) | Unity only | **$60** (Fluid) / $179 (Suite) | Unity indie standard для fluid/granular VFX |
| **Rapier + Salva** | Активен | **2D fluid** (Salva); 3D fluid — WIP | **Да** — Asset Library GDExtension | Бесплатно (MIT/Apache) | Godot community; не 3D regolith |
| **Godot SPH addon** | Community | 3D SPH compute (32k+ particles) | **Да** — Asset Library | MIT | Демо/VFX; не gameplay granular bulk |
| **Jolt** (встроен в Godot 4.4+) | Default 3D physics | Rigid + heightfield; **нет** granular/fluid | Встроен (не GDExtension) | Бесплатно | Godot 4.6 default; Regolith использует для коллизий |

### Детали по ключевым кандидатам

#### NVIDIA FleX

- **Статус:** официально legacy ([NVIDIA Developer](https://developer.nvidia.com/flex-example)); download as-is, без поддержки. Функциональность частично перешла в PhysX PBD, но **не 1:1** ([PhysX Discussion #129](https://github.com/NVIDIA-Omniverse/PhysX/discussions/129)).
- **Granular:** unified particle solver — один из немногих с phase transitions (fluid↔solid); CUDA-only → плохая кроссплатформенность для shipping.
- **Godot:** нецелесообразен для indie Godot в 2026: мёртвая поддержка, NVIDIA-only, нет готового моста.
- **Вердикт для Regolith:** ❌ архивный интерес, не production path.

#### NVIDIA Flow

- **Статус:** активная разработка в репозитории [NVIDIA-Omniverse/PhysX](https://github.com/NVIDIA-Omniverse/PhysX); Flow 2.2 + GPU shaders open source (BSD-3, апрель 2025).
- **Granular:** **нет** — combustible **gaseous** fluids (огонь/дым), sparse voxel grid, HLSL.
- **Godot:** интеграция = порт HLSL→GLSL/Vulkan RDG + отдельный сим-цикл; months of engine work.
- **Вердикт:** ❌ для regolith; ⚠️ только если нужен in-engine fire/smoke на Vulkan.

#### NVIDIA PhysX 5.6 (+ PBD particles)

- **Статус:** активен; SDK + GPU kernels open source (BSD-3). PBD particles: fluid, **granular (sand)**, cloth; GPU-only для particles ([Omniverse docs](https://docs.omniverse.nvidia.com/extensions/latest/ext_physics/physics-particles.html)).
- **Granular:** preset materials для sand-like media; двусторонняя связь с rigid/deformable; **не** continuum/rheology (Bingham и т.п. — аппроксимация поверх PBD).
- **Godot:** Godot **не планирует** встроенный PhysX ([proposal #4044](https://github.com/godotengine/godot-proposals/discussions/4044)); единственный след — эксперимент [`beiller/godot_physx`](https://github.com/beiller/godot_physx) (заброшен). Реалистичный путь: GDExtension PhysicsServer3D **или** sidecar sim + sync transforms — оба **high effort**.
- **Стоимость:** $0; но скрытая цена — CUDA/NVIDIA GPU для particles, AMD/Intel GPU acceleration потребует форка kernels.
- **Вердикт:** ⚠️ технически лучший «готовый» granular PBD, но **плохой fit для open indie Godot** (нет plugin, NVIDIA GPU lock-in, огромный integration cost).

#### Havok

- **Статус:** активная разработка (SDK 2025.2); Microsoft. Havok Particles — fast VFX fluid/destruction, trade fidelity for speed ([havok.com](https://www.havok.com/havok-physics/)).
- **Godot:** SDK «integrates with any engine» — на практике custom C++ bridge; **zero Godot ecosystem**.
- **Стоимость:** $50 000/product (budget ≤$20M) — **не indie** ([GDC 2025](https://www.gamedeveloper.com/programming/25-years-in-havok-unveils-royalty-free-pricing-for-budgets-up-to-20-million)).
- **Вердикт:** ❌ для Regolith.

#### Bullet 3

- **Статус:** maintained; soft body (legacy PBD + newer deformable CG solver). **Нет** dedicated granular/fluid module.
- **Granular:** возможен DIY (research: DEM-like clumps); PositionBasedFluids — отдельные проекты, не в core Bullet.
- **Godot:** удалён из Godot 4; возврат = полный GDExtension physics server (как Jolt, но без community momentum).
- **Игры:** широко в AAA middleware stacks historically; в Godot — мёртвый путь.
- **Вердикт:** ❌ superseded by Jolt для rigid; не решает granular.

#### OpenVDB (+ NanoVDB)

- **Статус:** ASWF, Apache 2.0; industry standard для **offline/baked** volumetrics.
- **Granular:** формат хранения, не solver. Real-time sim через OpenVDB возможен для CSG/fields, но тяжёлый для game loop.
- **Godot:** нет importers; pipeline VDB→Texture3D→shader ([community tools](https://github.com/meowyih/godot_openvdb_texture3d)); proposal [#2516](https://github.com/godotengine/godot-proposals/issues/2516) закрыт в пользу bake.
- **Вердict:** ⚠️ для **рендера baked dust plumes**, не для dig/spoil gameplay truth.

#### Taichi Lang

- **Статус:** активен; Apache 2.0; Python DSL → CUDA/Vulkan/CPU.
- **Granular:** taichi_elements (MPM: sand, snow, water) — research demos; SPH_Taichi — million-particle SPH.
- **Godot:** **нет** GDExtension. Unity path: [Taichi-UnityExample](https://github.com/taichi-dev/Taichi-UnityExample) (Vulkan-only, experimental). Для Godot: AOT compile kernels → RenderingDevice compute — **custom R&D**.
- **Вердикт:** ⚠️ отличный **prototyping** (offline bake или sidecar), ❌ turnkey для shipped Godot game.

#### Zibra (Liquid / Smoke&Fire / VDB)

- **Статус:** активен; UE + Unity (+ Houdini для VDB).
- **Granular:** **нет** — liquids + volumetric smoke/fire; small-to-midsize interactive VFX.
- **Godot:** **нет SDK/plugin**. ZibraVDB free для indie (≤$100k) — только UE/Houdini import.
- **Стоимость:** Zibra Effects indie **$120** lifetime ([zibra.ai](https://www.zibra.ai/zibra-liquid-smoke-effects)); ZibraVDB Personal free.
- **Игры:** Echoes of Somewhere, Hydrolab; case studies, не AAA bulk regolith.
- **Вердict:** ❌ Godot; ⚠️ если команда также шипит Unity/UE build.

### Godot-native и community альтернативы (важнее middleware для indie)

| Подход | Granular fit | Effort | Примечание |
|---|---|---|---|
| **Custom heightfield patch** (`GranularPatch`) | ★★★★★ для bulk regolith | Уже в проекте | Истина = thickness map, не particles; см. `GRANULAR-V0.md` |
| **Voxel CA / cellular** (`granular_voxel_field`) | ★★★★ локальный flow | В R&D | Хорош для bench/PoC |
| **Compute SPH (Asset Library)** | ★★ VFX liquid | Low (plugin) | 32k particles, SDF collision; не lunar bulk |
| **Rapier+Salva 2D** | ★ 2D only | Low | Fluids в 2D проектах |
| **PositionBasedDynamics / SPlisHSPlasH** | ★★★ research | High (C++ GDExtension) | MIT; нет готового Godot bridge |
| **PhysX PBD** | ★★★★ capability | Very high | Open source, но NVIDIA+custom server |
| **Baked VFX (EmberGen/LiquiGen/Houdini→VDB/flipbook)** | ★ presentation | Low–medium | 200+ game studios на EmberGen; **zero gameplay coupling** |

### Рекомендация для Regolith (indie Godot)

1. **Gameplay truth для lunar regolith** — оставаться на **custom continuum** (`GranularPatch` / voxel CA), не middleware particles. Причины: determinism (R6 coop), coupling с voxel SDF crust, planetoid anchors, контроль угла repose — middleware не даёт этого из коробки.

2. **Presentation layer** — declarative VFX + optional local particle burst; baked flipbooks (EmberGen) для dust plumes; OpenVDB/ZibraVDB **не нужны** unless cinematic quality bar rises.

3. **Если нужен interactive 3D liquid** (не regolith bulk) — Godot SPH compute addon или sidecar Taichi/PhysX R&D; не FleX/Havok.

4. **Не тратить время на:** FleX (dead), Havok ($50k), Zibra/Obi (wrong engine), OpenVDB as solver.

### Источники

- [NVIDIA FleX legacy notice](https://developer.nvidia.com/flex-example)
- [PhysX SDK / open source GPU (apr 2025)](https://developer.nvidia.com/physx-sdk)
- [PhysX PBD particles docs](https://docs.omniverse.nvidia.com/extensions/latest/ext_physics/physics-particles.html)
- [Flex vs PhysX particles (#129)](https://github.com/NVIDIA-Omniverse/PhysX/discussions/129)
- [Havok pricing](https://www.havok.com/pricing/)
- [Zibra Effects pricing](https://www.zibra.ai/zibra-liquid-smoke-effects)
- [OpenVDB GitHub / Apache 2.0](https://github.com/AcademySoftwareFoundation/openvdb)
- [Taichi license](https://www.taichi-lang.org/)
- [PositionBasedDynamics](https://github.com/InteractiveComputerGraphics/PositionBasedDynamics)
- [SPlisHSPlasH](https://splishsplash.physics-simulation.org/)
- [Godot PhysX proposal #4044](https://github.com/godotengine/godot-proposals/discussions/4044)
- [Godot Rapier Physics](https://github.com/appsinacup/godot-rapier-physics)
- [Godot 3D SPH addon](https://godotengine.org/asset-library/asset/5116)
