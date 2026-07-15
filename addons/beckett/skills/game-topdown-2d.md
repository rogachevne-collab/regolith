# Blueprint: top-down 2D arena — move, aim, shoot, survive waves

> Complete copy-able build of a one-screen top-down arena shooter/survival: 8-way CharacterBody2D player, mouse-aim shooting, chasing enemies spawned from screen edges with a ramping spawner, HP + score, game-over/retry, juice. Works for "zombie / space / survival / dodge" ideas via reskin. Read game-oneshot first for gates, palette, scope.

## Spec defaults (reskin names/colors to the theme; keep the numbers)
Player 28×28 `#41a6f6`, speed 320 · bullets 12×4 `#ffcd75`, speed 700, fire every 0.18 s (hold `ui_accept` or left mouse) · enemies 24×24 `#ef7d57`, speed 110, chase player, spawn at screen edges every 1.6 s ramping to 0.45 s · touch = −1 HP (0.8 s invuln), 3 HP · score = kills.
Dodge-only variant (no shooting in the idea): delete Bullet + `_shoot`, score = survival seconds via a 1 s Timer.

## Scene tree (final shape)
```
Main (Node2D, main.gd)
├─ Background (ColorRect 1152×648 #1a1c2c)
├─ Camera2D (position 576,324 — for shake)
├─ Player (CharacterBody2D, player.gd)
│  ├─ Visual (ColorRect 28×28, position −14,−14, pivot_offset 14,14)
│  ├─ Col (CollisionShape2D, RectangleShape2D 28×28)
│  └─ Hurtbox (Area2D) ─ Col (CollisionShape2D, CircleShape2D radius 20)
├─ Templates (Node2D, visible=false, process_mode=4 DISABLED)   # never spawns gameplay; duplicate() from here
│  ├─ Bullet (Area2D, bullet.gd) ─ Col (RectangleShape2D 12×4) + Visual (ColorRect 12×4, position −6,−2, #ffcd75)
│  └─ Enemy (CharacterBody2D, enemy.gd) ─ Visual (ColorRect 24×24, position −12,−12, #ef7d57) + Col (RectangleShape2D 24×24)
└─ HUD (CanvasLayer, process_mode=3 ALWAYS)
   ├─ Score (Label [24,16], #f4f4f4) · HP (Label [24,48], #ef7d57)
   └─ GameOver (Control full-rect, visible=false): Dim + VBox(Label "GAME OVER", Button "Retry")
```
Template trick: children under a `process_mode=DISABLED` + `visible=false` parent are inert (physics removed too); `duplicate()` + `add_child` onto Main re-enables them (their own mode is INHERIT). No .tscn files needed.

## P0 — bootstrap
Same as game-oneshot P0: `write_file` minimal `[gd_scene format=3]` + `Main` Node2D root → `open_scene` → `set_project_setting application/run/main_scene`.

## P1 — world, then P2 — player + shooting (main.gd lands here; GATE after)
```
write_script path=res://main.gd content="extends Node2D
var score := 0
var _over := false
var _spawn_t := 1.0
var _spawn_every := 1.6
func _process(delta: float) -> void:
	if _over:
		return
	_spawn_t -= delta
	if _spawn_t <= 0.0:
		_spawn_every = maxf(0.45, _spawn_every * 0.97)
		_spawn_t = _spawn_every
		_spawn_enemy()
func _spawn_enemy() -> void:
	var e := $Templates/Enemy.duplicate()
	add_child(e)
	match randi() % 4:
		0: e.global_position = Vector2(randf_range(0, 1152), -24)
		1: e.global_position = Vector2(randf_range(0, 1152), 672)
		2: e.global_position = Vector2(-24, randf_range(0, 648))
		3: e.global_position = Vector2(1176, randf_range(0, 648))
func spawn_bullet(at: Vector2, dir: Vector2) -> void:
	var b := $Templates/Bullet.duplicate()
	add_child(b)
	b.global_position = at
	b.dir = dir
func add_score(n: int) -> void:
	score += n
	var lbl: Label = get_node_or_null(\"HUD/Score\")
	if lbl == null:
		return
	lbl.text = \"Score: %d\" % score
	lbl.pivot_offset = lbl.size / 2.0
	lbl.scale = Vector2(1.3, 1.3)
	create_tween().tween_property(lbl, \"scale\", Vector2.ONE, 0.15)
func update_hp(hp: int) -> void:
	var lbl: Label = get_node_or_null(\"HUD/HP\")
	if lbl:
		lbl.text = \"HP \" + \"♥\".repeat(maxi(hp, 0))
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
write_script path=res://player.gd content="extends CharacterBody2D
const SPEED := 320.0
var hp := 3
var _invuln := 0.0
var _cd := 0.0
func _ready() -> void:
	add_to_group(\"player\")
	$Hurtbox.body_entered.connect(_on_hurt)
func _physics_process(delta: float) -> void:
	_invuln -= delta
	_cd -= delta
	velocity = Input.get_vector(\"ui_left\", \"ui_right\", \"ui_up\", \"ui_down\") * SPEED
	move_and_slide()
	position = position.clamp(Vector2(20, 20), Vector2(1132, 628))
	if (Input.is_action_pressed(\"ui_accept\") or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) and _cd <= 0.0:
		_cd = 0.18
		_shoot()
func _shoot() -> void:
	var dir := (get_global_mouse_position() - global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	get_tree().current_scene.spawn_bullet(global_position + dir * 24.0, dir)
	$Visual.scale = Vector2(0.8, 0.8)
	create_tween().tween_property($Visual, \"scale\", Vector2.ONE, 0.1)
func _on_hurt(body: Node2D) -> void:
	if _invuln > 0.0 or not body.is_in_group(\"enemy\"):
		return
	_invuln = 0.8
	body.die(false)
	hp -= 1
	get_tree().current_scene.update_hp(hp)
	modulate = Color(3, 3, 3)
	create_tween().tween_property(self, \"modulate\", Color.WHITE, 0.2)
	get_tree().current_scene.shake()
	if hp <= 0:
		get_tree().current_scene.game_over()
"
```
Build the tree per the diagram (batch_execute), attach scripts, save_scene. GATE: play → `simulate_input` arrows (player moves, stays in bounds) → hold ui_accept (Bullet appears in `get_remote_tree`, flies toward mouse) → screenshot → logs → stop.

