# Шпаргалка: Godot shading language (отличия от GLSL)

> Синтаксис ~90% GLSL. Ниже — то, из-за чего LLM обычно ошибаются.
> Дизайн, композиция и цикл проверки эффектов: [`vfx-design.md`](vfx-design.md).

## Каркас файла (.gdshader)

```glsl
shader_type spatial;              // spatial | canvas_item | particles | sky | fog
render_mode unshaded, cull_back;  // опционально

uniform vec4 tint : source_color = vec4(1.0);
uniform sampler2D tex : source_color;

void vertex()   { /* VERTEX, NORMAL, UV ... */ }
void fragment() { ALBEDO = tint.rgb; /* + ROUGHNESS, METALLIC, EMISSION, ALPHA */ }
```

## Ключевые отличия от GLSL

- Нет `main()` — функции `vertex()`, `fragment()`, `light()`.
- Выход не `gl_FragColor`, а встроенные: `ALBEDO`, `ALPHA`, `EMISSION`,
  `ROUGHNESS`, `METALLIC` (spatial); `COLOR` (canvas_item).
- Встроенные входы: `UV`, `VERTEX`, `NORMAL`, `TIME`, `SCREEN_UV`,
  `FRAGCOORD`; в canvas_item — `TEXTURE`, `UV`.
- Uniform-хинты через `:` — `source_color`, `hint_range(0, 1)`,
  `hint_default_black` и т.п.
- Screen-текстура: не `SCREEN_TEXTURE`-переменная (устарело в 4.x), а
  `uniform sampler2D screen_tex : hint_screen_texture;` + чтение по `SCREEN_UV`.
- Типы как в GLSL (vec2/3/4, mat3/4), но литералы float обязательны: `1.0`, не `1`.
- Инстансные данные: `instance uniform`.

## Правила проекта

1. VisualShader-графы не создавать: шейдеры пишутся текстом (`.gdshader`).
   (Если человек создал граф в редакторе — он хранится в текстовом `.tres`,
   читать можно, но новые эффекты — только код.)
2. После правок: headless-компиляция через Godot. Минимум — загрузка сцены,
   которая использует шейдер:

   ```bash
   ./run.sh --headless res://scenes/main.tscn
   ```

   Ошибки компиляции шейдера появятся в stdout/stderr. Чинить до чистого прохода.
3. Частицы для VFX: предпочтительно `GPUParticles3D` с `process_material` в `.tres`,
   параметры — текстом в ресурсе.
4. Материалы — текстовые `.tres` (`StandardMaterial3D`, `ShaderMaterial`).

## Regolith-специфика

- **Terrain:** `resources/transvoxel_terrain.gdshader` — triplanar + SDF mesh.
  Не ломай uniform'ы, на которые ссылается `terrain_material*.tres`.
- **VFX:** искры бура, пыль, выхлоп — см. [`vfx-authoring.md`](vfx-authoring.md).
- **Jolt + spatial:** collider mesh terrain может отставать от SDF на 1–2 кадра;
  для contact-эффектов опирайся на physics raycast (как в `scripts/drill.gd`).
