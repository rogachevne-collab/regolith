# Jolt Physics в Godot 4.4+ для гранулярных/мягких материалов

## 1. Что Jolt может и не может для почвы/гранулярного материала

### Может (релевантно для игры)

| Возможность | Применимость к реголиту |
|---|---|
| **RigidBody3D** — сферы, боксы, convex hull, mesh, CCD, sleep | Одиночные камни, обломки, ящики на отвале — хорошо |
| **HeightMapShape3D / ConcavePolygonShape3D** как статика | Коллизия поверхности кучи — то, что уже делает `GranularPatch` |
| **SoftBody3D (XPBD)** — ткань, мягкий мяч, pressure, skinning | Только «мягкие» объекты с сеткой constraints, **не** сыпучий материал |
| **CharacterVirtual / Character** | Контроллер персонажа/ровера, не зёрна |
| **Масштаб rigid bodies** | В 3–6× быстрее GodotPhysics/Bullet на больших сценах (синтетика: ~1000 тел @ 60 fps, ~10 000 @ ~19 fps) |
| **Collision layers/masks** | Эмуляция «debris layer»: зёрна не сталкиваются друг с другом, только с миром |

### Не может (критично для грануляра)

| Ограничение | Следствие |
|---|---|
| **Нет DEM (Discrete Element Method)** | Нет физики сыпучих зёрен с rolling/twisting friction, полидисперсности, когезии |
| **Нет «character particles» в смысле DEM** | «Particles» в soft body — вершины mesh с constraints, не автономные зёрна |
| **SoftBody3D ≠ реголит** | Угол естественного откоса, перенос массы, усадка под нагрузкой — не emergent behavior |
| **GPUParticles3D ≠ PhysicsServer** | Частицы GPU не создают RigidBody, не участвуют в gameplay-физике |
| **Тысячи взаимодействующих RigidBody3D** | Даже на Jolt это ~10 fps при 10k тел с взаимными контактами; self-collision хуже |
| **Godot не экспонирует Jolt DEBRIS/BroadPhaseLayer API** | Оптимизация «debris vs static only» достигается вручную через collision mask, без отдельного broadphase tree |

**Вывод:** Jolt — отличный **rigid/soft-body** движок для игры, но **не симулятор гранулярной среды**. Для лунного реголита нужен отдельный слой симуляции (поле толщины, cellular automata, внешний DEM), а Jolt — для коллизий и твёрдых тел поверх этого.

---

## 2. Официальная документация и ключевые issues

### Godot (встроенный Jolt module, 4.4+)

