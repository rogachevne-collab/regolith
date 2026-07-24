class_name SuitLifeSupportService
extends RefCounted

const EPSILON := 0.000001


static func tick_suit(
	world: SimulationWorld,
	player_id: String,
	suit: SimulationSuitState,
	delta_s: float
) -> bool:
	if world == null or suit == null or delta_s <= 0.0:
		return false
	var saturation := clampf(
		world.get_environment_profile().oxygen_saturation,
		0.0,
		1.0
	)
	var atmosphere_factor := 1.0 - saturation
	var changed := suit.tick_non_oxygen_channels(delta_s)
	if atmosphere_factor <= EPSILON:
		changed = suit.reset_hypoxia() or changed
		return changed

	var drain_lps := _balance_float("base_drain_lps", 0.02) * atmosphere_factor
	var oxygen_before := suit.oxygen
	var drain_l := drain_lps * delta_s
	changed = suit.set_oxygen(suit.oxygen - drain_l) or changed
	if suit.oxygen > EPSILON:
		changed = suit.reset_hypoxia() or changed
		return changed
	var empty_delta_s := delta_s
	if oxygen_before > EPSILON and drain_lps > EPSILON:
		empty_delta_s = maxf(delta_s - oxygen_before / drain_lps, 0.0)

	var previous_exposure := suit.hypoxia_exposure_s
	var previous_tick := suit.hypoxia_tick_accumulator_s
	var previous_health := suit.health
	# Grace is configured in real seconds after the tank empties. Atmospheric
	# oxygen scales post-grace hypoxia damage, not the grace duration itself.
	suit.hypoxia_exposure_s += empty_delta_s
	var grace_s := _balance_float("hypoxia_grace_s", 10.0)
	if suit.hypoxia_exposure_s > grace_s:
		suit.hypoxia_tick_accumulator_s += atmosphere_factor * (
			maxf(suit.hypoxia_exposure_s - grace_s, 0.0)
			- maxf(previous_exposure - grace_s, 0.0)
		)
		var tick_s := maxf(_balance_float("hypoxia_tick_s", 1.0), EPSILON)
		while suit.hypoxia_tick_accumulator_s + EPSILON >= tick_s:
			suit.hypoxia_tick_accumulator_s -= tick_s
			world.apply_suit_damage(
				player_id,
				_balance_float("hypoxia_damage_hp", 5.0),
				&"hypoxia",
				false
			)
	changed = (
		changed
		or not is_equal_approx(previous_exposure, suit.hypoxia_exposure_s)
		or not is_equal_approx(previous_tick, suit.hypoxia_tick_accumulator_s)
		or not is_equal_approx(previous_health, suit.health)
	)
	return changed


static func _balance_float(key: String, fallback: float) -> float:
	var life_support: Variant = GameBalance.root().get("suit_life_support", {})
	if life_support is Dictionary:
		return float((life_support as Dictionary).get(key, fallback))
	return fallback
