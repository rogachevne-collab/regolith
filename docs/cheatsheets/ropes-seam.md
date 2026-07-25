# Ropes! — шов с плагином

`addons/ropes/` — **чужой код**. Плагин живёт в собственном репозитории
`Y:\ropes` и приходит сюда junction'ом; гит Regolith его не видит, агенты
Regolith в него не заходят. Эта шпаргалка существует ровно за тем, чтобы
забор не превращался в тупик: здесь то, на что игра опирается, переписанное
на игровую сторону.

**Баг в верёвках — задача в `Y:\ropes`, а не правка на месте.** Правка «здесь
по-быстрому» уедет в чужой репозиторий незамеченной: junction прозрачен,
`git status` Regolith про неё промолчит.

## Кто в игре трогает плагин

| Файл | Что берёт |
|---|---|
| `scripts/simulation/projection/xpbd_cable_rope_solver.gd` | **боевой путь.** `core/xpbd_rope.gd` + `core/rope_colliders.gd` |
| `scripts/bench/rope_bench_xpbd_adapter.gd` | `core/xpbd_rope.gd`, `bench/rope_bench.gd` |
| `scripts/bench/run_rope_bench.gd` | `bench/rope_bench.gd` |

Всё — по `preload` пути. Единственное глобальное имя, которое плагин заводит,
это `Rope3D` (Node3D-нода), и игра им **не пользуется**: архитектура проекции
не принимает ноду, поэтому кабели идут в ядро напрямую через фасад
`XpbdCableRopeSolver`.

Отсюда правило: **менять сигнатуры `core/` в `Y:\ropes` — значит проверить
фасад.** Тесты плагина этого не поймают, они ядро и проверяют.

## `core/xpbd_rope.gd` — то, чем пользуется игра

RefCounted, чистая математика над `PackedVector3Array` / `PackedFloat64Array`.

Сборка и топология:

```
setup(segment_count: int, total_length: float, mass_per_meter: float)
lay_line(a: Vector3, b: Vector3, jitter := 0.0)
set_rest_length(total_length: float)      rest_length()  segment_rest_length()  segment_count()
pin(index)  is_pinned(index)  move_pin(index, to, velocity := ZERO)
add_point_mass(index, extra_kg)
attach_proxy(index, effective_mass)  is_proxy(index)
seat_proxy(index, position, velocity)  reseat_proxy(index, position)  proxy_momentum(index)
teleport(delta)  apply_impulse(index, impulse)
```

Тик и съём:

```
step(dt)
max_speed()  total_polyline_length()  center_of_mass()
pin_reaction_force(index)  pin_reaction_impulse(index)  endpoint_tension_n()
```

Состояние наружу (читается напрямую, не через геттеры):
`positions`, `prev_positions`, `velocities`, `inv_mass`, `rest_lengths`,
`lambdas` (накоплены внутри субшага, ≤ 0), `tensions` (Н, с последнего субшага).

Тюнеры: `gravity`, `stretch_compliance` (м/Н), `damping` (1/с, внутреннее
трение волокна), `drag`, `radius`, `friction`, `substeps`, `iterations`,
`colliders` (`Array[Dictionary]`), `local_planes` (`PackedVector4Array`).

## `core/rope_colliders.gd` — статика широкой фазы

```
SHAPE_PLANE = 0   xform.basis.y = нормаль, xform.origin = точка
SHAPE_SPHERE = 1  params.x = радиус
SHAPE_BOX = 2     params = полуразмеры
NO_CONTACT  NO_PLANE

gather_from_space(...)      сбор коллайдеров из PhysicsDirectSpaceState3D
sample_local_planes(...)    по одной контактной плоскости на частицу — путь для
                            вогнутой/воксельной геометрии (ADR 0006, срез 2)
cull(colliders, positions, ...)   interpolate(colliders, t, ...)
probe(shape, params, xf, ...)     surface_velocity(col, xf, p)
body_rids(colliders)
```

Почему у кабеля две маски: `COLLISION_MASK = 3` для аналитических форм,
`TERRAIN_COLLISION_MASK = 1` для коры. Кэш плоскостей живёт между тиками, а это
верно только для геометрии, которая не движется: плоскость, снятая с борта
ровера, хранится в мировых координатах и врёт в тот же миг, когда ровер
сдвинулся. Поверхности машин идут через аналитический проход.

## Известные долги на шве

- `scripts/bench/rope_bench_xpbd_adapter.gd` содержит **ручную копию**
  `Rope3D._gather_colliders` (его собственный комментарий это признаёт). После
  переезда это расхождение между репозиториями. Чинится со стороны плагина —
  когда `Rope3D` начнёт отдавать сбор коллайдеров наружу.
- Сигналов в плагине нет вообще (записано в его ROADMAP). Всё, что игре нужно
  знать про верёвку, она спрашивает опросом.
- `length` у `Rope3D` — холодный: смена пересевает верёвку и теряет движение.
  Боевой кабель этим не пользуется, лебёдка живёт в фасаде.