- [Using Jolt Physics](https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html) — отличия от GodotPhysics, joint limits, Area3D+SoftBody3D, kinematic contacts, WorldBoundary limits
- [Using SoftBody3D](https://docs.godotengine.org/en/stable/tutorials/physics/soft_body.html) — рекомендация Jolt для soft body; нет physics interpolation
- [SoftBody3D class](https://docs.godotengine.org/en/stable/classes/class_softbody3d.html) — `apply_force`, pinned points, simulation precision
- [GPUParticles3D collision tutorial](https://docs.godotengine.org/en/stable/tutorials/3d/particles/collision.html) — GPU-частицы изолированы от физического мира

### JoltPhysics (библиотека)

- [Architecture & API](https://jrouwe.github.io/JoltPhysics/) — rigid bodies, constraints, **soft bodies (XPBD)**, collision layers, **DEBRIS layer pattern**
- [SoftBodySharedSettings](https://jrouwe.github.io/JoltPhysics/class_soft_body_shared_settings.html) — edge/volume/dihedral constraints, tetrahedra
- [Character / CharacterVirtual](https://jrouwe.github.io/JoltPhysicsDocs/5.1.0/class_character.html) — keyframed capsule controller, не DEM
- [GitHub JoltPhysics](https://github.com/jrouwe/JoltPhysics) — README, ReleaseNotes, PerformanceTest
- [Multicore scaling PDF](https://jrouwe.nl/jolt/JoltPhysicsMulticoreScaling.pdf)

### Legacy extension (maintenance mode)

- [godot-jolt/godot-jolt](https://github.com/godot-jolt/godot-jolt) — до feature parity с модулем; JoltHingeJoint3D и др.

### GitHub issues (Godot + Jolt)

| Issue | Тема |
|---|---|
| [#111993](https://github.com/godotengine/godot/issues/111993) | Area3D ↔ SoftBody3D (wind/gravity) — закрыто в 4.7 |
| [#114198](https://github.com/godotengine/godot/pull/114198) | PR: overlap signals для SoftBody3D + Area3D |
| [#909](https://github.com/godot-jolt/godot-jolt/issues/909) | SoftBody oscillation, sleep/pinned points |
| [#1026](https://github.com/godot-jolt/godot-jolt/issues/1026) | Wind/gravity на SoftBody3D (исторически) |
| [#106482](https://github.com/godotengine/godot/issues/106482) | Overlapping Area3D — тяжёлый overhead даже без monitoring |
| [#118047](https://github.com/godotengine/godot/issues/118047) | Продолжение проблемы Area3D overlap |
| [#95510](https://github.com/godotengine/godot/issues/95510) | GPUParticles3D collision imprecise at speed |
| [Discussion #1855](https://github.com/jrouwe/JoltPhysics/discussions/1855) | Изолированный broadphase layer не влияет на sim |

---

## 3. Community workarounds

### A. Heightfield / поле толщины (рекомендуемый путь для Regolith)

Логика вне физдвижка: сетка `thickness`, релаксация по углу откоса, `settle_load`, `HeightMapShape3D` для Jolt. **Истина объёма — в патче, не в RigidBody.** Это уже описано в `docs/specs/GRANULAR-V0.md`.

### B. Pseudo-granular через RigidBody3D

- Сферы/маленькие convex hull, **collision mask: зёрна ↔ мир, не зёрна ↔ зёрна**
- Sleep агрессивно; CCD выключен; `contact_monitor` off
- Практический потолок: **сотни–низкие тысячи** активных тел, не десятки тысяч
- [MultiNode-Plugin](https://github.com/AverageDrafter/MultiNode-Plugin): PhysicsServer3D без scene tree — 3000 cubes @ ~60 fps vs individual nodes @ ~10 fps

### C. Визуальные зёрна без физики

- `MultiMeshInstance3D` + шейдер grit на меше поля
- `GPUParticles3D` + `GPUParticlesCollisionHeightField3D` — только VFX (пыль, просыпь)
- Активные зёрна Regolith v0 явно **не влияют на объём/откос**

### D. Cellular automata / grid simulation

- Falling-sand на 2D/3D сетке (GDExtension для perf): [neon-sand](https://github.com/KunkelAlexander/neon-sand)
- Хорошо для «сыпучести», плохо для 3D rover на сфере без адаптации

### E. Внешний DEM (не для realtime gameplay)

- [Chrono::GPU](https://par.nsf.gov/biblio/10349475-chrono-gpu-open-source-simulation-package-granular-dynamics-using-discrete-element-method) — до 130M элементов на GPU
- EDEM, YADE-DEM, TinyDEM — офлайн/исследовательские задачи
- Co-simulation с Godot — только для pre-bake или редких cutscenes

### F. SoftBody3D как «грязь»

Теоретически blob из tetrahedra с pressure — на практике нестабильно, дорого, не даёт angle of repose. Для реголита **не подходит**.

---

## 4. Сравнение с другими движками для этого use case

| Движок | Грануляр / сыпучий | Debris / loose objects | Deformable (cloth/soil blob) | Интеграция с Godot |
|---|---|---|---|---|
| **Jolt (Godot 4.4+)** | ❌ нет DEM | ✅ лучший в экосистеме Godot | ✅ SoftBody3D (cloth-like) | ✅ native |
| **GodotPhysics3D** | ❌ | ⚠️ медленнее, менее стабилен | ⚠️ soft body слабее | ✅ default legacy |
| **Bullet (старый Godot)** | ❌ | ⚠️ jitter, tunneling | ⚠️ | ❌ заменён |
| **PhysX / Chaos (UE5)** | ❌ | ✅ | ✅ cloth + destruction | ❌ |
| **Chrono::GPU / EDEM / YADE** | ✅ настоящий DEM | — | ✅ | ❌ отдельный pipeline |
| **Custom heightfield (Regolith)** | ✅ angle of repose, volume conserve | через rigid поверх | N/A (не deformable mesh) | ✅ уже в проекте |

**Jolt vs Bullet для debris:** Jolt стабильнее (меньше ghost collisions, лучше stacking), быстрее в 3–6× на больших сценах, детерминированнее. Bullet не даёт преимущества для грануляра — у обоих нет DEM.

**Jolt soft body vs cloth engines:** Jolt XPBD — для mesh-based deformables (плащ, мяч). Не заменяет soil mechanics.

---

## 5. Рекомендации для лунных куч реголита (Regolith)

### Архитектура (согласована с GRANULAR-V0)

```
Voxel SDF (скала)          ← terrain_carve, неизменяемая основа
       ↓
GranularPatch (thickness)  ← истина объёма, angle of repose, settle_load
       ↓
HeightMapShape3D (Jolt)    ← коллизия поверхности кучи
       ↓
RigidBody3D (rover, box)   ← Jolt: контакт с heightfield, давление → settle
       ↓
Presentation grains/VFX    ← только глаз, не физика
```

### Do

1. **Оставить `GranularPatch` + heightfield** как единственный источник истины для куч, отвалов, осыпей.
2. **Jolt для всего rigid:** rover, инструменты, ящики на отвале, одиночные камни.
3. **`settle_load` + `density_scale`** для readablе усадки под колёсами/ящиками (уже в спеке).
4. **VFX/MultiMesh** для «живости» сыпучести при deposit/spill.
5. **Collision layers:** debris/chunks — mask «только static terrain», без inter-debris.
6. **Sleep + без CCD** для декоративных обломков.

### Don't

1. **Не моделировать кучу тысячами RigidBody3D** — ни angle of repose, ни volume conservation, ни perf.
2. **Не использовать SoftBody3D** для реголита — wrong material model.
3. **Не полагаться на GPUParticles3D** для gameplay-коллизий с ровером.
4. **Не ждать DEM в Jolt** — в roadmap нет; это сознательно game-oriented rigid/soft engine ([Horizon Forbidden West](https://github.com/jrouwe/JoltPhysics), [Death Stranding 2](https://github.com/jrouwe/JoltPhysics)).

### Опциональные улучшения поверх v0

| Улучшение | Стоимость | Эффект |
|---|---|---|
| Spherical rigid «chunks» при крупном carve (10–50 шт.) | Низкая | Драматичный spill без DEM |
| MultiNode/PhysicsServer batch для chunks | Средняя | +2–3× больше debris-тел |
| GPU compute heightfield relax (будущее) | Высокая | Больше патчей одновременно |
| Offline DEM pre-bake траекторий | Очень высокая | Только cinematics |

### Performance anchors (Jolt + Godot, синтетика)

| Сценарий | ~FPS |
|---|---|
| 1 000 rigid boxes, ground | 60 |
| 5 000 boxes | ~38 |
| 10 000 boxes | ~19 |
| 3 000 cubes self-collision, MultiNode | ~60 |
| 3 000 individual RigidBody3D nodes | ~10 |

Для **лунного реголита** реалистичный бюджет физики: **0 rigid grains** (heightfield truth) + **десятки** rigid props/chunks + **1 heightfield на патч**.

---

## Краткий вердикт

**Jolt в Godot — правильный выбор для rigid-взаимодействий (ровер на отвале, ящик на куче, обломки), но не замена DEM или soil mechanics.** Для Regolith текущий путь (`GranularPatch` + Jolt heightfield + presentation grains) — индustry-standard game dev workaround, а не компромисс из-за слабости Jolt: **ни один mainstream game physics engine не делает настоящий грануляр в realtime**. Jolt здесь — транспорт коллизий и твёрдых тел, не симулятор сыпучки.

[REDACTED]
