extends Node
## Headless playtest runner (v1.8, CI / regression). Plays every res://tests/playtests/*.json,
## replays each DETERMINISTICALLY (frame-anchored input injection), checks its asserts, and quits
## with a NON-ZERO exit code if any suite fails. Run it OUTSIDE the editor, e.g.:
##
##   godot --headless --path <project> res://addons/beckett/runtime/playtest_runner.tscn
##
## node_state / expr / screen_text asserts work headless; screenshot asserts need an RHI, so they
## are SKIPPED (with a note) here rather than failing the suite. Perf asserts (v1.9) follow the
## same honest split: memory_/orphan_ metrics are simulation-side and evaluate everywhere, but
## frame_ms_/fps_/draw_calls_ metrics reflect rendering cost -- meaningless without an RHI -- so
## they are SKIPPED when the runner is headless (run those in-editor via playtest op=run, or run
## this scene windowed). The replay algorithm mirrors mcp_runtime's game-side window; _build_event
## mirrors mcp_runtime._build_event and _perf_summary mirrors mcp_runtime._replay_perf_summary --
## kept local so the runner is a self-contained standalone tool with no editor/bridge dependency
## (the places event construction + perf capture are duplicated; extend both sides together).

const PLAYTEST_DIR := "res://tests/playtests"
const SETTLE_FRAMES := 8

var _queue: Array = []
var _qi := -1
var _phase := "idle"
var _doc: Dictionary = {}
var _events: Array = []
var _ei := 0
var _tick := 0
var _end := 0
var _scene: Node = null
var _suites_total := 0
var _suites_failed := 0
var _perf_ms := PackedFloat64Array()
var _perf_fps := PackedFloat64Array()
var _perf_mem0 := 0.0
var _perf_orphan0 := 0.0


func _ready() -> void:
	print("[playtest] headless runner scanning %s" % PLAYTEST_DIR)
	_queue = _scan()
	_suites_total = _queue.size()
	if _queue.is_empty():
		print("[playtest] no suites found -- nothing to run")
		get_tree().quit(0)
		return
	print("[playtest] %d suite(s) to run" % _suites_total)
	_advance()


func _scan() -> Array:
	var out: Array = []
	var dir := DirAccess.open(PLAYTEST_DIR)
	if dir == null:
		return out
	var names: Array = []
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if not dir.current_is_dir() and e.get_extension() == "json":
			names.append(e)
		e = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for n in names:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/%s" % [PLAYTEST_DIR, n]))
		if parsed is Dictionary:
			out.append(parsed)
		else:
			print("[playtest] SKIP %s: not valid JSON" % n)
	return out


func _advance() -> void:
	if _scene != null and is_instance_valid(_scene):
		_scene.queue_free()
		_scene = null
	_qi += 1
	if _qi >= _queue.size():
		_finish()
		return
	_doc = _queue[_qi]
	var scene_path := str(_doc.get("scene", ""))
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		print("[playtest] FAIL %s: scene '%s' not found" % [_doc.get("name", "?"), scene_path])
		_suites_failed += 1
		call_deferred("_advance")
		return
	_scene = (load(scene_path) as PackedScene).instantiate()
	add_child(_scene)
	var evs: Array = _doc.get("events", []) if _doc.get("events", []) is Array else []
	evs = evs.duplicate()
	evs.sort_custom(func(a, b): return int(a.get("f", 0)) < int(b.get("f", 0)))
	_events = evs
	_ei = 0
	_tick = 0
	var last_f := 0
	if evs.size() > 0:
		last_f = int(evs[-1].get("f", 0))
	_end = last_f + SETTLE_FRAMES
	_perf_ms = PackedFloat64Array()
	_perf_fps = PackedFloat64Array()
	_perf_mem0 = Performance.get_monitor(Performance.MEMORY_STATIC)
	_perf_orphan0 = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	_phase = "replay"


func _physics_process(_delta: float) -> void:
	if _phase != "replay":
		return
	_perf_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_perf_fps.append(Performance.get_monitor(Performance.TIME_FPS))
	while _ei < _events.size():
		var ev: Dictionary = _events[_ei]
		if int(ev.get("f", 0)) > _tick:
			break
		var ie := _build_event(ev)
		if ie != null:
			Input.parse_input_event(ie)
		_ei += 1
	_tick += 1
	if _ei >= _events.size() and _tick > _end:
		_phase = "assert"
		_run_asserts()
		call_deferred("_advance")


