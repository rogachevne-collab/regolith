extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless PoC gate for the authoritative suit state (docs/specs/HUD-UI-01.md
## Phase 2, docs/specs/COOP-HOST-V0.md "Per-peer player state"). Asserts
## normalized fractions, clamping at 0..max, the world's `suit_changed` signal
## firing (and staying quiet on no-op), the placeholder drain/regen stub, that
## suits are per player id, and that they survive a snapshot round-trip.

const EPS := 0.0001

var _changed_ids: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "SUITSTATE")
	if not _test_fractions():
		return
	if not _test_clamping():
		return
	if not _test_change_signal():
		return
	if not _test_drain_regen():
		return
	if not _test_per_player_isolation():
		return
	if not _test_snapshot_round_trip():
		return
	print("SUITSTATE: PASS")
	get_tree().quit(0)


func _make_world() -> SimulationWorld:
	var world := SimulationWorld.new()
	add_child(world)
	return world


func _free_world(world: SimulationWorld) -> void:
	remove_child(world)
	world.free()


func _test_fractions() -> bool:
	var world := _make_world()
	# A fresh suit starts every channel at its max.
	var suit := world.ensure_suit_state("player")
	if not is_equal_approx(suit.health_fraction(), 1.0):
		return _fail("full health fraction expected 1.0, got %f" % suit.health_fraction())
	if not is_equal_approx(suit.oxygen_fraction(), 1.0):
		return _fail("full oxygen fraction expected 1.0, got %f" % suit.oxygen_fraction())
	if not is_equal_approx(suit.hydrogen_fraction(), 1.0):
		return _fail("full hydrogen fraction expected 1.0, got %f" % suit.hydrogen_fraction())

	suit.set_oxygen(suit.oxygen_max * 0.25)
	if absf(suit.oxygen_fraction() - 0.25) > EPS:
		return _fail("quarter oxygen fraction expected 0.25, got %f" % suit.oxygen_fraction())

	_free_world(world)
	return true


func _test_clamping() -> bool:
	var world := _make_world()
	var suit := world.ensure_suit_state("player")

	suit.set_health(suit.health_max * 10.0)
	if suit.health != suit.health_max:
		return _fail("health should clamp to max, got %f" % suit.health)
	if suit.health_fraction() > 1.0 + EPS:
		return _fail("health fraction should clamp to 1.0, got %f" % suit.health_fraction())

	suit.set_hydrogen(-50.0)
	if suit.hydrogen != 0.0:
		return _fail("hydrogen should clamp to 0, got %f" % suit.hydrogen)
	if suit.hydrogen_fraction() < -EPS:
		return _fail("hydrogen fraction should clamp to 0.0, got %f" % suit.hydrogen_fraction())

	_free_world(world)
	return true


func _test_change_signal() -> bool:
	var world := _make_world()
	world.ensure_suit_state("player")
	_changed_ids.clear()
	world.suit_changed.connect(_on_suit_changed)

	world.apply_suit_damage("player", 10.0, &"test")
	if _changed_ids.size() != 1:
		return _fail("suit_changed should fire once on damage, got %d" % _changed_ids.size())
	if _changed_ids[0] != "player":
		return _fail("suit_changed carried the wrong id: %s" % _changed_ids[0])

	# Zero damage must not re-emit.
	world.apply_suit_damage("player", 0.0, &"test")
	if _changed_ids.size() != 1:
		return _fail("suit_changed should stay quiet on a no-op, got %d" % _changed_ids.size())

	world.suit_changed.disconnect(_on_suit_changed)
	_free_world(world)
	return true


