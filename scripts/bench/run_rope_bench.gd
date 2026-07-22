extends Node3D
## Runner: builds the bench, points it at whichever rope implementation is
## being judged, prints the table and exits. Headless-friendly.
##
##   godot --headless res://scenes/bench_ropes.tscn

func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var bench := RopeBench.new()
	add_child(bench)
	await bench.run_all(RopeBenchVerletAdapter.new())
	get_tree().quit(0)
