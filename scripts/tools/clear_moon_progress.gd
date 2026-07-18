extends SceneTree

## Clear moon progress (digs, instances, player/build save) but keep crust heightmap.
## Run: ./run.sh --headless --script res://scripts/tools/clear_moon_progress.gd
## Editor: Project → Tools → Regolith → Clear Save

const _DevTools := preload("res://scripts/tools/moon_dev_tools.gd")


func _init() -> void:
	var result: Dictionary = _DevTools.clear_progress(true)
	var prefix := "clear_moon_progress: "
	if result.get("ok", false):
		print(prefix + str(result.get("message", "")))
		quit(0)
	else:
		push_error(prefix + str(result.get("message", "failed")))
		quit(1)
