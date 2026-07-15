class_name SuitState
extends Node
## Minimal authoritative survival state of the player's suit: health, oxygen and
## hydrogen, each as current + max with a normalized fraction. This is the single
## source of truth for the HUD Vitals widget — presentation reads it via `changed`
## and never writes it (see docs/PHYSICAL-LANGUAGE.md "Состояние скафандра" and
## docs/specs/HUD-UI-01.md). It is deliberately NOT a full atmosphere / life-support
## system (no sealed volumes, pressure, leaks or gas exchange).

## Emitted whenever any current value actually changes.
signal changed

@export var health_max := 100.0
@export var oxygen_max := 100.0
@export var hydrogen_max := 100.0

## Placeholder consumption/regen rates (units per second). Clearly a tunable stub
## so the bars are alive; a real balance/life-support system will own these later.
@export var oxygen_drain_per_sec := 0.6
@export var hydrogen_drain_per_sec := 0.35
@export var health_regen_per_sec := 0.0

## When true the node self-ticks the placeholder drain/regen each frame. Tests
## drive tick() directly and keep this off for determinism.
@export var simulate := true

var health := 0.0
var oxygen := 0.0
var hydrogen := 0.0


func _ready() -> void:
	fill()


func _process(delta: float) -> void:
	if simulate:
		tick(delta)


## Reset all channels to full and notify. Called on spawn.
func fill() -> void:
	health = health_max
	oxygen = oxygen_max
	hydrogen = hydrogen_max
	changed.emit()


## Advance the placeholder drain/regen by `delta` seconds. Always applies (the
## `simulate` flag only gates the automatic per-frame call), so tests can step it
## deterministically. Emits `changed` once if anything moved.
func tick(delta: float) -> void:
	var next_health := clampf(health + health_regen_per_sec * delta, 0.0, health_max)
	var next_oxygen := clampf(oxygen - oxygen_drain_per_sec * delta, 0.0, oxygen_max)
	var next_hydrogen := clampf(hydrogen - hydrogen_drain_per_sec * delta, 0.0, hydrogen_max)
	if next_health == health and next_oxygen == oxygen and next_hydrogen == hydrogen:
		return
	health = next_health
	oxygen = next_oxygen
	hydrogen = next_hydrogen
	changed.emit()


## Externally inflicted damage (kinetic impacts, V2-6). Source is kept for
## future HUD/death messaging; delivery must happen on the main thread.
func apply_damage(amount: float, _source: StringName = &"") -> void:
	if amount <= 0.0:
		return
	set_health(health - amount)


func set_health(value: float) -> void:
	var clamped := clampf(value, 0.0, health_max)
	if clamped != health:
		health = clamped
		changed.emit()


func set_oxygen(value: float) -> void:
	var clamped := clampf(value, 0.0, oxygen_max)
	if clamped != oxygen:
		oxygen = clamped
		changed.emit()


func set_hydrogen(value: float) -> void:
	var clamped := clampf(value, 0.0, hydrogen_max)
	if clamped != hydrogen:
		hydrogen = clamped
		changed.emit()


func health_fraction() -> float:
	return _fraction(health, health_max)


func oxygen_fraction() -> float:
	return _fraction(oxygen, oxygen_max)


func hydrogen_fraction() -> float:
	return _fraction(hydrogen, hydrogen_max)


static func _fraction(current: float, maximum: float) -> float:
	if maximum <= 0.0:
		return 0.0
	return clampf(current / maximum, 0.0, 1.0)
