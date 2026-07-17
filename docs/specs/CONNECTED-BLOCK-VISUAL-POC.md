# Connected Block Visual PoC

Статус: presentation PoC (без арт-ассетов).

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` (Element, Unified grid 0.5 m);
- `docs/specs/CONSTRUCTION-V1.md` (`frame`, `large_frame`).

## Цель

Кубические каркасы одного archetype визуально стыкуются без зазора, как
connected armor в Space Engineers: на свободных рёбрах — procedural-рамка, на
соприкасающихся гранях рамочка и сама грань пропадают.

## Scope

| Archetype | Envelope | Merge family |
|---|---|---|
| `frame`, `frame_basalt`, `rover_frame` | 0.5³ m (1 cell) | только свой `archetype_id` |
| `large_frame` | 2.5³ m (5³ cells) | только `large_frame` |

Не трогаем: beam/foundation/machines, physics colliders, topology.

## Контракт

1. Visual scale = **1.0** (без `0.96` gap) для участников PoC.
2. Соседство считается по assembly occupancy: грань полностью закрыта, если
   каждая наружная footprint-cell этой грани имеет соседа того же
   `archetype_id` (другой element).
3. Рисуются только **открытые** грани (occlusion mask, 6 бит).
4. Ребро куба с рамкой рисуется, если **обе** смежные грани открыты
   (silhouette merge: стык двух блоков убирает рамку на шве).
5. Рамка — procedural mesh (тонкий бокс по ребру), без текстур.
6. Preview в руках: тот же exact-size fill + полная рамка (соседей ещё нет).

## Не владеет

Симуляция / joints / derived surfaces — без изменений. Это только
`ElementVisualProjection` (+ preview).

## Верификация

- Headless: `test_connected_block_visual` (маска + число граней/рёбер).
- В игре: поставить два `frame` / два `large_frame` / два `rover_frame` в ряд —
  шов без рамки и без щели; одиночный блок — рамка по всем 12 рёбрам.
