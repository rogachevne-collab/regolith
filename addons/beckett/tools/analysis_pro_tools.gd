@tool
extends RefCounted
class_name BeckettAnalysisProTools

## Premium (L4) project analysis — unused-resource detection and circular-dependency
## detection. Split out of analysis_tools.gd so the Lite build ships ZERO tier-3+ code:
## this whole file is trimmed by pack.ps1. The small file-walk helpers are duplicated
## from analysis_tools on purpose — premium modules must be self-contained (no imports
## from files that might be reorganized in the core layer).

var server

const _SKIP_DIRS := [".godot", ".git", ".import"]
const _ASSET_EXTS := ["tres", "res", "png", "jpg", "jpeg", "webp", "svg", "bmp", "ogg", "wav", "mp3", "glb", "gltf", "obj", "fbx", "ttf", "otf", "fnt", "atlastex", "exr", "hdr"]
const _TEXT_EXTS := ["gd", "tscn", "tres", "cfg", "godot", "json", "gdshader"]
const _MAX_FILES := 6000


func _register(registry) -> void:
	registry.register({
		"name": "find_unused_resources",
		"description": "Heuristic: asset files (.tres/.png/.ogg/.glb/...) whose res:// path AND UID appear in no other text file (.gd/.tscn/.tres/project.godot). HEURISTIC — assets loaded via a built/dynamic string path are false positives; verify before deleting. 'ext' restricts to one extension; 'max' caps results.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"ext": {"type": "string"}, "max": {"type": "integer"},
		}},
		"handler": Callable(self, "_unused"),
	})
	registry.register({
		"name": "detect_circular_dependencies",
		"description": "Build a dependency graph from preload()/load(\"res://...\") + extends \"res://...\" in .gd and [ext_resource path=\"res://...\"] in .tscn/.tres, then report cycles. Catches real load-time cycles; does NOT track class_name references.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {}},
		"handler": Callable(self, "_circular"),
	})



func _unused(args: Dictionary) -> Dictionary:
	var only_ext := str(args.get("ext", "")).to_lower()
	var maxn := clampi(int(args.get("max", 100)), 1, 1000)
	var candidates := _all_files([only_ext] if not only_ext.is_empty() else _ASSET_EXTS)
	var corpus: Dictionary = {}
	for tf in _all_files(_TEXT_EXTS):
		corpus[tf] = FileAccess.get_file_as_string(tf)
	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	var unused: Array = []
	for c in candidates:
		if c == main_scene:
			continue
		var uid := ""
		if ResourceLoader.has_method("get_resource_uid"):
			var id: int = ResourceLoader.get_resource_uid(c)
			if id != -1:
				uid = ResourceUID.id_to_text(id)
		var referenced := false
		for tf in corpus:
			if tf == c:
				continue
			var content: String = corpus[tf]
			if content.contains(c) or (not uid.is_empty() and content.contains(uid)):
				referenced = true
				break
		if not referenced:
			unused.append(c)
			if unused.size() >= maxn:
				break
	return {"json": {
		"count": unused.size(),
		"unused": unused,
		"note": "Heuristic by path/UID reference. Assets loaded via a constructed/dynamic string path will be false positives — verify before deleting.",
	}}



func _circular(_args: Dictionary) -> Dictionary:
	var re_load := RegEx.new()
	re_load.compile("(?:preload|load)\\s*\\(\\s*\"(res://[^\"]+)\"")
	var re_extends := RegEx.new()
	re_extends.compile("^\\s*extends\\s+\"(res://[^\"]+)\"")
	var re_ext_res := RegEx.new()
	re_ext_res.compile("\\[ext_resource[^\\]]*path=\"(res://[^\"]+)\"")
	var graph: Dictionary = {}
	for f in _all_files(["gd", "tscn", "tres"]):
		var content := FileAccess.get_file_as_string(f)
		var deps: Array = []
		if f.get_extension().to_lower() == "gd":
			for m in re_load.search_all(content):
				_add(deps, m.get_string(1))
			var em := re_extends.search(content)
			if em != null:
				_add(deps, em.get_string(1))
		else:
			for m in re_ext_res.search_all(content):
				_add(deps, m.get_string(1))
		graph[f] = deps
	var cycles: Array = []
	var state: Dictionary = {}
	var stack: Array = []
	var seen: Dictionary = {}
	for node in graph:
		_dfs(node, graph, state, stack, cycles, seen)
	return {"json": {
		"count": cycles.size(),
		"cycles": cycles,
		"note": "Edges from preload/load/extends and scene ext_resource paths only; class_name references are not tracked.",
	}}


func _dfs(node: String, graph: Dictionary, state: Dictionary, stack: Array, cycles: Array, seen: Dictionary) -> void:
	if int(state.get(node, 0)) != 0:
		return
	state[node] = 1
	stack.push_back(node)
	for dep in graph.get(node, []):
		if not graph.has(dep):
			continue
		var ds := int(state.get(dep, 0))
		if ds == 1:
			var idx := stack.find(dep)
			if idx != -1:
				var cyc: Array = stack.slice(idx)
				cyc.append(dep)
				var key: Array = cyc.duplicate()
				key.sort()
				var ks := "|".join(key)
				if not seen.has(ks):
					seen[ks] = true
					cycles.append(cyc)
		elif ds == 0:
			_dfs(dep, graph, state, stack, cycles, seen)
	stack.pop_back()
	state[node] = 2



func _all_files(exts: Array) -> Array:
	var out: Array = []
	_walk("res://", exts, out)
	return out


func _walk(path: String, exts: Array, out: Array) -> void:
	if out.size() >= _MAX_FILES:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if e == "." or e == "..":
			e = dir.get_next()
			continue
		var full := path.path_join(e)
		if dir.current_is_dir():
			if not _SKIP_DIRS.has(e):
				_walk(full, exts, out)
		elif exts.is_empty() or exts.has(e.get_extension().to_lower()):
			out.append(full)
		if out.size() >= _MAX_FILES:
			break
		e = dir.get_next()
	dir.list_dir_end()


func _add(arr: Array, v: String) -> void:
	if not arr.has(v):
		arr.append(v)
