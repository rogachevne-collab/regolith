@tool
extends RefCounted
class_name BeckettSkillTools

## Skills (B5) — lazy-loaded Markdown knowledge packs. The answer to per-domain tool
## sprawl: instead of 6–8 wrappers per subsystem (which go stale), a pack names the exact
## classes/properties/methods + the good path, and the agent drives it with the reflection
## tools. "Curated knowledge, not curated code." Bundled packs ship in the addon; a project
## can add or override packs under res://.beckett/skills/.

var server

const BUNDLED_DIR := "res://addons/beckett/skills"
const PROJECT_DIR := "res://.beckett/skills"


func _register(registry) -> void:
	registry.register({
		"name": "list_skills",
		"description": "List available knowledge packs (name + one-line summary). Load one with load_skill to learn the exact classes/methods for a domain, then drive it with the reflection tools.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_list_skills"),
	})
	registry.register({
		"name": "load_skill",
		"description": "Load a knowledge pack's Markdown by name (e.g. particles, animation, signals, ui). Project packs under res://.beckett/skills/ override bundled ones.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"name": {"type": "string"},
		}, "required": ["name"]},
		"handler": Callable(self, "_load_skill"),
	})


func _list_skills(_args: Dictionary) -> Dictionary:
	var packs: Dictionary = {}
	_scan(BUNDLED_DIR, "bundled", packs)
	_scan(PROJECT_DIR, "project", packs)
	var names := packs.keys()
	names.sort()
	var out: Array = []
	for n in names:
		out.append(packs[n])
	return {"json": {"count": out.size(), "skills": out}}


func _scan(dir_path: String, source: String, packs: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.ends_with(".md"):
			var name := f.get_basename()
			packs[name] = {"name": name, "summary": _summary(dir_path.path_join(f)), "source": source}


func _summary(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	for line in text.split("\n"):
		var l := line.strip_edges()
		if l.is_empty() or l.begins_with("#"):
			continue
		return l.trim_prefix("> ").strip_edges()
	return ""


func _load_skill(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", ""))
	var proj := PROJECT_DIR.path_join(name + ".md")
	var bundled := BUNDLED_DIR.path_join(name + ".md")
	var path := proj if FileAccess.file_exists(proj) else bundled
	if not FileAccess.file_exists(path):
		return {"error": "No skill named '%s'." % name, "suggestion": "Call list_skills to see available packs."}
	return {"text": FileAccess.get_file_as_string(path)}
