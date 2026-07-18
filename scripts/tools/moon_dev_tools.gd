class_name MoonDevTools
extends RefCounted

## Shared helpers for editor Tools → Regolith and headless scripts.

const PROGRESS_FILES := [
	"world_save.json",
	"moon.sqlite",
]


static func stream_dir() -> String:
	return MoonTerrainParams.stream_directory()


static func stream_dir_absolute() -> String:
	return ProjectSettings.globalize_path(stream_dir())


static func clear_progress(keep_heightmap: bool = true) -> Dictionary:
	var dir := stream_dir()
	var abs_dir := stream_dir_absolute()
	if not DirAccess.dir_exists_absolute(abs_dir):
		return {
			"ok": true,
			"removed": PackedStringArray(),
			"message": "nothing to clear (%s missing)" % dir,
		}

	var removed: PackedStringArray = []
	var to_remove: Array[String] = []
	to_remove.assign(PROGRESS_FILES)
	if not keep_heightmap:
		to_remove.append("crust_heightmap.exr")
		to_remove.append("generator_version.txt")

	for name in to_remove:
		var path := "%s/%s" % [dir, name]
		var abs_path := ProjectSettings.globalize_path(path)
		if not FileAccess.file_exists(abs_path):
			continue
		var err := DirAccess.remove_absolute(abs_path)
		if err != OK:
			return {
				"ok": false,
				"removed": removed,
				"message": "failed to remove %s (err=%d)" % [path, err],
			}
		removed.append(path)

	var kept := MoonHeightmapUtil.heightmap_path()
	var msg := ""
	if removed.is_empty():
		msg = "no progress files found in %s" % dir
	else:
		msg = "removed %s" % ", ".join(removed)
	if keep_heightmap:
		if FileAccess.file_exists(ProjectSettings.globalize_path(kept)):
			msg += "; kept heightmap %s" % kept
		else:
			msg += "; no heightmap at %s (will bake on next run)" % kept
	return {"ok": true, "removed": removed, "message": msg}


static func rebake_heightmap(
	width: int = 2048,
	height: int = 1024
) -> Dictionary:
	var hm_path := MoonHeightmapUtil.heightmap_path()
	var abs_path := MoonHeightmapUtil.absolute_heightmap_path()
	if FileAccess.file_exists(abs_path):
		var err := DirAccess.remove_absolute(abs_path)
		if err != OK:
			return {
				"ok": false,
				"message": "failed to remove %s (err=%d)" % [hm_path, err],
			}
	var version_path := "%s/generator_version.txt" % abs_path.get_base_dir()
	if FileAccess.file_exists(version_path):
		DirAccess.remove_absolute(version_path)

	var t0 := Time.get_ticks_msec()
	var img := MoonHeightmapUtil.bake_heightmap(width, height, abs_path)
	if img == null or img.get_width() <= 0:
		return {"ok": false, "message": "bake failed for %s" % hm_path}
	var ms := Time.get_ticks_msec() - t0
	var native := ClassDB.class_exists("MoonHeightmapBake")
	return {
		"ok": true,
		"message": (
			"rebaked %s (%dx%d) in %d ms%s"
			% [
				hm_path,
				img.get_width(),
				img.get_height(),
				ms,
				" (native)" if native else " (GDScript)",
			]
		),
	}


static func open_stream_folder() -> Dictionary:
	var abs_dir := stream_dir_absolute()
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)
	OS.shell_show_in_file_manager(abs_dir, true)
	return {"ok": true, "message": "opened %s" % abs_dir}
