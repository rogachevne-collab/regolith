# Шпаргалка: декларативный VFX (.tscn)

> Выжимка паттерна из Erebus ADR-0019, адаптированная для pure Godot Regolith.
> Дизайн-принципы: [`vfx-design.md`](vfx-design.md).

## Идея

Составной эффект — **текстовая Godot-сцена** без геймплейной логики. Скрипт
спавнит `PackedScene`, один раз «заряжает» материалы и частицы, удаляет по таймеру
или когда родитель исчезает.

```
scenes/vfx/
  drill_sparks.tscn      # one-shot burst при ударе
  regolith_dust.tscn     # пылевое облако
  thrust_plume.tscn      # выхлоп
```

## Контракт `.tscn`

- **Корень** — `Node3D`.
- **Metadata** на корне: `vfx_duration` (`float > 0`) — полная длительность от
  anticipation до конца dissipate. Спавнер согласует `queue_free` с этим значением.
- **Без скриптов** на нодах композиции. Исключение — общий spawner/helper вне
  `scenes/vfx/`, не внутри reusable-композиции.
- **Материалы** — через `material_override` или surface materials; параметры в `.tres`.
- **`GPUParticles3D`** для burst: `one_shot = true`; spawner вызывает `restart()` и
  `emitting = true` после инстанцирования.
- **Не полагайся на `_ready()`** для автозапуска — эффект должен корректно
  переигрываться при каждом spawn.

## Шейдер с возрастом экземпляра

```glsl
uniform float born_at = 0.0;

void fragment() {
    float age = mod(TIME - born_at + 3600.0, 3600.0);
    // Кривые эффекта вычисляются из age.
}
```

`born_at` — presentation-время, не gameplay. Не используй для урона, hit detection
или длительности игрового события.

## Spawner (минимальный паттерн)

```gdscript
func spawn_vfx(scene: PackedScene, at: Transform3D, parent: Node3D) -> Node3D:
    var fx: Node3D = scene.instantiate()
    parent.add_child(fx)
    fx.global_transform = at
    var born := Time.get_ticks_msec() / 1000.0
    _prime_vfx(fx, born)
    var duration: float = fx.get_meta("vfx_duration", 1.0)
    get_tree().create_timer(duration).timeout.connect(fx.queue_free)
    return fx


func _prime_vfx(root: Node, born_at: float) -> void:
    if root is GPUParticles3D and root.one_shot:
        root.restart()
        root.emitting = true
    if root is MeshInstance3D:
        var mat := root.material_override as ShaderMaterial
        if mat and mat.shader and mat.shader.get_shader_uniform_list().any(
            func(u): return u.name == "born_at"
        ):
            mat = mat.duplicate() as ShaderMaterial
            mat.set_shader_parameter("born_at", born_at)
            root.material_override = mat
    for child in root.get_children():
        _prime_vfx(child, born_at)
```

Spawner может жить в `scripts/vfx_spawner.gd` или inline в gameplay-скрипте (бур,
vehicle). **Композиция `.tscn` остаётся декларативной.**

## Правила времени жизни

| Кто решает | Что |
|------------|-----|
| Gameplay-скрипт | когда spawn, позиция, ориентация, `queue_free` / timer |
| `.tscn` + metadata | как выглядит, `vfx_duration` для согласования |
| Не `.tscn` | hit detection, урон, физика |

Длительность частиц внутри сцены ≤ `vfx_duration`. Если частицы затухают раньше —
нормально; если дольше — визуальный артеfact при раннем `queue_free`.

## Camera shake

Тряска камеры — **отдельно** от VFX-сцены. Не встраивай `Camera3D` в `scenes/vfx/`.
Gameplay вызывает короткий impulse на камеру игрока (amplitude, duration, frequency).

## Чеклист перед merge

- [ ] `.tscn` открывается в редакторе без missing resources
- [ ] `./run.sh --headless res://scenes/main.tscn` — шейдеры компилируются
- [ ] Эффект читается на лунном фоне (не только на сером)
- [ ] One-shot не оставляет emitting-частиц после `vfx_duration`
- [ ] ≤ 2 `GPUParticles3D`, ≤ 128 частиц/система (см. бюджеты в `vfx-design.md`)
- [ ] Нет скриптов внутри `scenes/vfx/*.tscn`

## Связанные документы

- [`vfx-design.md`](vfx-design.md) — ритм, силуэт, бюджеты
- [`godot-shaders.md`](godot-shaders.md) — синтаксис `.gdshader`
- [`../PHYSICAL-LANGUAGE.md`](../PHYSICAL-LANGUAGE.md) — домен машин и контактов
