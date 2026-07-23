# Connected Block Visual PoC

Статус: presentation PoC. `frame` (0.5 m) — art mesh
`scenes/presentation/base_block_05m_visual.tscn` + PBR
`resources/materials/sci_fi_panel1.tres`. Procedural rim-рамки
временно выключены (`ConnectedBlockVisual.RIMS_ENABLED = false`),
код `make_rim_mesh` / `_add_face_rim` сохранён.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` (Element, Unified grid 0.5 m);
- `docs/specs/CONSTRUCTION-V1.md` (`frame`, `large_frame`).

## Цель

Кубические каркасы одного archetype визуально стыкуются без зазора, как
connected armor в Space Engineers: на свободных краях грани — procedural-рамка,
на соприкасающихся гранях рамочка и сама грань пропадают.

## Scope

| Archetype | Envelope | Merge family |
|---|---|---|
| `frame`, `frame_basalt` | 0.5³ m (1 cell) | только свой `archetype_id` |
| `large_frame` | 2.5³ m (5³ cells) | только `large_frame` |

Не трогаем: beam/foundation/machines, physics colliders, topology.

## Контракт

1. Visual scale = **1.0** (без `0.96` gap) для участников PoC.
2. Соседство считается по assembly occupancy: грань полностью закрыта, если
   каждая наружная footprint-cell этой грани имеет соседа того же
   `archetype_id` (другой element).
3. Рисуются только **открытые** грани (occlusion mask, 6 бит).
4. Геометрия — **face-panel**, не edge-cage:
   - на каждой открытой грани: inset fill + rim-полоски по краям + corner pads;
   - rim-полоска на ребре грани рисуется, если **обе** смежные грани куба открыты
     (silhouette merge: стык двух блоков убирает рамку на шве);
   - уголки рамки обязательны (нет gaps на углах куба).
5. Geometry contract (Godot 4):
   - front face = **clockwise** при взгляде снаружи;
   - нормали вершин = outward explicit; **не** вызывать `SurfaceTool.generate_normals()`;
   - лёгкий outward bias (`FACE_BIAS_M`) против z-fight с чужим archetype.
6. Рамка — procedural mesh на плоскости грани, без текстур.
7. Preview в руках: тот же exact-size fill + полная рамка (соседей ещё нет).

## Не владеет

Симуляция / joints / derived surfaces — без изменений. Это только
`ElementVisualProjection` (+ preview).

## Верификация

- Headless: `test_connected_block_visual` (маска, число граней/рёбер, winding/normals,
  покрытие углов рамкой).
- В игре: поставить два `frame` / два `large_frame` в ряд —
  шов без рамки и без щели; одиночный блок — все 6 граней видны, рамка замкнута
  по периметру (12 рёбер / 8 углов); обход вокруг блока не показывает «дырявых» ±Z.