func _test_drain_regen() -> bool:
	var world := _make_world()
	var suit := world.ensure_suit_state("player")
	suit.oxygen_drain_per_sec = 4.0
	suit.hydrogen_drain_per_sec = 2.0
	suit.health_regen_per_sec = 1.0

	suit.set_oxygen(50.0)
	suit.set_hydrogen(50.0)
	suit.set_health(50.0)

	_changed_ids.clear()
	world.suit_changed.connect(_on_suit_changed)
	world.tick_suits(2.0)
	if _changed_ids.size() != 1:
		return _fail("tick with movement should emit once, got %d" % _changed_ids.size())
	if absf(suit.oxygen - 42.0) > EPS:
		return _fail("oxygen after 2s drain expected 42, got %f" % suit.oxygen)
	if absf(suit.hydrogen - 46.0) > EPS:
		return _fail("hydrogen after 2s drain expected 46, got %f" % suit.hydrogen)
	if absf(suit.health - 52.0) > EPS:
		return _fail("health after 2s regen expected 52, got %f" % suit.health)

	# Drain must not push a channel below zero.
	suit.set_oxygen(1.0)
	world.tick_suits(100.0)
	if suit.oxygen != 0.0:
		return _fail("oxygen drain should clamp at 0, got %f" % suit.oxygen)

	world.suit_changed.disconnect(_on_suit_changed)
	_free_world(world)
	return true


## The whole point of moving suits into the world: N players, N suits.
func _test_per_player_isolation() -> bool:
	var world := _make_world()
	var host := world.ensure_suit_state("player:1")
	var guest := world.ensure_suit_state("player:2")
	if host == guest:
		return _fail("two player ids must not share one suit")

	world.apply_suit_damage("player:1", 30.0, &"test")
	if absf(host.health - 70.0) > EPS:
		return _fail("host health expected 70, got %f" % host.health)
	if guest.health != guest.health_max:
		return _fail("damaging one player hurt the other: %f" % guest.health)

	var ids := world.list_suit_state_ids()
	if ids.size() != 2 or ids[0] != "player:1" or ids[1] != "player:2":
		return _fail("unexpected suit id list: %s" % str(ids))

	_free_world(world)
	return true


## Suits ride capture_snapshot() into the save (and later the join payload),
## so a round-trip must preserve them exactly.
func _test_snapshot_round_trip() -> bool:
	var world := _make_world()
	var suit := world.ensure_suit_state("player")
	suit.set_health(41.0)
	suit.set_oxygen(17.5)
	suit.oxygen_drain_per_sec = 2.25
	world.ensure_suit_state("player:2").set_hydrogen(3.0)

	var snapshot := world.capture_snapshot()
	if not world.restore_snapshot(snapshot, false):
		return _fail("restore_snapshot rejected a snapshot carrying suits")

	var restored := world.get_suit_state("player")
	if restored == null:
		return _fail("suit missing after round-trip")
	if absf(restored.health - 41.0) > EPS:
		return _fail("health after round-trip expected 41, got %f" % restored.health)
	if absf(restored.oxygen - 17.5) > EPS:
		return _fail("oxygen after round-trip expected 17.5, got %f" % restored.oxygen)
	if absf(restored.oxygen_drain_per_sec - 2.25) > EPS:
		return _fail(
			"drain rate after round-trip expected 2.25, got %f"
			% restored.oxygen_drain_per_sec
		)
	var second := world.get_suit_state("player:2")
	if second == null or absf(second.hydrogen - 3.0) > EPS:
		return _fail("second player's suit did not survive the round-trip")

	# A save written before suits moved into the world must still load.
	var legacy := world.capture_snapshot()
	legacy.erase("suits")
	if not world.restore_snapshot(legacy, false):
		return _fail("restore_snapshot rejected a pre-suits snapshot")
	if world.has_suit_state("player"):
		return _fail("pre-suits snapshot should restore without any suit")

	_free_world(world)
	return true


func _on_suit_changed(player_id: String) -> void:
	_changed_ids.append(player_id)


func _fail(msg: String) -> bool:
	push_error("SUITSTATE: FAIL - %s" % msg)
	print("SUITSTATE: FAIL - %s" % msg)
	get_tree().quit(1)
	return false
