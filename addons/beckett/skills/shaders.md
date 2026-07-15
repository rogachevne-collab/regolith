# Shaders (GDShader) — write GLSL-like shaders, wrap in a ShaderMaterial

> A `Shader` (text code) goes in a `ShaderMaterial.shader`, assigned to a node's material slot. First line is `shader_type`; set uniforms from outside via `set_shader_parameter`.

GDShader is a GLSL-like language. The code lives in a `Shader` resource's `code` (String); a `ShaderMaterial` runs it and holds per-material uniform values; that material is assigned to `CanvasItem.material` (2D) or `GeometryInstance3D.material_override` (3D).

## Version note
- **4.0** overhauled the language: GLSL-like syntax, `hint_color`/`hint_albedo` → **`source_color`**; `SCREEN_TEXTURE`/`DEPTH_TEXTURE`/`NORMAL_ROUGHNESS` **removed** → declare `uniform sampler2D` with `hint_screen_texture` / `hint_depth_texture` / `hint_normal_roughness_texture`, sampled via `SCREEN_UV`. `TIME`/`PI`/`TAU`/`E`, global & instance uniforms, `shader_type fog`, fragment→light varyings all added in 4.0.
- **4.4** pipeline precompilation/ubershaders (kills first-use compile stutter). **4.5** Shader Baker + spatial stencil buffer. **4.6** SSR rewrite (half-res default; runtime is 4.6.2).
- **4.7**: live **inline preview** in the text shader editor (editor-only QoL, no API change); `BaseMaterial3D` clearcoat refined toward Disney PBR (`clearcoat`/`clearcoat_roughness` unchanged — just better-looking output).
- Baseline 4.3+. Confirm with `get_godot_version` / `describe_class class=ShaderMaterial`.

## Key classes
- **`Shader`** (`Resource`): `code` (String). `get_mode() -> Shader.Mode` (derived from `shader_type`); `set_default_texture_parameter(name: StringName, texture: Texture, index := 0)`, `get_default_texture_parameter(name, index := 0)`, `get_shader_uniform_list()`.
- **`ShaderMaterial`** (`Material`): `shader` (Shader). `set_shader_parameter(param: StringName, value)` / `get_shader_parameter(param) -> Variant`. Param names are **CASE-SENSITIVE**; a typo silently no-ops.
- **`VisualShader`** (extends `Shader`): node-graph alternative. `set_mode(Shader.Mode)`, `add_node(type, node, position, id)`, `connect_nodes(type, from, from_port, to, to_port)`. `Type` enum: `TYPE_VERTEX, TYPE_FRAGMENT, TYPE_LIGHT, TYPE_START, TYPE_PROCESS, TYPE_COLLIDE, TYPE_START_CUSTOM, TYPE_PROCESS_CUSTOM, TYPE_SKY, TYPE_FOG`.

`Shader.Mode`: `MODE_SPATIAL=0, MODE_CANVAS_ITEM=1, MODE_PARTICLES=2, MODE_SKY=3, MODE_FOG=4` — implied by the `shader_type` line, not set separately for a text shader.

## shader_type (mandatory first line)
`canvas_item` (2D), `spatial` (3D), `particles`, `sky`, `fog`. Determines which built-ins/processor functions exist (`fragment`/`vertex`/`light`; `start`/`process`; `sky`; `fog`). `render_mode ...;` (comma-separated flags) goes on the next line(s).

## Uniforms & hints
- Qualifiers: `const`, `varying`, `uniform`, `global uniform`, `instance uniform` (max 16/shader, no textures/arrays).
- General hints: `source_color` (use for ALL color uniforms — sRGB→linear), `hint_range(min,max[,step])`, `hint_enum("A","B")`.
- sampler2D: `hint_normal`, `hint_default_white/_black/_transparent`, `hint_roughness_*`, `source_color`; filter `filter_nearest|linear[_mipmap][_anisotropic]`; repeat `repeat_enable|repeat_disable`; screen/buffer `hint_screen_texture` (2D+3D), `hint_depth_texture`, `hint_normal_roughness_texture` (Forward+ only).

## Required setup
- **Renderer matters** (Project Settings > Rendering > Renderer): Forward+ supports everything; Mobile/Compatibility have reduced screen/depth/normal-roughness support.
- `shader_type` must match the node family: 2D → `CanvasItem.material`; 3D → `GeometryInstance3D.material_override` or a mesh surface material.
- `particles` shaders need a `GPUParticles2D/3D` with `process_material` = a ShaderMaterial (CPUParticles unsupported). `fog` needs `Environment.volumetric_fog_enabled = true` + Forward+. `sky` needs WorldEnvironment → Environment (`background_mode = Sky`) → `Sky.sky_material`. `global uniform` must be declared in Project Settings > Shader Globals, then `RenderingServer.global_shader_parameter_set(name, value)`.

## Recipe — tinted Sprite2D (canvas_item)
```
create_node type=Sprite2D name=Fx parent=<root>
set_property target=Fx property=texture value=res://icon.svg
set_resource target=Fx property=material class=ShaderMaterial
set_resource target=Fx:material property=shader class=Shader
set_property target=Fx:material property=code value="shader_type canvas_item;
uniform vec4 tint : source_color = vec4(1.0, 0.4, 0.2, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.5;
void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    COLOR = vec4(mix(tex.rgb, tint.rgb, strength), tex.a);
}"
# set a uniform at runtime — two equivalent ways:
call_method target=Fx:material method=set_shader_parameter args=["strength", 0.8]
set_property target=Fx:material property=shader_parameter/strength value=0.8
play_scene  # then screenshot to confirm the tint renders
```
For 3D, swap `Sprite2D`→`MeshInstance3D`, `material`→`material_override`, `shader_type canvas_item`→`spatial`. Screen effects: cover the viewport with a `ColorRect`, declare `uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;` and sample `textureLod(screen_tex, SCREEN_UV, 0.0)`.

## Common traps
- **First-line rule:** must start with `shader_type <type>;`. Wrong type means expected built-ins (`UV`, `NORMAL`, `VIEW`, `ALBEDO`) don't exist.
- **No `SCREEN_TEXTURE`/`DEPTH_TEXTURE`/`NORMAL_ROUGHNESS`** (removed 4.0) — use the `hint_*_texture` uniforms above.
- **`hint_color`/`hint_albedo` gone** → `source_color`. Color uniforms without it look washed out (sRGB mishandled).
- **Uniforms don't animate themselves** — declaring just exposes them; change at runtime via `set_shader_parameter` (or AnimationPlayer / per-frame `set_property`).
- **2D `modulate` is now the INPUT** to the canvas_item shader (arrives in `COLOR` before `fragment`); what you write to `COLOR` is final, not multiplied after (4.0 change).
- **`light()` differs by family** — spatial uses `DIFFUSE_LIGHT`/`SPECULAR_LIGHT` (+= accumulate), `LIGHT`, `ATTENUATION`; canvas_item uses `LIGHT` (vec4 inout) per Light2D. Don't mix them.
- **instance uniforms** set via `set_instance_shader_parameter(name, value)` on the node, NOT `set_shader_parameter`.
- **MCP `write_script` validates GDScript, not GDShader.** Shader code is a `Shader.code` string — set it via `set_property target=<mat>:shader property=code value="..."`, then `play_scene` + `screenshot` to verify it compiled and renders.

Always confirm exact class/property/method names with `describe_class` (e.g. `class=ShaderMaterial`, `class=Shader`) before relying on them.
