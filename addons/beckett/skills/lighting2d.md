# 2D lighting & shadows — light, occlude, and darken the canvas

> PointLight2D/DirectionalLight2D + LightOccluder2D for shadows + CanvasModulate for night. Lights are additive — darken the scene to see them.

2D lights only ever **brighten** by default (`BLEND_MODE_ADD`). Add a dark `CanvasModulate` so additive lights "reveal" the scene, and add `LightOccluder2D` nodes so `shadow_enabled` actually does something.

## Version note
- **`Light2D` is the base class** for 2D lights; in the editor you add the concrete `PointLight2D` or `DirectionalLight2D`, not `Light2D` itself.
- **Godot 4.0:** the 3.x `Light2D` node was renamed → **`PointLight2D`** (the 4.0 upgrade tool auto-renames it). **`DirectionalLight2D`** is new in 4.0 (no 3.x equivalent). **`CanvasTexture`** (diffuse/normal/specular bundle) is the new 4.x normal-map workflow, replacing 3.x's per-Sprite `normal_map`.
- **Godot 4.2:** project setting `rendering/viewport/hdr_2d` (HDR 2D) added — lets over-bright (>1.0) light/modulate values show. Only effective with the **Forward+ or Mobile** renderer; not in Compatibility (and more limited on Mobile). Basic LDR lighting/shadows work in all three renderers.
- **Godot 4.3:** `TileMapLayer` replaced `TileMap`; tile shadows are authored via a TileSet **Occlusion Layer** (per-tile occlusion polygons) instead of `LightOccluder2D` nodes.

Verified against stable + /en/4.4 class refs; no renames/deprecations for these classes 4.0→4.4. Confirm live with `get_godot_version` / `describe_class`.

## Classes
- **`PointLight2D`** (Node2D ← Light2D) — torch/lamp/glow. `texture` (Texture2D, **required** — invisible without it), `texture_scale` (float, 1.0), `offset` (Vector2; moves the **texture only**, not the shadow), `height` (float, 0.0).
- **`DirectionalLight2D`** (Node2D ← Light2D) — sun/moon parallel rays; direction = node **rotation**, not position. `max_distance` (float, 10000.0; shadow cull range in px, ignores camera zoom), `height` (float, 0.0; normal-map only).
- **`LightOccluder2D`** (Node2D) — casts shadows. `occluder` (OccluderPolygon2D), `occluder_light_mask` (int, 1), `sdf_collision` (bool, true).
- **`OccluderPolygon2D`** (Resource) — `polygon` (PackedVector2Array), `closed` (bool, true), `cull_mode` (CullMode, 0).
- **`CanvasModulate`** (Node2D) — `color` (Color, white). Only **one** affects a canvas; use separate CanvasLayers for independent tints.
- **`CanvasTexture`** (Texture2D) — `diffuse_texture`/`normal_texture`/`specular_texture` (Texture2D), `specular_color` (Color, white), `specular_shininess` (float, 1.0). 2D only.

## Shared Light2D properties (on both lights)
`enabled` (bool, true), `editor_only` (bool, false), `color` (Color, white), `energy` (float, 1.0 — animate for flicker), `blend_mode` (BlendMode, 0=ADD), `shadow_enabled` (bool, false), `shadow_color` (Color, transparent black), `shadow_filter` (ShadowFilter, 0), `shadow_filter_smooth` (float, 0.0), `range_item_cull_mask` (int, 1 — which CanvasItems are LIT, vs their `light_mask`), `shadow_item_cull_mask` (int, 1 — which occluders CAST, vs `occluder_light_mask`), `range_z_min/max`, `range_layer_min/max`.

> **Setter ≠ property name** — prefer `set_property` on the property name. Direct setters: `range_item_cull_mask`→`set_item_cull_mask`, `shadow_item_cull_mask`→`set_item_shadow_cull_mask`, `shadow_filter_smooth`→`set_shadow_smooth`, `range_layer_min/max`→`set_layer_range_min/max`, `range_z_min/max`→`set_z_range_min/max`, `offset`→`set_texture_offset`.

