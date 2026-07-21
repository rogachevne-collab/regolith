# Симуляция сыпучих материалов в Godot: обзор для лунного реголита

Godot **не имеет встроенной 3D-симуляции гранул** (песка, рыхлого грунта, реголита). Все рабочие решения — кастомные слои поверх движка. Ниже — что реально существует в экосистеме и что из этого применимо к игре вроде Regolith (voxel-копка + рыхлый материал на сферическом теле).

---

## 1. Доступные подходы в Godot

### 1.1. Частицы (GPUParticles3D / CPUParticles3D)

**Суть:** GPU-частицы — сотни тысяч «точек» с кастомным process shader, гравитацией, attractor/collision nodes.

| Аспект | Реальность |
|---|---|
| Количество | GPU: сотни тысяч визуальных частиц; CPU: на порядок меньше |
| Коллизия | `GPUParticlesCollisionBox3D/Sphere3D`, `HeightField3D`, `SDF3D` — только **визуальная** реакция на геометрию |
| Лимиты | Жёсткий cap **32 collider/attractor** на одну систему; max **7 SDF/vector field** на Forward+ ([issue #110860](https://github.com/godotengine/godot/issues/110860)) |
| Физика | Нет стекания, угла откоса, объёмной консервации — частицы не «сыпятся» как грунт |

**Вывод:** годится для **пыли, искр, струи при бурении**, но не для источника истины о рыхлом материале.

Документация: [Particle systems (3D)](https://docs.godotengine.org/en/stable/tutorials/3d/particles/index.html), [3D Particle collisions](https://docs.godotengine.org/en/stable/tutorials/3d/particles/collision.html).

---

### 1.2. Heightfield / деформация поверхности

**Суть:** карта высот → mesh + `HeightMapShape3D`. Материал «течёт» через перераспределение высот, а не через отдельные зёрна.

| Вариант | Описание |
|---|---|
| **Vertex displacement shader** | Noise/heightmap в vertex shader; дёшево, но без физики и без сохранения объёма |
| **HTerrain** (Zylann) | GDScript heightmap terrain: sculpt, holes, LOD, трава — **нет сыпучести** ([github.com/Zylann/godot_heightmap_plugin](https://github.com/Zylann/godot_heightmap_plugin)) |
| **Terrain3D** | C++ GDExtension, GPU clipmap, sculpt/holes — editor terrain, не granular flow ([github.com/TokisanGames/Terrain3D](https://github.com/TokisanGames/Terrain3D)) |
| **Кастомный height field** | `PackedFloat32Array` → mesh + `HeightMapShape3D`; релаксация по углу откоса — **именно этот паттерн** использует Regolith |

**Шейдерные трюки без физики:**
- SubViewport-маска следов/колеи → vertex displacement ([godotshaders.com — car tracks on sand](https://godotshaders.com/shader/car-tracks-on-snow-or-sand-using-viewport-textures-and-particles/))
- Анимированный normal map «течения» песка ([Anime-esque Quicksand Shader](https://godotshaders.com/shader/anime-esque-quicksand-shader/))
- Процедурная «эрозия» mesh + dust particles ([Journey Sand Shader](https://summit-2021-sem2.game-lab.nl/2021/03/22/journey-sand-shader/))

**Вывод:** для **3D loose soil на больших масштабах** heightfield + angle-of-repose — единственный практичный путь в Godot без собственного движка.

---

### 1.3. Cellular automata / Falling Sand (2D)

**Суть:** сетка ячеек, локальные правила (вниз → диагональ), порядок обхода сверху вниз, active-cell tracking.

| Реализация | Производительность | Масштаб |
|---|---|---|
| GDScript + TileMap/Image | ~тысячи–десятки тысяч ячеек | 2D, mobile |
| C# (`Image.set_pixel`) | лучше GDScript, всё ещё CPU-bound | 2D |
| **C++ GDExtension** | десятки–сотни тысяч ячеек/кадр | 2D, Noita-like |
| **Compute shader** (RenderingDevice) | миллионы ячеек на GPU | 2D, без readback |

На форуме Godot прямо советуют: симуляция — в **нативном коде или compute**, рендер — shader/texture ([forum: pixel sandbox simulation](https://forum.godotengine.org/t/best-way-to-display-a-2d-pixel-sandbox-simulation/53443)). Для Terraria-style падающих блоков — grid swap или временный Sprite2D вместо tilemap ([forum: falling tiles](https://forum.godotengine.org/t/how-to-implement-falling-tiles-like-the-sand-tiles-in-terraria/104534)).

**Вывод:** falling sand в Godot — **зрелая ниша для 2D**, но **не переносится напрямую** на сферический 3D voxel-мир без радикальной архитектуры.

---

### 1.4. RigidBody3D «по зёрну»

**Суть:** каждое зёрно — `RigidBody3D` + sphere/box collider.

| Jolt (Godot 4.6 default) | ~500 boxes @ 60 fps | ~5000 @ ~38 fps | ~10000 @ ~19 fps |
|---|---|---|---|
| GodotPhysics3D | заметно хуже на больших счётчиках | | |

Источник: [StraySpark Jolt benchmarks](https://www.strayspark.studio/blog/godot-46-jolt-physics-migration-guide).

**Проблемы для реголита:**
- 1 м³ при 1 мм зёрна ≈ **10⁹ тел** — нереально
- даже 10⁴ активных тел — уже stress test, не геймплей
- нет angle of repose без ручного constraint solver
- детерминизм коопа под вопросом при contact chaos

**Вывод:** RigidBody — для **десятков–сотен камней/обломков**, не для spoil heap.

---

### 1.5. SoftBody3D / PBD / fluids

| Технология | Применимость к гранулам |
|---|---|
| **SoftBody3D** (Jolt) | ткань/мягкие деформации; experimental, не сыпучесть ([soft body docs](https://docs.godotengine.org/en/stable/tutorials/physics/soft_body.html)) |
| **PositionBasedDynamicsForGodot** | демо верёвок/ткани, не sand ([github.com/ner-develop/PositionBasedDynamicsForGodot](https://github.com/ner-develop/PositionBasedDynamicsForGodot)) |
| **GPU Cloth (PBD compute)** | cloth constraints, не granular ([godotassetlibrary.com](https://godotassetlibrary.com/asset/2lh97V/gpu-cloth-simulation)) |
| **PositionBasedDynamics (C++ lib)** | fluids + rigid + deformable — но **нет Godot-интеграции** для sand ([github.com/InteractiveComputerGraphics/PositionBasedDynamics](https://github.com/InteractiveComputerGraphics/PositionBasedDynamics)) |
| **Compute water plane** | 2D heightfield fluid demo ([godot-demo-projects](https://github.com/godotengine/godot-demo-projects/blob/master/compute/texture/water_plane/water_plane.gd)) |

**Вывод:** PBD/fluids в Godot — **отдельная R&D-ветка**, готового granular addon нет.

---

### 1.6. Voxel terrain + loose material (гибрид)

Voxel-модули (**Voxel Tools / Zylann**) дают SDF-копку, mesh, collision — но **не spoil flow**:

> «Voxels are transformed into chunked meshes… Godot physics integration» — без loose material layer  
> ([github.com/Zylann/godot_voxel](https://github.com/Zylann/godot_voxel))

Типичный паттерн индустрии: **твёрдое = voxel SDF**, **рыхлое = отдельный слой** (height field, CA grid или physics bodies).

---

## 2. Примеры кода и проектов

### 2.1. Falling Sand / CA (2D)

| Проект | Стек | Особенности |
|---|---|---|
| [kiwijuice56/sand-slide](https://github.com/kiwijuice56/sand-slide) | C++ GDExtension + Godot 4.3 | Production-ish; [itch.io](https://kiwijuice56.itch.io/sand-slide), Google Play |
| [KunkelAlexander/neon-sand](https://github.com/KunkelAlexander/neon-sand) | C++ GDExtension | Active cells, web export, [demo](https://kunkelalexander.github.io/neon-sand/) |
| [kiwijuice56/sand-spoon](https://github.com/kiwijuice56/sand-spoon) | GDScript Resources | Модульные Element resources, id+data на ячейку |
| [MathExpert/GodotSand](https://github.com/MathExpert/GodotSand) | C# | Простой шаблон; ссылки на Noita, Sandspiel, Reddit alchemy thread |
| [Lukvargen/Sandbox](https://github.com/Lukvargen/Sandbox) | C# | 9 элементов, paint brush |
| [stereoa/Godot-Falling-Sand](https://github.com/stereoa/Godot-Falling-Sand) | GDScript mobile | Proof-of-concept на Android Editor |
| [Texnist/PixelDot](https://github.com/Texnist/PixelDot) | C# plugin | `BlockFluid` с `Vertical Only` = Minecraft sand |
| [pascal-ballet/CellularAutomataStudio](https://github.com/pascal-ballet/CellularAutomataStudio) | Compute GLSL plugin | CA в editor через GLSL snippets |
| [bruce965/godot-gpu-cellular-automata](https://github.com/bruce965/godot-gpu-cellular-automata) | Viewport ping-pong shader | Obsolete, но учебный |
| [woldendans/test-cellular-automaton-godot](https://github.com/woldendans/test-cellular-automaton-godot) | Compute RD | Reaction-diffusion, не sand |

**YouTube / описания:**
- [Godot Sand Simulation Explained](https://www.youtube.com/watch?v=5CI9Tn1JWDw) — TileMap + timer, ~100 строк GDScript
- [2D Liquid CA in Godot](https://www.youtube.com/watch?v=nF7cdUVgvNc) — fluid amount per pixel
- [Everything to Know About PARTICLES in Godot 4](https://www.youtube.com/watch?v=yWIH7hHfWyU) — VFX, не granular physics

### 2.2. 3D terrain / digging

| Проект | Что делает |
|---|---|
| [ape1121/Godot4-3D-Smooth-Destructible-Terrain](https://github.com/ape1121/Godot4-3D-Smooth-Destructible-Terrain) | Chunk heightmap + dig; spoil нет |
| [JorisAR/GDVoxelTerrain](https://github.com/JorisAR/GDVoxelTerrain) | SDF octree + surface nets |
| [Anthill (hromp.com)](https://hromp.com/anthill/) | Godot 4.2+: «one voxel ≈ one sand grain», granular substrate + nest digging — **ближайший аналог научной granular CA в Godot** |

### 2.3. Референсы вне Godot (для сравнения)

| Проект | Зачем смотреть |
|---|---|
| [Noita / Falling Everything](https://www.youtube.com/watch?v=prXuyMCgbTc) | GDC talk — per-pixel CA + rigidbody coupling |
| [Sandspiel](https://sandspiel.club/) / [source](https://github.com/MaxBittker/sandspiel) | Web CA + fluid wind VFX |
| [PyxisEngine](https://github.com/MrJones16/PyxisEngine) | C++ multiplayer falling sand + Box2D rigid |
| [mintage (Rust)](https://github.com/astradamus/mintage) | Multithreaded CA, material chemistry |

---

## 3. Плюсы и минусы для симуляции лунного реголита

Лунный реголит в игре: **низкая g (1.62 m/s²)**, angle of repose ~30–35°, мелкодисперсный, cohesion слабая, объём при копке растёт (bulking), нужна **читаемость** куч и осыпей, не DEM-точность.

| Подход | Плюсы для реголита | Минусы |
|---|---|---|
| **Heightfield + repose (GranularPatch)** | Объём сохраняется; детерминизм; Jolt HeightMapShape3D; масштаб патча 8–32 м; lunar g в flow speed | Нет internal avalanching в 3D; не «настоящие» зёрна; overhangs только в SDF |
| **2D Falling Sand CA** | Богатая материаловая химия; проверенная производительность | 2D; не стыкуется с planetoid SDF без отдельного мира |
| **3D Voxel CA (per-cell loose)** | Физически честнее для шахт/пещер | 96³ @ 0.25 м = 884k cells; GDScript spike показывает budget ~4 ms/sweep — **дорого** |
| **GPUParticles3D** | Отличная пыль/струя из-под бура | Не коллизия для rover; cap 32 colliders |
| **RigidBody per grain/clump** | Такtility, Jolt stacking | Масштаб; не repose; sleep/wake артефакты |
| **Fake shaders only** | Дёшево; tracks, shimmer, dust | Нет gameplay (опора колёс, засыпание траншеи) |
| **SoftBody / PBD fluid** | — | Не granular; R&D months |

**Специфика луны:**
- Медленнее осыпание → heightfield с `FLOW_SPEED_COEFF × sqrt(g)` — правильная физическая эвристика (у Regolith уже есть)
- Bearing capacity ~kPa → gameplay sinkage, не mm-точность Apollo
- Bulking 10–25% → константа в spoil pipeline, не particle sim

---

## 4. Ссылки и references

### Документация Godot
- [3D Particles](https://docs.godotengine.org/en/stable/tutorials/3d/particles/index.html)
- [3D Particle collisions](https://docs.godotengine.org/en/stable/tutorials/3d/particles/collision.html)
- [Particle properties (Amount, Fixed FPS)](https://docs.godotengine.org/en/stable/tutorials/3d/particles/properties.html)
- [Compute shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html)
- [Using Jolt Physics](https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html)
- [Optimizing 3D performance (MultiMesh)](https://docs.godotengine.org/en/stable/tutorials/performance/optimizing_3d_performance.html)
- [GPUParticles collider limit #110860](https://github.com/godotengine/godot/issues/110860)

### Форумы Godot
- [Falling tiles like Terraria](https://forum.godotengine.org/t/how-to-implement-falling-tiles-like-the-sand-tiles-in-terraria/104534)
- [2D pixel sandbox display](https://forum.godotengine.org/t/best-way-to-display-a-2d-pixel-sandbox-simulation/53443)
- [Compute texture + render latency](https://forum.godotengine.org/t/how-to-compute-a-texture-using-compute-shader-and-then-render-it-on-main-screen/113208)
- [Fast erosion filter (heightfield)](https://forum.godotengine.org/t/fast-and-gorgeous-erosion-filter/136436)

### GitHub / itch.io / YouTube
- Sand Slide: [GitHub](https://github.com/kiwijuice56/sand-slide) · [itch.io](https://kiwijuice56.itch.io/sand-slide)
- Neon Sand: [GitHub](https://github.com/KunkelAlexander/neon-sand) · [Web demo](https://kunkelalexander.github.io/neon-sand/)
- GodotSand (C#): [GitHub](https://github.com/MathExpert/GodotSand)
- PixelDot plugin: [GitHub](https://github.com/Texnist/PixelDot)
- Cellular Automata Studio: [Asset Library](https://godotengine.org/asset-library/asset/2354)
- Voxel Tools: [GitHub](https://github.com/Zylann/godot_voxel)
- HTerrain: [GitHub](https://github.com/Zylann/godot_heightmap_plugin)
- Terrain3D: [GitHub](https://github.com/TokisanGames/Terrain3D)
- Anthill: [hromp.com/anthill](https://hromp.com/anthill/)
- Noita GDC: [YouTube](https://www.youtube.com/watch?v=prXuyMCgbTc)
- Jolt benchmarks: [StraySpark](https://www.strayspark.studio/blog/godot-46-jolt-physics-migration-guide)
- Godot physics benchmark video: [YouTube](https://www.youtube.com/watch?v=VtCViY9Ls2Q)

### Теория / блоги
- [Falling sand water simulation (w-shadow)](https://w-shadow.com/blog/2009/09/29/falling-sand-style-water-simulation/)
- [Making Sandspiel](https://maxbittker.com/making-sandspiel)
- [Procedural death animation via sand CA](https://pvigier.github.io/2020/12/12/procedural-death-animation-with-falling-sand-automata.html)

---

## 5. Что подходит для Regolith (voxel digging + loose material)

### Текущая архитектура проекта — правильный выбор

Regolith уже реализует **industry-standard hybrid**, описанный в `docs/specs/GRANULAR-V0.md`:

```text
Voxel SDF (скала)  →  terrain_carve
        ↓ removed volume
GranularSpoil       →  deposit_ring / heap на GranularPatch
        ↓
GranularPatch      →  thickness field + angle of repose + HeightMapShape3D
        ↓
Presentation         →  mesh + grit VFX + GranularSpoilBody (aim/drill target)
```

Ключевые инварианты, которых **нет** в типичных Godot sandbox-проектах:
- **разделение истины**: SDF ≠ loose material (SDF хранит distance, не mass)
- **локальные патчи** на сфере через `GranularAnchor` (нет global heightmap)
- **детерминизм** для коопа/replay
- **dig → spoil** через `GranularWorld` / `terrain_modified`

Spike `bench_granular_voxel_ca.gd` исследует 3D voxel CA как альтернативу height field — пока **не production path** из-за стоимости sweeps на 96³ сетке.

### Рекомендуемая стратегия (fake vs real)

| Слой | Подход | «Fake» или «Real» |
|---|---|---|
| Скальная порода | Voxel Tools SDF | Real (для формы) |
| Рыхлый материал (gameplay) | `GranularPatch` height field + repose | **Real enough** (volume, slope, bearing) |
| Spill между патчами | `spill_edge` → cascade | Semi-real |
| Пыль/струя из-под бура | GPUParticles3D / declarative VFX | Fake |
| Отдельные камни | единичные RigidBody3D (optional) | Real physics, rare |
| Per-grain 3D CA | не делать | — |

### Что **не** стоит тащить из экосистемы Godot

1. **Falling sand GDExtension (Sand Slide, Neon Sand)** — 2D CA; интеграция с planetoid SDF = второй мир
2. **Terrain3D / HTerrain** — flat heightmap terrain; конфликтует с Voxel Tools + сферой
3. **Thousands RigidBody «песка»** — даже Jolt 4.6 не спасёт масштаб
4. **Full Noita-style pixel sim** — нужен custom engine tier (см. форум: «maybe a different engine» для Noita-scale)

### Практичные улучшения поверх текущего пути

| Улучшение | Источник идеи | Effort |
|---|---|---|
| Dust/debris VFX при carve | GPUParticles3D + CollisionHeightField3D | Low |
| Следы колёс на spoil heap | SubViewport mask shader (snow tracks pattern) | Low–Med |
| Автосвязка патчей при spill | Anthill-style routing | Med |
| `SWELL_FACTOR` > 1.0 | geotechnics bulking | Low (константа) |
| GPU relax sweep | Compute shader на thickness buffer | High |
| Редкие clump RigidBody при avalanche | Jolt, freeze/sleep | Med |

### Сравнительная таблица: fake vs real granular physics

| Критерий | Fake (shader/VFX) | Regolith GranularPatch | Real (PBD/DEM/Rigid grains) |
|---|---|---|---|
| Угол откоса | Нет | Да (repose + stability margin) | Да |
| Сохранение объёма | Нет | Да | Да |
| Коллизия rover | Нет | HeightMapShape3D | Да, но дорого |
| Копка засыпает траншею | Нет | Да (thickness + base resample) | Да |
| Overhangs / 3D flow | Нет | Частично (spill_edge) | Полностью |
| Детерминизм коопа | — | Да | Сложно |
| CPU/GPU budget | ~0 | ~ms на патч | ×100–1000 |
| Lunar g | Визуально подкрутить | Встроено в flow speed | Нужен full sim |

---

## Итог

**Godot — сильный движок для voxel terrain + Jolt + VFX, но слабый для native granular mechanics.** Сообщество закрывает 2D falling sand через C++ GDExtension и compute CA; 3D loose soil почти нигде не решён «из коробки».

Для Regolith оптимален **гибрид, который проект уже выбрал**: твёрдое в SDF, рыхлое в локальных height-field патчах с углом откоса, визуальные зёрна/VFX поверх. Полноценная per-grain физика (Noita-in-3D) потребовала бы отдельного simulation kernel — это не задача «подключить addon», а months-long engine work без гарантии FPS на planetoid scale.

Если нужно — могу отдельно разобрать spike `GranularVoxelField` vs `GranularPatch` по цифрам из bench или составить decision matrix для v1 spill между патчами.

[REDACTED]
