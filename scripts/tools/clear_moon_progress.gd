extends SceneTree

## Clear moon progress (digs, instances, player/build save) but keep crust heightmap.
## Run: ./run.sh --headless --script res://scripts/tools/clear_moon_progress.gd

const PROGRESS_FILES := [
	"world_save.json",
	"moon.sqlite",
]


func _init() -> void:
	var dir := MoonTerrainParams.stream_directory()
	var abs_dir := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs_dir):
		print("clear_moon_progress: nothing to clear (%s missing)" % dir)
		quit(0)
		return
	var removed: Array[String] = []
	for name in PROGRESS_FILES:
		var path := "%s/%s" % [dir, name]
		var abs_path := ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			var err := DirAccess.remove_absolute(abs_path)
			if err != OK:
				push_error("clear_moon_progress: failed to remove %s (err=%d)" % [path, err])
				quit(1)
				return
			removed.append(path)
	var kept := MoonHeightmapUtil.heightmap_path()
	if FileAccess.file_exists(ProjectSettings.globalize_path(kept)):
		print("clear_moon_progress: kept heightmap %s" % kept)
	else:
		print("clear_moon_progress: no heightmap at %s (will bake on next run)" % kept)
	if removed.is_empty():
		print("clear_moon_progress: no progress files found in %s" % dir)
	else:
		print("clear_moon_progress: removed %s" % ", ".join(removed))
	quit(0)