## Enums
- **`Light2D.BlendMode`**: `ADD=0` (default), `SUB=1` (negative light), `MIX=2`.
- **`Light2D.ShadowFilter`**: `NONE=0` (hard, fastest — best for pixel art), `PCF5=1`, `PCF13=2` (softest).
- **`OccluderPolygon2D.CullMode`**: `CULL_DISABLED=0` (self-shadows!), `CULL_CLOCKWISE=1`, `CULL_COUNTER_CLOCKWISE=2` (standard: cast outward only).
- **`CanvasItemMaterial.LightMode`**: `NORMAL=0`, `UNSHADED=1` (ignores lights + CanvasModulate), `LIGHT_ONLY=2`.
- **`CanvasItemMaterial.BlendMode`**: `MIX=0`, `ADD=1` (cheap fake-light sprite — can't cast shadows), `SUB=2`, `MUL=3`, `PREMULT_ALPHA=4`. (Note: ADD=1 here vs ADD=0 on Light2D.)

## Required setup
- No project setting needed for basic lighting/shadows — works out of the box in all three renderers.
- **To see lights:** add a dark `CanvasModulate` (lights are additive; without darkening they wash out a lit scene).
- **For shadows:** need BOTH `light.shadow_enabled = true` AND ≥1 `LightOccluder2D` with an `OccluderPolygon2D` in the scene.
- **For over-bright values:** enable `rendering/viewport/hdr_2d` (4.2+, Forward+/Mobile only).
- **Masks:** match light `range_item_cull_mask` ↔ sprite `light_mask` to control what's lit; light `shadow_item_cull_mask` ↔ `occluder_light_mask` to control what casts.

## Recipe — night scene: dark ambient + a torch
```
create_node type=CanvasModulate name=Ambient parent=/root/World
set_property target=Ambient property=color value="0.14 0.16 0.23 1"     # dark blue night
create_node type=PointLight2D name=Torch parent=/root/World
set_resource target=Torch property=texture class=GradientTexture2D       # then set its fill=1 (radial), white→transparent gradient; ~256px sets radius
set_property target=Torch property=energy value=1.2
set_property target=Torch property=color value="1.0 0.85 0.6 1"          # warm flame
```

## Recipe — make a wall cast a hard shadow
```
set_property target=Torch property=shadow_enabled value=true
set_property target=Torch property=shadow_filter value=0                  # SHADOW_FILTER_NONE (crisp)
create_node type=LightOccluder2D name=WallOccluder parent=/root/World/Wall
set_resource target=WallOccluder property=occluder class=OccluderPolygon2D
# resolve the OccluderPolygon2D, then:
set_property target=<the OccluderPolygon2D> property=polygon value="[-16 -16, 16 -16, 16 16, -16 16]"
set_property target=<the OccluderPolygon2D> property=cull_mode value=2    # CULL_COUNTER_CLOCKWISE — no self-shadow
# masks: Torch.shadow_item_cull_mask & WallOccluder.occluder_light_mask must share a bit (both default 1)
```

## Common traps
- A `PointLight2D` with **no texture is invisible** — assign one (commonly a radial `GradientTexture2D`); its pixel size × `texture_scale` = lit radius.
- `shadow_enabled` alone does nothing — needs `LightOccluder2D` nodes with `OccluderPolygon2D` shapes.
- `OccluderPolygon2D` default `cull_mode = CULL_DISABLED` makes objects **self-shadow** (permanently dark). Use `CULL_COUNTER_CLOCKWISE (2)`.
- `PointLight2D.offset` moves only the light texture; shadows always cast from the **node position**.
- Normal maps make lights look weaker — raise the light's `height` and `energy` to compensate.
- Without a `CanvasModulate`, an additive light just brightens an already-visible scene — no "darkness revealed" look.
- A light "not hitting" a sprite is often a `range_z_min/max` / `range_layer_min/max` / mask mismatch, not a position issue.
- `DirectionalLight2D.max_distance` ignores camera zoom — shadows can fade early when zoomed in; `height` affects normal-map shading only, not shadows.
- Items with `CanvasItemMaterial.light_mode = UNSHADED` ignore lights AND CanvasModulate — handy for a glowing player/HUD in darkness.

Always confirm exact class names, property types, and setter signatures with `describe_class` / `find_methods` before relying on them.