func _run_asserts() -> void:
	var nm := str(_doc.get("name", "?"))
	var asserts: Array = _doc.get("asserts", []) if _doc.get("asserts", []) is Array else []
	var p := 0
	var f := 0
	var details: Array = []
	for a in asserts:
		if not (a is Dictionary):
			continue
		var r := _eval_assert(a)
		details.append("      [%s] %s" % [str(r.get("status", "?")), str(r.get("detail", ""))])
		match str(r.get("status", "")):
			"pass": p += 1
			"fail": f += 1
	if f > 0:
		_suites_failed += 1
	print("[playtest] %s %s  (%d/%d asserts passed)" % [("FAIL" if f > 0 else "ok  "), nm, p, p + f])
	var perf := _perf_summary()
	if not perf.is_empty():
		print("      perf: frames=%d frame_ms avg=%.2f p95=%.2f max=%.2f | mem_delta=%d orphan_delta=%d%s" % [
			int(perf.get("frames", 0)), float(perf.get("frame_ms_avg", 0.0)), float(perf.get("frame_ms_p95", 0.0)),
			float(perf.get("frame_ms_max", 0.0)), int(perf.get("memory_delta", 0)), int(perf.get("orphan_delta", 0)),
			" (headless: frame/fps figures are render-less)" if _is_headless() else ""])
	for d in details:
		print(d)


func _eval_assert(a: Dictionary) -> Dictionary:
	match str(a.get("type", "")).to_lower():
		"node_state":
			var n := _scene.get_node_or_null(NodePath(str(a.get("target", ""))))
			if n == null:
				return {"status": "fail", "detail": "node_state: node not found '%s'" % str(a.get("target", ""))}
			var actual: Variant = n.get(str(a.get("property", "")))
			if _values_equal(actual, a.get("equals")):
				return {"status": "pass", "detail": "node_state %s.%s == %s" % [str(a.get("target", "")), str(a.get("property", "")), str(a.get("equals"))]}
			return {"status": "fail", "detail": "node_state %s.%s = %s (want %s)" % [str(a.get("target", "")), str(a.get("property", "")), str(actual), str(a.get("equals"))]}
		"expr":
			var ex := Expression.new()
			if ex.parse(str(a.get("condition", ""))) != OK:
				return {"status": "fail", "detail": "expr parse: %s" % ex.get_error_text()}
			var v: Variant = ex.execute([], _scene, true)
			if ex.has_execute_failed():
				return {"status": "fail", "detail": "expr exec: %s" % ex.get_error_text()}
			if bool(v):
				return {"status": "pass", "detail": "expr %s -> true" % str(a.get("condition", ""))}
			return {"status": "fail", "detail": "expr %s -> %s" % [str(a.get("condition", "")), str(v)]}
		"screen_text":
			if _find_text(_scene, str(a.get("text", ""))):
				return {"status": "pass", "detail": "screen_text found '%s'" % str(a.get("text", ""))}
			return {"status": "fail", "detail": "screen_text '%s' not found" % str(a.get("text", ""))}
		"screenshot":
			return {"status": "skip", "detail": "screenshot skipped (headless: no RHI)"}
		"perf":
			return _eval_perf_assert(a)
		_:
			return {"status": "skip", "detail": "unknown assert type '%s'" % str(a.get("type", ""))}


## Perf assert: {type:"perf", metric:<flat key>, max:<num>[, min:<num>]}. Metrics come from
## _perf_summary(). Rendering-cost metrics (frame_ms_*/fps_*/draw_calls_*) are skipped when
## headless -- a render-less loop's frame numbers would vacuously pass and teach nothing.
func _eval_perf_assert(a: Dictionary) -> Dictionary:
	var metric := str(a.get("metric", ""))
	if _is_headless() and (metric.begins_with("frame_ms") or metric.begins_with("fps") or metric.begins_with("draw_calls")):
		return {"status": "skip", "detail": "perf %s skipped (headless: no RHI, rendering cost not measured) -- run in-editor via playtest op=run" % metric}
	var perf := _perf_summary()
	if not perf.has(metric):
		return {"status": "fail", "detail": "perf: unknown metric '%s' (have: %s)" % [metric, ", ".join(PackedStringArray(perf.keys()))]}
	if not (a.has("max") or a.has("min")):
		return {"status": "fail", "detail": "perf %s: assert needs 'max' and/or 'min'" % metric}
	var value := float(perf[metric])
	if a.has("max") and value > float(a.get("max")):
		return {"status": "fail", "detail": "perf %s = %.2f > max %.2f" % [metric, value, float(a.get("max"))]}
	if a.has("min") and value < float(a.get("min")):
		return {"status": "fail", "detail": "perf %s = %.2f < min %.2f" % [metric, value, float(a.get("min"))]}
	var bound := ("max %.2f" % float(a.get("max"))) if a.has("max") else ("min %.2f" % float(a.get("min")))
	return {"status": "pass", "detail": "perf %s = %.2f within %s" % [metric, value, bound]}


