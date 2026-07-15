@tool
extends RefCounted
class_name BeckettTestTools

## Lightweight GDScript test runner (D-tier QA). Discovers test scripts, instantiates each,
## runs its `test_*` methods, and reports per-test pass/fail — the close-the-loop check the
## agent can write and run itself without pulling in an external framework. Failures are
## collected (via BeckettTestCase assertions or a returned message/false), never thrown, so one
## bad test can't abort the run.
##
## (logs_read used to live here; it moved to run_tools.gd when the L3 run loop
## became core — the Lite build ships it too.)

var server


func _register(registry) -> void:
	registry.register({
		"name": "test_run",
		"description": "Run lightweight GDScript tests and report pass/fail. Target a single 'script' (res://*.gd) or scan a 'path' dir (default: res://test + res://tests) for files named test_*.gd or *_test.gd. A test is a method named test_* on the script. Report failures WITHOUT crashing in one of two ways: (a) extend BeckettTestCase and call assert_eq/assert_true/assert_almost_eq/etc., or (b) return a non-empty String (the message) or false from the method. Never use the built-in assert() — it crashes the debug editor.",
		"input_schema": {"type": "object", "properties": {
			"script": {"type": "string", "description": "a single res:// .gd test file"},
			"path": {"type": "string", "description": "directory to scan (default res://test + res://tests)"},
		}},
		"handler": Callable(self, "_test_run"),
	})


func _test_run(args: Dictionary) -> Dictionary:
	var scripts: Array = []
	if args.has("script") and not str(args["script"]).is_empty():
		scripts.append(str(args["script"]))
	elif args.has("path") and not str(args["path"]).is_empty():
		_collect(str(args["path"]), scripts)
	else:
		for d in ["res://test", "res://tests"]:
			if DirAccess.dir_exists_absolute(d):
				_collect(d, scripts)
	if scripts.is_empty():
		return {"error": "No test scripts found.",
			"suggestion": "Pass script=res://my_test.gd, or put test_*.gd files under res://test/."}

	var suites: Array = []
	var tot_pass := 0
	var tot_fail := 0
	for sp in scripts:
		var suite := _run_suite(sp)
		suites.append(suite)
		tot_pass += int(suite.get("passed", 0))
		tot_fail += int(suite.get("failed", 0))
	return {"json": {
		"passed": tot_pass,
		"failed": tot_fail,
		"ok": tot_fail == 0,
		"suites": suites,
	}}



func _collect(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if e != "." and e != "..":
			var full := dir_path.path_join(e)
			if dir.current_is_dir():
				if e != ".godot":
					_collect(full, out)
			elif e.get_extension() == "gd" and (e.begins_with("test_") or e.ends_with("_test.gd")):
				out.append(full)
		e = dir.get_next()
	dir.list_dir_end()


func _run_suite(path: String) -> Dictionary:
	var suite: Dictionary = {"script": path, "tests": [], "passed": 0, "failed": 0}
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		return _suite_error(suite, "no file at %s" % path)
	var gd: Variant = load(path)
	if not (gd is GDScript):
		return _suite_error(suite, "not a GDScript")
	var inst: Variant = (gd as GDScript).new()
	if inst == null:
		return _suite_error(suite, "could not instantiate (does _init() need arguments?)")

	var names: Array = []
	for m in inst.get_method_list():
		var n := String(m.get("name", ""))
		if n.begins_with("test_") and not names.has(n):
			names.append(n)
	names.sort()

	var has_collector: bool = inst.has_method("_mcp_get_failures")
	var has_reset: bool = inst.has_method("_mcp_reset")
	for n in names:
		if has_reset:
			inst._mcp_reset()
		var ret: Variant = inst.call(n)
		var fails: Array = []
		if has_collector:
			for f in inst._mcp_get_failures():
				fails.append(str(f))
		if ret is String and ret != "":
			fails.append(ret)
		elif ret is bool and ret == false:
			fails.append("test returned false")
		var ok := fails.is_empty()
		suite["tests"].append({"name": n, "ok": ok, "messages": fails})
		if ok:
			suite["passed"] = int(suite["passed"]) + 1
		else:
			suite["failed"] = int(suite["failed"]) + 1

	if inst is Node:
		(inst as Node).free()
	return suite


func _suite_error(suite: Dictionary, msg: String) -> Dictionary:
	suite["tests"].append({"name": "(load)", "ok": false, "messages": [msg]})
	suite["failed"] = 1
	return suite
