extends SceneTree

## Force-reload project scripts so Godot prints GDScript analyzer warnings.
## ./run.sh --headless -s res://scripts/tools/dump_gdscript_warnings.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var roots: PackedStringArray = ["res://scripts"]
	var paths: PackedStringArray = []
	for root in roots:
		_collect_gd(root, paths)
	paths.sort()
	print("dump_gdscript_warnings: reloading %d scripts..." % paths.size())
	for path in paths:
		var scr: GDScript = load(path) as GDScript
		if scr == null:
			push_warning("failed to load %s" % path)
			continue
		scr.reload()
	print("dump_gdscript_warnings: done")
	quit(0)


func _collect_gd(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if entry_name.begins_with("."):
			entry_name = dir.get_next()
			continue
		var full := "%s/%s" % [dir_path, entry_name]
		if dir.current_is_dir():
			_collect_gd(full, out)
		elif entry_name.ends_with(".gd"):
			out.append(full)
		entry_name = dir.get_next()
	dir.list_dir_end()
