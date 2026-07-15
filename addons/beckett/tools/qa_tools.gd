@tool
extends RefCounted
class_name BeckettQaTools

## QA / assertions (P1) — the verify half of the autonomous loop. Assertions return a
## clear PASS, or surface an error so the agent notices a failure and fixes it.

const Reflect := preload("res://addons/beckett/core/reflection.gd")

var server


func _register(registry) -> void:
	registry.register({
		"name": "assert_node_state",
		"description": "Assert a node's property equals an expected value. Checks the open scene by default; set runtime=true to check the running game. Fails loudly (error) if it doesn't match.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string"}, "property": {"type": "string"},
			"equals": {}, "runtime": {"type": "boolean"},
		}, "required": ["target", "property", "equals"]},
		"handler": Callable(self, "_assert_node_state"),
	})
	registry.register({
		"name": "assert_screen_text",
		"description": "Assert that some visible UI node in the running game has text containing the given string.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"text": {"type": "string"},
		}, "required": ["text"]},
		"handler": Callable(self, "_assert_screen_text"),
	})
	registry.register({
		"name": "compare_screenshots",
		"description": "Capture the running game and compare against a baseline PNG (res:// or user://). First run (or save_baseline=true) saves the baseline; later runs return a diff %% and pass/fail vs tolerance. Needs a non-headless play session (RHI).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"baseline": {"type": "string", "description": "res:// or user:// PNG path"},
			"tolerance": {"type": "number", "description": "max diff %% to pass (default 2.0)"},
			"save_baseline": {"type": "boolean"},
		}, "required": ["baseline"]},
		"handler": Callable(self, "_compare_screenshots"),
	})
	registry.register({
		"name": "assert_scene",
		"description": "Assert a SAVED scene file has the structure you expect: at least min_nodes nodes, every class in require_types present, and (optionally) that it is the project's main scene. Reads the .tscn from disk — cannot be faked from chat — so it's the objective gate after building or generating any scene.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"scene": {"type": "string", "description": "scene path (default: application/run/main_scene)"},
			"min_nodes": {"type": "integer", "description": "minimum node count (default 1)"},
			"require_types": {"type": "array", "items": {"type": "string"}, "description": "class names that MUST appear, e.g. [\"CharacterBody2D\",\"Area2D\"]"},
			"require_main_scene": {"type": "boolean", "description": "also assert this scene IS application/run/main_scene"},
		}},
		"handler": Callable(self, "_assert_scene"),
	})


func _assert_node_state(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", ""))
	var prop := str(args.get("property", ""))
	var actual: Variant
	if bool(args.get("runtime", false)):
		var r: Dictionary = server.bridge.send_command({"cmd": "get", "path": target, "prop": prop})
		if not bool(r.get("ok", false)):
			return {"error": str(r.get("error", "runtime get failed"))}
		actual = r.get("value")
	else:
		var obj := Reflect.resolve(target)
		if obj == null:
			return {"error": "Could not resolve target: %s" % target}
		actual = Reflect.to_json_safe(obj.get(prop))
	var expected: Variant = args.get("equals")
	if str(actual) == str(expected):
		return {"text": "PASS: %s.%s == %s" % [target, prop, str(expected)]}
	return {"error": "assertion failed: %s.%s = %s (expected %s)" % [target, prop, str(actual), str(expected)]}


func _assert_screen_text(args: Dictionary) -> Dictionary:
	var text := str(args.get("text", ""))
	var r: Dictionary = server.bridge.send_command({"cmd": "find", "text": text, "max": 1})
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "game not running"))}
	var nodes: Array = r.get("nodes", [])
	if nodes.size() > 0:
		return {"text": "PASS: found '%s' on screen (%s)" % [text, str(nodes[0].get("path", ""))]}
	return {"error": "assertion failed: text '%s' not found on screen" % text}


func _assert_scene(args: Dictionary) -> Dictionary:
	var scene := str(args.get("scene", ""))
	var main_setting := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if scene.is_empty():
		scene = main_setting
	if scene.is_empty():
		return {"json": {"pass": false, "reasons": ["no 'scene' given and application/run/main_scene is not set"]}}

	var reasons: Array = []
	var main_scene_set := (main_setting == scene)
	if bool(args.get("require_main_scene", false)) and not main_scene_set:
		reasons.append("not the project main scene (application/run/main_scene = '%s')" % main_setting)
	if not ResourceLoader.exists(scene):
		return {"json": {"pass": false, "main_scene_set": main_scene_set,
			"reasons": ["scene file does not exist: %s" % scene]}}
	var ps := load(scene) as PackedScene
	if ps == null:
		return {"json": {"pass": false, "main_scene_set": main_scene_set,
			"reasons": ["could not load PackedScene: %s" % scene]}}

	var st := ps.get_state()
	var count := st.get_node_count()
	var types: Dictionary = {}
	for i in count:
		var t := str(st.get_node_type(i))
		if not t.is_empty():
			types[t] = true

	var min_nodes := int(args.get("min_nodes", 1))
	if count < min_nodes:
		reasons.append("scene has %d nodes (need >= %d)" % [count, min_nodes])

	var missing: Array = []
	var require: Variant = args.get("require_types", [])
	if require is Array:
		for r in require:
			if not types.has(str(r)):
				missing.append(str(r))
	if not missing.is_empty():
		reasons.append("missing required node types: %s" % ", ".join(missing))

	return {"json": {
		"pass": reasons.is_empty(),
		"scene": scene,
		"main_scene_set": main_scene_set,
		"node_count": count,
		"types_present": types.keys(),
		"missing_types": missing,
		"reasons": reasons,
	}}


func _compare_screenshots(args: Dictionary) -> Dictionary:
	var baseline := str(args.get("baseline", ""))
	if not (baseline.begins_with("res://") or baseline.begins_with("user://")):
		return {"error": "baseline must be a res:// or user:// path"}
	var r: Dictionary = server.bridge.send_command({"cmd": "screenshot"})
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "screenshot failed (needs a non-headless play session)"))}
	var cur := Image.new()
	if cur.load_png_from_buffer(Marshalls.base64_to_raw(str(r.get("png", "")))) != OK:
		return {"error": "could not decode screenshot"}
	if bool(args.get("save_baseline", false)) or not FileAccess.file_exists(baseline):
		if cur.save_png(baseline) != OK:
			return {"error": "could not save baseline to %s" % baseline}
		return {"text": "baseline saved to %s" % baseline}
	var base := Image.new()
	if base.load(baseline) != OK:
		return {"error": "could not load baseline: %s" % baseline}
	cur.resize(64, 64)
	base.resize(64, 64)
	cur.convert(Image.FORMAT_RGBA8)
	base.convert(Image.FORMAT_RGBA8)
	var cd := cur.get_data()
	var bd := base.get_data()
	var diff := 0
	for i in cd.size():
		diff += abs(int(cd[i]) - int(bd[i]))
	var pct := 100.0 * float(diff) / float(cd.size() * 255)
	var tol := float(args.get("tolerance", 2.0))
	return {"json": {"diff_pct": pct, "tolerance": tol, "pass": pct <= tol}}