func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


## Flat perf summary of the replay just run (mirrors mcp_runtime._replay_perf_summary; {} if
## nothing sampled). Same keys as the editor-side capture so suites assert one metric name
## everywhere: frames, frame_ms_min/avg/p95/max, fps_min/avg, memory_static_end, memory_delta,
## orphan_delta, draw_calls_end.
func _perf_summary() -> Dictionary:
	if _perf_ms.is_empty():
		return {}
	var by_ms := _perf_ms.duplicate()
	by_ms.sort()
	var n := by_ms.size()
	var total := 0.0
	for v in by_ms:
		total += v
	var fps_total := 0.0
	var fps_min := 0.0
	for i in _perf_fps.size():
		fps_total += _perf_fps[i]
		if i == 0 or _perf_fps[i] < fps_min:
			fps_min = _perf_fps[i]
	return {
		"frames": n,
		"frame_ms_min": by_ms[0],
		"frame_ms_avg": total / float(n),
		"frame_ms_p95": by_ms[clampi(int(ceil(float(n) * 0.95)) - 1, 0, n - 1)],
		"frame_ms_max": by_ms[n - 1],
		"fps_min": fps_min,
		"fps_avg": fps_total / float(maxi(1, _perf_fps.size())),
		"memory_static_end": Performance.get_monitor(Performance.MEMORY_STATIC),
		"memory_delta": Performance.get_monitor(Performance.MEMORY_STATIC) - _perf_mem0,
		"orphan_delta": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _perf_orphan0,
		"draw_calls_end": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
	}


func _find_text(node: Node, needle: String) -> bool:
	if needle == "":
		return false
	var t: Variant = node.get("text")
	if t is String and (t as String).findn(needle) != -1:
		return true
	for c in node.get_children():
		if _find_text(c, needle):
			return true
	return false


func _finish() -> void:
	var passed := _suites_total - _suites_failed
	print("[playtest] === %d/%d suites passed ===" % [passed, _suites_total])
	get_tree().quit(1 if _suites_failed > 0 else 0)


func _build_event(e: Dictionary) -> InputEvent:
	match str(e.get("type", "")):
		"key":
			var k := InputEventKey.new()
			var kc: int = OS.find_keycode_from_string(str(e.get("keycode", "")))
			k.keycode = kc
			k.physical_keycode = kc
			k.pressed = bool(e.get("pressed", true))
			return k
		"action":
			var a := InputEventAction.new()
			a.action = StringName(str(e.get("action", "")))
			a.pressed = bool(e.get("pressed", true))
			a.strength = float(e.get("strength", 1.0)) if e.get("pressed", true) else 0.0
			return a
		"mouse_button":
			var mb := InputEventMouseButton.new()
			mb.button_index = int(e.get("button", 1))
			mb.pressed = bool(e.get("pressed", true))
			mb.position = _vec2(e.get("position", [0, 0]))
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			mm.position = _vec2(e.get("position", [0, 0]))
			mm.relative = _vec2(e.get("relative", [0, 0]))
			return mm
		"joy_button":
			var jb := InputEventJoypadButton.new()
			jb.button_index = int(e.get("button", 0))
			jb.pressed = bool(e.get("pressed", true))
			jb.device = int(e.get("device", 0))
			return jb
		"joy_axis":
			var ja := InputEventJoypadMotion.new()
			ja.axis = int(e.get("axis", 0))
			ja.axis_value = clampf(float(e.get("value", 0.0)), -1.0, 1.0)
			ja.device = int(e.get("device", 0))
			return ja
		"touch":
			var st := InputEventScreenTouch.new()
			st.index = int(e.get("index", 0))
			st.position = _vec2(e.get("position", [0, 0]))
			st.pressed = bool(e.get("pressed", true))
			return st
		"touch_drag":
			var sd := InputEventScreenDrag.new()
			sd.index = int(e.get("index", 0))
			sd.position = _vec2(e.get("position", [0, 0]))
			sd.relative = _vec2(e.get("relative", [0, 0]))
			return sd
		_:
			return null


func _vec2(v: Variant) -> Vector2:
	if v is Array and (v as Array).size() >= 2:
		return Vector2(v[0], v[1])
	if v is Dictionary:
		return Vector2(v.get("x", 0), v.get("y", 0))
	return Vector2.ZERO


## Numeric-tolerant equality (mirrors playtest_tools): int property read (1) must match a
## JSON-loaded float expected (1.0), since JSON parsing makes every number a float.
func _values_equal(actual: Variant, expected: Variant) -> bool:
	if (actual is int or actual is float) and (expected is int or expected is float):
		return is_equal_approx(float(actual), float(expected))
	return str(actual) == str(expected)
