extends Node3D
## Runner: builds the bench, points it at whichever rope implementation(s) are
## being judged, prints one table per adapter and exits. Headless-friendly.
##
##   godot --headless res://scenes/bench_ropes.tscn
##   godot --headless res://scenes/bench_ropes.tscn -- adapter=xpbd
##   godot --headless res://scenes/bench_ropes.tscn -- adapter=verlet
##
## Bare (no args): both, back to back, so the two tables sit next to each
## other for a direct read — the point of a shared bench is that "the new one
## is better" has to be a number in this same table, not a separate run
## someone has to remember to compare by hand.

const KNOWN_ADAPTERS := ["verlet", "xpbd"]


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	for name: String in _requested_adapters():
		var bench := RopeBench.new()
		add_child(bench)
		await bench.run_all(_make_adapter(name))
		bench.queue_free()
	get_tree().quit(0)


func _requested_adapters() -> Array[String]:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("adapter="):
			var name := a.substr(8)
			if KNOWN_ADAPTERS.has(name):
				return [name]
			push_warning("run_rope_bench: unknown adapter '%s', running both" % name)
	return KNOWN_ADAPTERS


func _make_adapter(name: String) -> Object:
	if name == "xpbd":
		return RopeBenchXpbdAdapter.new()
	return RopeBenchVerletAdapter.new()
