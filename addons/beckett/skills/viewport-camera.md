# Viewports, cameras & layers — frame the world, pin the HUD, render to texture

> Camera2D framing/zoom/limits/smoothing, CanvasLayer for camera-independent UI, SubViewport for minimaps/render-to-texture, Parallax2D for backgrounds.

## Version note
- **Camera2D.current is GONE in 4.x** — use `enabled` (bool, default true) + `make_current()` / `is_current()`. The first enabled Camera2D in the tree wins; call `make_current()` to force.
- **zoom inverted in 4.0**: `zoom > 1` zooms IN (magnify), `zoom < 1` zooms OUT (see more). `zoom=(2,2)` = 2x bigger.
- Smoothing props renamed in 4.0: `smoothing_enabled`→`position_smoothing_enabled`, `smoothing_speed`→`position_smoothing_speed`; added `rotation_smoothing_enabled/_speed`.
- `Viewport.get_camera()` split in 4.0 → `get_camera_2d()` / `get_camera_3d()`.
- **SubViewport** is its own class as of 4.0 (distinct from the Window-backed root Viewport).
- **Parallax2D added 4.3** (was experimental in 4.3) — recommended over `ParallaxBackground`/`ParallaxLayer`, which are deprecated (still functional through 4.6).

Confirm with `get_godot_version` / `describe_class`.

## Camera2D
- `enabled` (bool=true), `offset` (Vector2, shake/look-ahead), `zoom` (Vector2, >1 in / <1 out), `ignore_rotation` (bool=true).
- `anchor_mode` (AnchorMode: `ANCHOR_MODE_FIXED_TOP_LEFT`=0, `ANCHOR_MODE_DRAG_CENTER`=1 default).
- `position_smoothing_enabled` (bool=false), `position_smoothing_speed` (float=5.0); `rotation_smoothing_enabled` (bool=false), `rotation_smoothing_speed` (float=5.0).
- `limit_left/top` (int=-10000000), `limit_right/bottom` (int=10000000), `limit_enabled` (bool=true), `limit_smoothed` (bool=false — only eases if position smoothing is on).
- `drag_horizontal_enabled`/`drag_vertical_enabled` (bool=false), `drag_left/right/top/bottom_margin` (float=0.2, fraction 0..1 dead-zone).
- `process_callback` (Camera2DProcessCallback: `CAMERA2D_PROCESS_PHYSICS`=0, `CAMERA2D_PROCESS_IDLE`=1 default) — use PHYSICS when following a body moved in `_physics_process`.
- Methods: `make_current()`, `is_current() -> bool`, `align()`, `reset_smoothing()` (snap after teleport), `force_update_scroll()`, `get_screen_center_position() -> Vector2` (for minimap markers/culling), `get_target_position() -> Vector2`, `set_limit(margin: Side, limit: int)`, `set_drag_margin(margin: Side, drag: float)`. `Side`: `SIDE_LEFT`=0,`SIDE_TOP`=1,`SIDE_RIGHT`=2,`SIDE_BOTTOM`=3.

## CanvasLayer (HUD / camera-independent UI)
Extends **Node, not CanvasItem** — no `modulate`/self-rendering; it only groups children into a layer the Camera2D does NOT move.
- `layer` (int=1) — world renders at 0; HUD = 1+ (on top), background = negative. Embedded windows use 1024.
- `visible` (bool=true) toggles the whole layer; `offset` (Vector2), `rotation` (float rad), `scale` (Vector2), `transform` (Transform2D).
- `follow_viewport_enabled` (bool=false) — make the layer DO follow the camera (mid-depth parallax); `follow_viewport_scale` (float=1.0).
- `custom_viewport` (Node) — targets exactly ONE viewport; cannot be shared across viewports (split-screen needs one per SubViewport).
- Methods `show()`/`hide()`, `get_final_transform() -> Transform2D`. Signal `visibility_changed()`.

