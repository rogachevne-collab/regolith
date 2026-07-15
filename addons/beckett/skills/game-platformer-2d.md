# Blueprint: 2D platformer — jump, coins, hazards, score, retry

> Complete copy-able build of a one-screen 2D platformer: CharacterBody2D player with coyote time + jump buffer, coin pickups, kill zones, score HUD, game-over/retry, juice. Follow the phases in order; read game-oneshot first for gates, palette, and scope rules.

## Fast path (use this unless you need a custom structure)
This exact build ships as a template. ONE call writes all of it (scene + `main.gd`/`player.gd`/`coin.gd`/`killzone.gd`) and sets the main scene:
`apply_template template=platformer-2d`
Then reskin to the theme (rename nodes, swap the palette colors below) and run the gates. `assert_scene require_types=["CharacterBody2D","Area2D","StaticBody2D"] require_main_scene=true` must return `pass: true` before you call it done. The phases below are the by-hand version — the reference for what each part is and how to customise or repair it.

## Spec defaults (reskin names/colors to the theme; keep the numbers)
Player 28×40 `#41a6f6` · run speed 260 · jump −600 with gravity ×2 · one fixed screen 1152×648 · coins `#ffcd75` diamonds · hazards `#ef7d57` · score = coins collected · touch hazard → game over → Retry.

## Scene tree (final shape)
```
Main (Node2D, main.gd)
├─ Background (ColorRect 1152×648 #1a1c2c)
├─ Camera2D (position 576,324 — default drag-center ⇒ same view as no camera; exists for shake)
├─ World (Node2D)            # one StaticBody2D per platform: CollisionShape2D + ColorRect visual
├─ Player (CharacterBody2D, player.gd) ─ Visual (ColorRect) + Col (CollisionShape2D)
├─ Coins (Node2D)            # Area2D per coin: CollisionShape2D + Visual (rotated ColorRect)
├─ Hazards (Node2D)          # Area2D per hazard strip, killzone.gd
└─ HUD (CanvasLayer, process_mode ALWAYS=3)
   ├─ Score (Label, top-left, text #f4f4f4)
   └─ GameOver (Control full-rect, visible=false): Dim ColorRect + VBox(Label "GAME OVER", Button "Retry")
```

## P0 — bootstrap
```
write_file path=res://main.tscn content="[gd_scene format=3]\n\n[node name=\"Main\" type=\"Node2D\"]\n"
open_scene path=res://main.tscn
set_project_setting setting=application/run/main_scene value=res://main.tscn
```

## P1 — world (batch_execute the node setup)
Background ColorRect: `size=[1152,648]`, `color=#1a1c2c`. Camera2D at `[576,324]`.
Platform = StaticBody2D at a position + CollisionShape2D + ColorRect visual (`size=[w,h]`, `position=[-w/2,-h/2]`, `color=#333c57`). Size the collision shape with the two-step resource pattern (targets resolve to NODES from the scene root — you cannot path-walk into `.../Col/shape`, so build the shape as a resource and attach it):
`create_resource class=RectangleShape2D properties={"size":[w,h]} path=res://shapes/<name>.tres` → `set_resource target=<body>/Col property=shape resource=res://shapes/<name>.tres`.
Layout (position / size):
ground `[576,616] / [1152,64]` · ledge1 `[250,470] / [220,28]` · ledge2 `[560,360] / [200,28]` · ledge3 `[870,250] / [220,28]`.

## P2 — player + movement (GATE after)
Player CharacterBody2D at `[80,520]`; Visual ColorRect `size=[28,40]` `position=[-14,-20]` `pivot_offset=[14,20]` `color=#41a6f6`; Col shape RectangleShape2D `size=[28,40]`.
```
write_script path=res://player.gd content="extends CharacterBody2D
const SPEED := 260.0
const JUMP := -600.0
const GRAV_MULT := 2.0
var _coyote := 0.0
var _buffer := 0.0
func _physics_process(delta: float) -> void:
	if is_on_floor():
		_coyote = 0.1
	else:
		velocity += get_gravity() * GRAV_MULT * delta
		_coyote -= delta
	_buffer = 0.1 if Input.is_action_just_pressed(\"ui_accept\") else _buffer - delta
	if _buffer > 0.0 and _coyote > 0.0:
		velocity.y = JUMP
		_buffer = 0.0
		_coyote = 0.0
		squash()
	if Input.is_action_just_released(\"ui_accept\") and velocity.y < 0.0:
		velocity.y *= 0.5
	velocity.x = move_toward(velocity.x, Input.get_axis(\"ui_left\", \"ui_right\") * SPEED, SPEED * 10.0 * delta)
	var was_air := not is_on_floor()
	move_and_slide()
	position.x = clampf(position.x, 14.0, 1138.0)
	if was_air and is_on_floor():
		squash()
func squash() -> void:
	$Visual.scale = Vector2(1.15, 0.85)
	create_tween().tween_property($Visual, \"scale\", Vector2.ONE, 0.12)
"
attach_script target=Player path=res://player.gd
save_scene
```
GATE: play → `simulate_input` right + jump → `assert_node_state` Player moved right and y decreased mid-jump → screenshot → logs clean → stop.