## P3 — bullet + enemy templates (GATE after)
```
write_script path=res://bullet.gd content="extends Area2D
var dir := Vector2.RIGHT
const SPEED := 700.0
func _ready() -> void:
	body_entered.connect(_on_body)
func _physics_process(delta: float) -> void:
	position += dir * SPEED * delta
	if not Rect2(-32, -32, 1216, 712).has_point(position):
		queue_free()
func _on_body(body: Node2D) -> void:
	if body.is_in_group(\"enemy\"):
		body.die()
		queue_free()
"
write_script path=res://enemy.gd content="extends CharacterBody2D
const SPEED := 110.0
func _ready() -> void:
	add_to_group(\"enemy\")
func _physics_process(_delta: float) -> void:
	var p := get_tree().get_first_node_in_group(\"player\")
	if p == null:
		return
	velocity = (p.global_position - global_position).normalized() * SPEED
	move_and_slide()
func die(scored := true) -> void:
	if scored:
		get_tree().current_scene.add_score(1)
	get_tree().current_scene.burst(global_position, Color(\"ef7d57\"))
	queue_free()
"
```
GATE: play 10 s → enemies stream in from edges and chase → shoot one (burst + it frees) → get rammed (flash + shake) → logs → stop.

## P4 — HUD + game loop (GATE after)
Build HUD per diagram; `connect_signal from=HUD/GameOver/VBox/Retry signal=pressed to=Main method=_on_retry`. GATE: kill an enemy (score pops) → stand still until HP 0 (beat → panel) → `click_button_by_text "Retry"` → assert score/HP reset → logs → stop.

## P5 — juice + final gate
Kick, flash, shake, burst, pop, death-beat already wired. Final game-oneshot GATE: fresh 60 s playtest — difficulty visibly ramps, HUD readable, screenshot composed.

## Fallbacks (gate failed twice → simplify)
| Problem | Simplify to |
|---|---|
| Mouse aim misbehaves under simulate_input | shoot toward last nonzero move direction instead of the mouse |
| duplicate() template issues | `var e := CharacterBody2D.new()` built in `_spawn_enemy` (add Visual/Col in code) |
| Enemies stuck on each other | enemy `Col.disabled = true`, keep Hurtbox-only damage (pure dodge feel) |
| Heart glyph renders wrong | `lbl.text = "HP: %d" % hp` |

## Traps
- Templates parent MUST be `process_mode=4` + `visible=false`, or the template Enemy chases while "hidden"; duplicates re-enable via INHERIT automatically.
- `duplicate()` copies children + script but `_ready` runs on tree entry — connect signals in `_ready`, not in the editor-time template only.
- Bullets are Area2D moved by code (`position +=`), enemies are CharacterBody2D (`move_and_slide`) — don't mix the two movement styles.
- Off-screen spawns must be outside the player clamp rect, else edge-camping kills instantly; invuln window (0.8 s) prevents multi-hit drain in one clump.
- While paused only `process_mode=3` nodes tick — HUD owns the Retry button.

Confirm exact class, property, and method names with `describe_class` (and `get_godot_version`) before relying on them — APIs shift between Godot versions.