## SubViewport + SubViewportContainer (minimaps / render-to-texture / 3D-in-2D)
- `SubViewport`: `size` (Vector2i=(512,512), **must be non-zero**), `render_target_update_mode` (UpdateMode: `DISABLED`=0,`ONCE`=1,`WHEN_VISIBLE`=2 default,`WHEN_PARENT_VISIBLE`=3,`ALWAYS`=4 — use ALWAYS for live maps), `render_target_clear_mode` (`ALWAYS`=0,`NEVER`=1,`ONCE`=2). Inherited from Viewport: `own_world_3d` (bool=false — true isolates a 3D scene for model viewers), `world_2d`, `world_3d`.
- Inherited methods: `get_texture() -> ViewportTexture`, `get_camera_2d()`, `get_camera_3d()`.
- `SubViewportContainer` (a Control): `stretch` (bool=false — true auto-sizes the child SubViewport; then DON'T set its size), `stretch_shrink` (int=1, requires stretch — render at reduced res, upscaled; cheap minimaps).
- To DISPLAY a SubViewport: nest it in a SubViewportContainer **or** assign its `get_texture()` to a Sprite2D/TextureRect/material. A bare SubViewport shows nothing.

## Viewport coordinate helpers
- `get_global_mouse_position()` (on a CanvasItem) → WORLD coords (respects Camera2D zoom/pan) — for placing world objects.
- `get_viewport().get_mouse_position()` → SCREEN/viewport pixels (ignores camera) — for HUD/tooltips.
- `get_viewport().get_camera_2d()` / `get_camera_3d()` → active camera. `get_viewport_rect() -> Rect2`.

## Parallax2D (4.3+)
Extends **Node2D** (no `layer` index — order via tree/`z_index`/parent CanvasLayer). `scroll_scale` (Vector2=(1,1): <1 far/slow, >1 near/fast), `repeat_size` (Vector2=(0,0); set to texture width for infinite scroll), `repeat_times` (int=1; raise when zoomed out), `autoscroll` (Vector2 px/sec), `follow_viewport` (bool=true), `ignore_camera_scroll` (bool=false). Needs an active Camera2D to drive it.

## Required setup
- No autoloads/feature flags needed; nodes work out of the box.
- Parallax2D/ParallaxBackground need an **active Camera2D** to scroll.
- SubViewport renders only with non-zero `size`, an update mode ≠ DISABLED, AND a display path (container or ViewportTexture).
- 3D-in-2D viewer: `own_world_3d = true` + a Camera3D + a light inside the SubViewport.
- Shared minimap world: assign the SubViewport's `world_2d` from the main viewport's `get_world_2d()`.

## Recipe — smooth follow camera with level bounds
```
create_node type=Camera2D name=Camera2D parent=Player
set_property target=Player/Camera2D property=enabled value=true
call_method target=Player/Camera2D method=make_current args=[]
set_property target=Player/Camera2D property=position_smoothing_enabled value=true
set_property target=Player/Camera2D property=position_smoothing_speed value=6.0
set_property target=Player/Camera2D property=process_callback value=0   # PHYSICS
set_property target=Player/Camera2D property=zoom value="2 2"           # 4.x: >1 zooms in
set_property target=Player/Camera2D property=limit_left value=0
set_property target=Player/Camera2D property=limit_top value=0
set_property target=Player/Camera2D property=limit_right value=4096
set_property target=Player/Camera2D property=limit_bottom value=2048
# after teleporting the player:
call_method target=Player/Camera2D method=reset_smoothing args=[]
```

## Recipe — live minimap (SubViewport)
```
create_node type=CanvasLayer name=HUD parent=Main
set_property target=Main/HUD property=layer value=1
create_node type=SubViewportContainer name=MinimapFrame parent=Main/HUD
set_property target=Main/HUD/MinimapFrame property=stretch value=true
set_property target=Main/HUD/MinimapFrame property=stretch_shrink value=2
create_node type=SubViewport name=MinimapView parent=Main/HUD/MinimapFrame
set_property target=Main/HUD/MinimapFrame/MinimapView property=render_target_update_mode value=4  # ALWAYS
create_node type=Camera2D name=MiniCam parent=Main/HUD/MinimapFrame/MinimapView
call_method target=Main/HUD/MinimapFrame/MinimapView/MiniCam method=make_current args=[]
set_property target=Main/HUD/MinimapFrame/MinimapView/MiniCam property=zoom value="0.25 0.25"  # zoom out
```

## Common traps
- No `current` bool in 4.x — use `enabled` + `make_current()`. On scene reload the active camera can reset; re-call `make_current()` in `_ready()`.
- `zoom` is inverted vs 3.x: `>1` magnifies, `<1` shows more world.
- CanvasLayer extends Node — no `modulate`; tint via a child CanvasModulate/Control. A HUD = Control nodes under a CanvasLayer at `layer` ≥ 1.
- SubViewport `size=(0,0)` OR `render_target_update_mode=DISABLED` → blank texture. Default WHEN_VISIBLE only updates while its texture is visible.
- A SubViewport gets NO input unless inside a SubViewportContainer (or you call `Viewport.push_input`). Set `stretch=true` to auto-size, then don't set `size` manually.
- A CanvasLayer/ParallaxBackground binds to ONE viewport — duplicate per SubViewport for split-screen.
- Parallax2D children must be positioned TOP-LEFT at (0,0) (`centered=false`), or `repeat_size` tiling misaligns. Increase `repeat_times` when zoomed out.
- `limit_smoothed` only eases at the edge if `position_smoothing_enabled` is also true.
- For follow jitter on a physics body, set `process_callback=CAMERA2D_PROCESS_PHYSICS` (0).

Confirm exact names, defaults, and enum values with `describe_class` before relying on them.