## P3 — coins + hazards (GATE after)
Coin = Area2D at each spot (above each ledge: `[250,420]`, `[560,310]`, `[870,200]`, bonus `[1050,560]`); child CollisionShape2D (CircleShape2D `radius=12`) + Visual ColorRect `size=[18,18]` `position=[-9,-9]` `pivot_offset=[9,9]` `rotation_degrees=45` `color=#ffcd75`. One coin.gd attached to every coin.
Hazard = Area2D strip on the ground gap `[700,592]`: CollisionShape2D RectangleShape2D `size=[120,24]` + ColorRect `size=[120,24]` `position=[-60,-12]` `color=#ef7d57`, script killzone.gd.
```
write_script path=res://coin.gd content="extends Area2D
func _ready() -> void:
	body_entered.connect(_on_body)
func _on_body(body: Node2D) -> void:
	if not body is CharacterBody2D:
		return
	set_deferred(\"monitoring\", false)
	get_tree().current_scene.add_score(1)
	get_tree().current_scene.burst(global_position, Color(\"ffcd75\"))
	var t := create_tween()
	t.tween_property(self, \"scale\", Vector2(1.6, 1.6), 0.12)
	t.parallel().tween_property(self, \"modulate:a\", 0.0, 0.12)
	t.tween_callback(queue_free)
"
write_script path=res://killzone.gd content="extends Area2D
func _ready() -> void:
	body_entered.connect(_on_body)
func _on_body(body: Node2D) -> void:
	if body is CharacterBody2D:
		get_tree().current_scene.game_over()
"
```
GATE: play → walk over a coin → assert coin freed + score state → walk into hazard → assert game_over reached → logs → stop.

## P4 — HUD + game loop (GATE after)
HUD CanvasLayer `process_mode=3` (ALWAYS — Retry must click while paused). Score Label at `[24,16]`, `text="Score: 0"`. GameOver Control full-rect `visible=false`: Dim ColorRect `size=[1152,648]` `color=[0,0,0,0.55]`; centered VBox with Label "GAME OVER" + Button "Retry". `connect_signal from=HUD/GameOver/VBox/Retry signal=pressed to=Main method=_on_retry`.
```
write_script path=res://main.gd content="extends Node2D
var score := 0
var _over := false
func add_score(n: int) -> void:
	score += n
	var lbl: Label = $HUD/Score
	lbl.text = \"Score: %d\" % score
	lbl.pivot_offset = lbl.size / 2.0
	lbl.scale = Vector2(1.3, 1.3)
	create_tween().tween_property(lbl, \"scale\", Vector2.ONE, 0.15)
func burst(at: Vector2, color: Color) -> void:
	var p := CPUParticles2D.new()
	add_child(p)
	p.position = at
	p.one_shot = true
	p.amount = 12
	p.lifetime = 0.4
	p.spread = 180.0
	p.initial_velocity_min = 60.0
	p.initial_velocity_max = 140.0
	p.color = color
	p.finished.connect(p.queue_free)
	p.emitting = true
func shake() -> void:
	var t := create_tween()
	for i in 4:
		t.tween_property($Camera2D, \"offset\", Vector2(randf_range(-8, 8), randf_range(-8, 8)), 0.04)
	t.tween_property($Camera2D, \"offset\", Vector2.ZERO, 0.04)
func game_over() -> void:
	if _over:
		return
	_over = true
	shake()
	await get_tree().create_timer(0.3).timeout
	get_tree().paused = true
	$HUD/GameOver.visible = true
func _on_retry() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
"
attach_script target=Main path=res://main.gd
save_scene
```
GATE: play → collect coin (score pops) → die on hazard (shake, beat, panel) → `click_button_by_text "Retry"` → assert score reset + player back at spawn → logs → stop.

## P5 — juice + final gate
Squash, burst, pop, shake, death-beat are already wired above. Final pass: confirm Background covers everything, coins readable, hazard clearly orange. Then the game-oneshot final GATE: fresh 60 s playtest, screenshots, `logs_read` clean.

## Fallbacks (gate failed twice → simplify)
| Problem | Simplify to |
|---|---|
| Coyote/buffer logic misbehaves | plain `if is_on_floor() and Input.is_action_just_pressed("ui_accept")` |
| get_gravity() unavailable (<4.3) | `velocity.y += 1960.0 * delta` |
| Tween/burst errors | delete the juice line, keep mechanics; retry juice last |
| Retry unclickable | confirm HUD `process_mode=3`; else `game_over()` skips pause and just shows the panel |

## Traps
- `move_and_slide()` takes no args; `velocity` is units/second — never multiply it by delta.
- Area2D detects the player via `body_entered` only if the player has a CollisionShape2D; coins/hazards collide as areas, platforms as bodies.
- ColorRect scales from its top-left unless `pivot_offset` is the center — set it before any scale tween.
- While `get_tree().paused`, tweens/physics stop — anything that must animate or click then needs `process_mode=3` (ALWAYS).
- Don't scale CollisionShape2D nodes; size the shape resource.

Confirm exact class, property, and method names with `describe_class` (and `get_godot_version`) before relying on them — APIs shift between Godot versions.
