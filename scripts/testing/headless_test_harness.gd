class_name HeadlessTestHarness
extends RefCounted
## Shared fail-fast helpers for headless `test_*.gd` scenes.
##
## Script errors inside an awaited test can abort the coroutine without
## `quit()`, leaving Godot printing FPS forever. Arm a watchdog at the start
## of every headless suite so the process always exits.

const DEFAULT_WATCHDOG_SEC := 20.0


## Start a one-shot timer that prints FAIL and quits if the suite overruns.
static func arm_watchdog(
	host: Node,
	label: String,
	timeout_sec: float = DEFAULT_WATCHDOG_SEC
) -> void:
	if host == null:
		return
	var tree := host.get_tree()
	if tree == null:
		return
	var tag := label.strip_edges()
	if tag.is_empty():
		tag = host.name
	var seconds := maxf(timeout_sec, 1.0)
	tree.create_timer(seconds).timeout.connect(
		func() -> void:
			if not is_instance_valid(host) or host.get_tree() == null:
				return
			var msg := "%s: FAIL watchdog timeout after %.0fs" % [tag, seconds]
			push_error(msg)
			print(msg)
			host.get_tree().quit(1)
	)
