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
		var scr: Script = load(path) as Script
		if scr == null:
			push_warning("failed to load %s" % path)
			continue
		if scr.has_method("reload"):
			pass  # load is enough
	print("dump_gdscript_warnings: done")
	quit(0)


func _collect_gd(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := "%s/%s" % [dir_path, name]
		if dir.current_is_dir():
			_collect_gd(full, out)
		elif name.ends_with(".gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
