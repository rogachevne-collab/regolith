extends Node

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")
## Headless PoC gate for the authoritative SuitState (docs/specs/HUD-UI-01.md
## Phase 2). Asserts normalized fractions, clamping at 0..max, the change signal
## firing (and staying quiet on no-op), and the placeholder drain/regen stub.

const EPS := 0.0001

var _changed_count := 0


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
	print("SUITSTATE: PASS")
	get_tree().quit(0)


func _make_suit() -> SuitState:
	var suit := SuitState.new()
	suit.simulate = false
	add_child(suit)
	return suit


func _test_fractions() -> bool:
	var suit := _make_suit()
	# _ready() fills every channel to its max.
	if not is_equal_approx(suit.health_fraction(), 1.0):
		return _fail("full health fraction expected 1.0, got %f" % suit.health_fraction())
	if not is_equal_approx(suit.oxygen_fraction(), 1.0):
		return _fail("full oxygen fraction expected 1.0, got %f" % suit.oxygen_fraction())
	if not is_equal_approx(suit.hydrogen_fraction(), 1.0):
		return _fail("full hydrogen fraction expected 1.0, got %f" % suit.hydrogen_fraction())

	suit.set_oxygen(suit.oxygen_max * 0.25)
	if absf(suit.oxygen_fraction() - 0.25) > EPS:
		return _fail("quarter oxygen fraction expected 0.25, got %f" % suit.oxygen_fraction())

	suit.queue_free()
	return true


func _test_clamping() -> bool:
	var suit := _make_suit()

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

	suit.queue_free()
	return true


func _test_change_signal() -> bool:
	var suit := _make_suit()
	_changed_count = 0
	suit.changed.connect(_on_changed)

	suit.set_health(suit.health_max * 0.5)
	if _changed_count != 1:
		return _fail("changed should fire once on a real change, got %d" % _changed_count)

	# Setting the same value must not re-emit.
	suit.set_health(suit.health_max * 0.5)
	if _changed_count != 1:
		return _fail("changed should stay quiet on a no-op set, got %d" % _changed_count)

	suit.changed.disconnect(_on_changed)
	suit.queue_free()
	return true


func _test_drain_regen() -> bool:
	var suit := _make_suit()
	suit.oxygen_drain_per_sec = 4.0
	suit.hydrogen_drain_per_sec = 2.0
	suit.health_regen_per_sec = 1.0

	suit.set_oxygen(50.0)
	suit.set_hydrogen(50.0)
	suit.set_health(50.0)

	_changed_count = 0
	suit.changed.connect(_on_changed)
	suit.tick(2.0)
	if _changed_count != 1:
		return _fail("tick with movement should emit changed once, got %d" % _changed_count)
	if absf(suit.oxygen - 42.0) > EPS:
		return _fail("oxygen after 2s drain expected 42, got %f" % suit.oxygen)
	if absf(suit.hydrogen - 46.0) > EPS:
		return _fail("hydrogen after 2s drain expected 46, got %f" % suit.hydrogen)
	if absf(suit.health - 52.0) > EPS:
		return _fail("health after 2s regen expected 52, got %f" % suit.health)

	# Drain must not push a channel below zero.
	suit.set_oxygen(1.0)
	suit.tick(100.0)
	if suit.oxygen != 0.0:
		return _fail("oxygen drain should clamp at 0, got %f" % suit.oxygen)

	suit.changed.disconnect(_on_changed)
	suit.queue_free()
	return true


func _on_changed() -> void:
	_changed_count += 1


func _fail(msg: String) -> bool:
	push_error("SUITSTATE: FAIL - %s" % msg)
	print("SUITSTATE: FAIL - %s" % msg)
	get_tree().quit(1)
	return false
