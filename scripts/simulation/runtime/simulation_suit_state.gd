class_name SimulationSuitState
extends RefCounted
## Authoritative survival state of ONE player's suit: health, oxygen and
## hydrogen. Oxygen values are liters; the legacy oxygen/oxygen_max names stay
## as compatibility aliases for existing HUD and saves.
## `SimulationWorld` and keyed by player id, so it rides `capture_snapshot()`
## into the save and (COOP-HOST-V0) into the join payload — no separate
## replication or persistence path.
##
## Presentation reads it through the `SuitState` view node and never writes it
## (see docs/PHYSICAL-LANGUAGE.md "Состояние скафандра" and
## docs/specs/HUD-UI-01.md). Deliberately NOT a full atmosphere / life-support
## system (no sealed volumes, pressure, leaks or gas exchange).
##
## Every mutator returns `true` only when a value actually moved; the world
## turns that into a single `suit_changed` emission.

var health_max := 100.0
var oxygen_max := 100.0
var hydrogen_max := 100.0

## Legacy persisted field. Oxygen drain is now owned by SuitLifeSupportService
## and tuned globally in Game Balance; old snapshots still load this value.
var oxygen_drain_per_sec := 0.6
var hydrogen_drain_per_sec := 0.35
var health_regen_per_sec := 0.0

var health := 0.0
var oxygen := 0.0
var hydrogen := 0.0
## Persisted deterministic hypoxia state.
var hypoxia_exposure_s := 0.0
var hypoxia_tick_accumulator_s := 0.0


func _init() -> void:
	fill()


## Reset all channels to full. Called on spawn.
func fill() -> bool:
	var changed := _assign(health_max, oxygen_max, hydrogen_max)
	return reset_hypoxia() or changed


## Compatibility helper for direct callers. Authoritative world ticks use
## SuitLifeSupportService so atmosphere and hypoxia are applied.
func tick(delta: float) -> bool:
	return tick_non_oxygen_channels(delta)


func tick_non_oxygen_channels(delta: float) -> bool:
	return _assign(
		health + health_regen_per_sec * delta,
		oxygen,
		hydrogen - hydrogen_drain_per_sec * delta
	)


func reset_hypoxia() -> bool:
	if (
		hypoxia_exposure_s == 0.0
		and hypoxia_tick_accumulator_s == 0.0
	):
		return false
	hypoxia_exposure_s = 0.0
	hypoxia_tick_accumulator_s = 0.0
	return true


## Externally inflicted damage (kinetic impacts, meteorites). Source is kept
## for future HUD/death messaging.
func apply_damage(amount: float, _source: StringName = &"") -> bool:
	if amount <= 0.0:
		return false
	return set_health(health - amount)


func set_health(value: float) -> bool:
	return _assign(value, oxygen, hydrogen)


func set_oxygen(value: float) -> bool:
	return _assign(health, value, hydrogen)


func set_hydrogen(value: float) -> bool:
	return _assign(health, oxygen, value)


func health_fraction() -> float:
	return _fraction(health, health_max)


func oxygen_fraction() -> float:
	return _fraction(oxygen, oxygen_max)


func hydrogen_fraction() -> float:
	return _fraction(hydrogen, hydrogen_max)


func is_dead() -> bool:
	return health <= 0.0


func to_dict() -> Dictionary:
	return {
		"health": health,
		"oxygen_current_l": oxygen,
		"oxygen_capacity_l": oxygen_max,
		# Backward-compatible keys for existing saves/readers.
		"oxygen": oxygen,
		"hydrogen": hydrogen,
		"health_max": health_max,
		"oxygen_max": oxygen_max,
		"hydrogen_max": hydrogen_max,
		"oxygen_drain_per_sec": oxygen_drain_per_sec,
		"hydrogen_drain_per_sec": hydrogen_drain_per_sec,
		"health_regen_per_sec": health_regen_per_sec,
		"hypoxia_exposure_s": hypoxia_exposure_s,
		"hypoxia_tick_accumulator_s": hypoxia_tick_accumulator_s,
	}


static func from_dict(row: Dictionary) -> SimulationSuitState:
	var suit := SimulationSuitState.new()
	suit.health_max = float(row.get("health_max", suit.health_max))
	suit.oxygen_max = float(
		row.get("oxygen_capacity_l", row.get("oxygen_max", suit.oxygen_max))
	)
	suit.hydrogen_max = float(row.get("hydrogen_max", suit.hydrogen_max))
	suit.oxygen_drain_per_sec = float(
		row.get("oxygen_drain_per_sec", suit.oxygen_drain_per_sec)
	)
	suit.hydrogen_drain_per_sec = float(
		row.get("hydrogen_drain_per_sec", suit.hydrogen_drain_per_sec)
	)
	suit.health_regen_per_sec = float(
		row.get("health_regen_per_sec", suit.health_regen_per_sec)
	)
	suit._assign(
		float(row.get("health", suit.health_max)),
		float(row.get("oxygen_current_l", row.get("oxygen", suit.oxygen_max))),
		float(row.get("hydrogen", suit.hydrogen_max))
	)
	var exposure := float(row.get("hypoxia_exposure_s", 0.0))
	var accumulator := float(row.get("hypoxia_tick_accumulator_s", 0.0))
	suit.hypoxia_exposure_s = maxf(exposure, 0.0) if is_finite(exposure) else 0.0
	suit.hypoxia_tick_accumulator_s = (
		maxf(accumulator, 0.0) if is_finite(accumulator) else 0.0
	)
	return suit


## Single clamp + change-detect point, so no mutator can drift out of range or
## report a change that did not happen.
func _assign(
	next_health: float,
	next_oxygen: float,
	next_hydrogen: float
) -> bool:
	var clamped_health := clampf(next_health, 0.0, health_max)
	var clamped_oxygen := clampf(next_oxygen, 0.0, oxygen_max)
	var clamped_hydrogen := clampf(next_hydrogen, 0.0, hydrogen_max)
	if (
		clamped_health == health
		and clamped_oxygen == oxygen
		and clamped_hydrogen == hydrogen
	):
		return false
	health = clamped_health
	oxygen = clamped_oxygen
	hydrogen = clamped_hydrogen
	return true


static func _fraction(current: float, maximum: float) -> float:
	if maximum <= 0.0:
		return 0.0
	return clampf(current / maximum, 0.0, 1.0)
