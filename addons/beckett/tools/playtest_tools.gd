@tool
extends RefCounted
class_name BeckettPlaytestTools

## Playtest suites (L5, Full): turn a recorded input run + asserts into a durable, rerunnable
## regression asset. `playtest op=save` writes res://tests/playtests/<name>.json; `op=run`
## replays it DETERMINISTICALLY (frame-stepped, game-side replay window) into the live game and
## evaluates its asserts; `op=list`/`op=show` inspect saved playtests.
##
## The run assumes the game is ALREADY playing and connected (play_scene -> wait_until
## game_connected first): a handler can't launch the game and wait for the runtime bridge in
## one synchronous call — that starves the main-thread frames the launch needs, the same reason
## wait_until yields (see run_tools.gd). Replay + asserts against a *connected* game are plain
## bridge round-trips, so they fit one handler.
##
## Full-only: pack.ps1 trims this module from the free Lite build (in $liteTrimModules), and
## `playtest` is in $premiumToolNames so the leak gate catches a stray registration. Classified
## L5 in effort.gd _DELTA.

const PLAYTEST_DIR := "res://tests/playtests"
const SCHEMA_VERSION := 1
const MCPJobsScript := preload("res://addons/beckett/core/jobs.gd")

var server


func _register(registry) -> void:
	registry.register({
		"name": "playtest",
		"description": "Save and rerun PLAYTESTS — a recorded input run + asserts, persisted under res://tests/playtests/ and replayable as a regression test. ops: save {name, scene, events (from record_input action=stop, or hand-authored), asserts} writes the file; run {name, deterministic=true, settle_frames=4, save_baseline=false} replays it into the RUNNING game (play_scene -> wait_until game_connected FIRST) and checks its asserts, returning pass/fail; list enumerates saved playtests; show {name} dumps one. Deterministic replay frame-steps a game-side window (needs events recorded in Beckett 1.8+, which carry a frame stamp 'f'); it falls back to back-to-back replay for older/hand-authored events. Assert types: {type:node_state,target,property,equals} | {type:screen_text,text} | {type:expr,condition:\"get_node('Player').position.y<500\"} | {type:screenshot,baseline,tolerance} (RHI-only: skipped with a warning when headless) | {type:perf,metric,max,min} (v1.9). PERF: a deterministic run also MEASURES the window (Performance monitors, never modeled) and returns flat stats — frames, frame_ms_min/avg/p95/max, fps_min/avg, memory_static_end, memory_delta, orphan_delta, draw_calls_end — as result.perf; perf asserts bound any of those (e.g. {type:perf,metric:frame_ms_p95,max:16.7} = a 60fps frame budget; frame/fps/draw metrics skip if the game is headless). save_baseline=true stamps this run's stats into the suite; later runs return result.perf_diff (per-metric baseline/current/delta/delta_pct) — the optimize loop: baseline, change code, rerun, read the diff. The run leaves the game FROZEN so asserts read a settled state — time_control op=unfreeze to resume. For CI, use the headless runner (see the playtest skill) which plays every suite and exits non-zero on failure.",
		"input_schema": {"type": "object", "properties": {
			"op": {"type": "string", "description": "save | run | list | show"},
			"name": {"type": "string", "description": "playtest name (file stem under res://tests/playtests/)"},
			"scene": {"type": "string", "description": "op=save: the res:// scene the playtest plays (used by the headless runner)"},
			"events": {"type": "array", "description": "op=save: the events array from record_input action=stop (or hand-authored)"},
			"asserts": {"type": "array", "description": "op=save: array of typed asserts (node_state | screen_text | expr | screenshot | perf)"},
			"deterministic": {"type": "boolean", "description": "op=run: frame-stepped deterministic replay (default true); false = back-to-back"},
			"settle_frames": {"type": "integer", "description": "op=run: extra physics frames to advance after the last event before asserting (default 4)"},
			"save_baseline": {"type": "boolean", "description": "op=run: store this run's measured perf stats in the suite as the baseline future runs diff against (default false)"},
		}, "required": ["op"]},
		"handler": Callable(self, "_playtest"),
	})


func _playtest(args: Dictionary) -> Dictionary:
	match str(args.get("op", "")).to_lower():
		"save": return _save(args)
		"run": return _run(args)
		"list": return _list()
		"show": return _show(args)
		_: return {"error": "unknown op '%s' — use save | run | list | show" % str(args.get("op", ""))}



func _save(args: Dictionary) -> Dictionary:
	var pname := _sanitize(str(args.get("name", "")))
	if pname.is_empty():
		return {"error": "op=save needs a 'name'"}
	var events: Variant = args.get("events", [])
	if not (events is Array) or (events as Array).is_empty():
		return {"error": "op=save needs 'events' (from record_input action=stop, or hand-authored)"}
	var asserts: Variant = args.get("asserts", [])
	if not (asserts is Array):
		asserts = []
	var doc := {
		"schema_version": SCHEMA_VERSION,
		"name": pname,
		"scene": str(args.get("scene", "")),
		"created": Time.get_datetime_string_from_system(false, true),
		"engine": String(Engine.get_version_info().get("string", "")),
		"beckett": _beckett_version(),
		"events": events,
		"asserts": asserts,
	}
	var werr := _store(pname, doc)
	if werr != "":
		return {"error": werr}
	return {"text": "saved playtest '%s' -> %s/%s.json (%d events, %d asserts)" % [pname, PLAYTEST_DIR, pname, (events as Array).size(), (asserts as Array).size()]}


## Write a playtest doc to its file under PLAYTEST_DIR; "" on success, else the error text.
## Shared by op=save and the run-time baseline update (save_baseline).
func _store(pname: String, doc: Dictionary) -> String:
	if not DirAccess.dir_exists_absolute(PLAYTEST_DIR):
		DirAccess.make_dir_recursive_absolute(PLAYTEST_DIR)
	var path := "%s/%s.json" % [PLAYTEST_DIR, pname]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "could not write %s (%s)" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(JSON.stringify(doc, "\t"))
	f.close()
	return ""



func _run(args: Dictionary) -> Dictionary:
	if server.bridge == null or not server.bridge.is_game_connected():
		return {"error": "game not running/connected — play_scene, then wait_until condition=game_connected, then playtest op=run"}
	var pname := _sanitize(str(args.get("name", "")))
	var doc := _load(pname)
	if doc.has("error"):
		return doc
	var events: Array = doc.get("events", []) if doc.get("events", []) is Array else []
	var asserts: Array = doc.get("asserts", []) if doc.get("asserts", []) is Array else []
	var want_det := bool(args.get("deterministic", true))
	var has_frames := _events_have_frames(events)
	var deterministic := want_det and has_frames

	var replay: Dictionary
	if deterministic:
		replay = _replay_window(events, maxi(0, int(args.get("settle_frames", 4))))
	else:
		replay = _replay_plain(events)
	if replay.has("error"):
		return replay
	var perf: Dictionary = replay.get("perf", {}) if replay.get("perf", {}) is Dictionary else {}
	replay.erase("perf")

	var game_headless := false
	if not perf.is_empty() and _has_perf_assert(asserts):
		var hr := _bridge({"cmd": "eval", "expr": "DisplayServer.get_name()"})
		game_headless = bool(hr.get("ok", false)) and str(hr.get("value", "")) == "headless"

	var results: Array = []
	var passed := 0
	var failed := 0
	var skipped := 0
	for a in asserts:
		if not (a is Dictionary):
			continue
		var res := _eval_assert(a, perf, game_headless)
		results.append(res)
		match str(res.get("status", "")):
			"pass": passed += 1
			"fail": failed += 1
			_: skipped += 1

	var out := {
		"name": pname,
		"ok": failed == 0,
		"passed": passed,
		"failed": failed,
		"skipped": skipped,
		"deterministic": deterministic,
		"replay": replay,
		"asserts": results,
		"note": "game left FROZEN for stable asserts — time_control op=unfreeze to resume" + ("" if deterministic else " (non-deterministic: events had no frame stamp 'f'; re-record on 1.8+ for frame-exact replay)"),
	}
	if not perf.is_empty():
		out["perf"] = perf
		var base_wrap: Dictionary = doc.get("perf_baseline", {}) if doc.get("perf_baseline", {}) is Dictionary else {}
		var base: Dictionary = base_wrap.get("stats", {}) if base_wrap.get("stats", {}) is Dictionary else {}
		if not base.is_empty():
			out["perf_diff"] = _perf_diff(base, perf)
			out["perf_baseline_captured"] = str(base_wrap.get("captured", ""))
		if bool(args.get("save_baseline", false)):
			doc["perf_baseline"] = {
				"captured": Time.get_datetime_string_from_system(false, true),
				"engine": String(Engine.get_version_info().get("string", "")),
				"stats": perf,
			}
			var werr := _store(pname, doc)
			out["baseline"] = ("update failed: " + werr) if werr != "" else "saved — future runs report perf_diff vs this run"
	elif bool(args.get("save_baseline", false)):
		out["baseline"] = "not saved — no perf capture (only the deterministic replay window measures; needs events with frame stamps and deterministic=true)"
	return {"json": out}


## Deterministic replay: open the game-side replay window and poll until it closes. The game
## injects each event at its recorded physics frame and re-pauses at the end (see mcp_runtime
## _replay_open / _replay_step_tick), so asserts read a settled, reproducible state.
func _replay_window(events: Array, settle: int) -> Dictionary:
	var open_r := _bridge({"cmd": "replay_open", "events": events, "settle_frames": settle})
	if not bool(open_r.get("ok", false)):
		return {"error": "replay_open failed: %s" % str(open_r.get("error", ""))}
	var end_frame := int(open_r.get("end_frame", 0))
	var phys_fps: int = maxi(1, int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))
	var cap_ms: int = maxi(3000, int(1000.0 * float(end_frame + 10) / float(phys_fps)) + 2000)
	var tick := func() -> Dictionary:
		var st := _bridge({"cmd": "replay_status"})
		if not bool(st.get("ok", false)):
			return {"error": "replay_status failed: %s" % str(st.get("error", ""))}
		if not bool(st.get("replaying", false)):
			var perf: Dictionary = st.get("perf", {}) if st.get("perf", {}) is Dictionary else {}
			return {"mode": "deterministic", "events": events.size(), "injected": int(st.get("injected", 0)), "frames": int(st.get("frames", 0)), "perf": perf}
		return {}
	var r: Dictionary = MCPJobsScript.poll_until(cap_ms, 16, tick, Callable(server.bridge, "poll_once"))
	if r.has("timeout"):
		return {"error": "replay window did not close within %d ms" % cap_ms}
	return r


## Plain replay: fire events back-to-back (no frame anchoring), then freeze so asserts read a
## stable frame. Used when events predate the frame stamp or deterministic=false was asked for.
func _replay_plain(events: Array) -> Dictionary:
	var injected := 0
	for e in events:
		if not (e is Dictionary):
			continue
		var r := _bridge({"cmd": "input", "events": [e]})
		injected += int(r.get("dispatched", 0))
	_bridge({"cmd": "tc_freeze"})
	return {"mode": "plain", "events": events.size(), "injected": injected}



func _eval_assert(a: Dictionary, perf: Dictionary = {}, game_headless: bool = false) -> Dictionary:
	match str(a.get("type", "")).to_lower():
		"perf":
			return _eval_perf_assert(a, perf, game_headless)
		"node_state":
			var r := _bridge({"cmd": "get", "path": str(a.get("target", "")), "prop": str(a.get("property", ""))})
			if not bool(r.get("ok", false)):
				return _fail(a, str(r.get("error", "get failed")))
			var actual: Variant = r.get("value")
			var expected: Variant = a.get("equals")
			if _values_equal(actual, expected):
				return _pass(a, "%s.%s == %s" % [str(a.get("target", "")), str(a.get("property", "")), str(expected)])
			return _fail(a, "%s.%s = %s (expected %s)" % [str(a.get("target", "")), str(a.get("property", "")), str(actual), str(expected)])
		"screen_text":
			var r := _bridge({"cmd": "find", "text": str(a.get("text", "")), "max": 1})
			if bool(r.get("ok", false)) and (r.get("nodes", []) as Array).size() > 0:
				return _pass(a, "found '%s' on screen" % str(a.get("text", "")))
			return _fail(a, "text '%s' not found on screen" % str(a.get("text", "")))
		"expr":
			var r := _bridge({"cmd": "eval", "expr": str(a.get("condition", ""))})
			if not bool(r.get("ok", false)):
				return _fail(a, str(r.get("error", "eval failed")))
			if bool(r.get("value", false)):
				return _pass(a, "%s -> true" % str(a.get("condition", "")))
			return _fail(a, "%s -> %s (want true)" % [str(a.get("condition", "")), str(r.get("value"))])
		"screenshot":
			return _eval_screenshot(a)
		_:
			return {"type": str(a.get("type", "")), "status": "skip", "detail": "unknown assert type"}


## Perf assert (v1.9): {type:"perf", metric:<flat key>, max:<num>[, min:<num>]}. Metrics come
## from the deterministic replay window's capture: frames, frame_ms_min/avg/p95/max,
## fps_min/avg, memory_static_end, memory_delta, orphan_delta, draw_calls_end — all measured
## Performance monitors, never modeled. Mirrors playtest_runner._eval_perf_assert (extend both).
func _eval_perf_assert(a: Dictionary, perf: Dictionary, game_headless: bool) -> Dictionary:
	if perf.is_empty():
		return _skip("perf", "no perf capture — perf asserts need the deterministic replay window (events with frame stamps, deterministic=true)")
	var metric := str(a.get("metric", ""))
	if game_headless and (metric.begins_with("frame_ms") or metric.begins_with("fps") or metric.begins_with("draw_calls")):
		return _skip("perf", "%s skipped: the game is headless (no RHI) so rendering cost is not measured — play windowed for frame/fps/draw metrics" % metric)
	if not perf.has(metric):
		return _fail(a, "unknown perf metric '%s' (have: %s)" % [metric, ", ".join(PackedStringArray(perf.keys()))])
	if not (a.has("max") or a.has("min")):
		return _fail(a, "perf assert needs 'max' and/or 'min' (metric %s)" % metric)
	var value := float(perf[metric])
	if a.has("max") and value > float(a.get("max")):
		return _fail(a, "perf %s = %.2f > max %.2f" % [metric, value, float(a.get("max"))])
	if a.has("min") and value < float(a.get("min")):
		return _fail(a, "perf %s = %.2f < min %.2f" % [metric, value, float(a.get("min"))])
	var bound := ("max %.2f" % float(a.get("max"))) if a.has("max") else ("min %.2f" % float(a.get("min")))
	return _pass(a, "perf %s = %.2f within %s" % [metric, value, bound])


func _eval_screenshot(a: Dictionary) -> Dictionary:
	var baseline := str(a.get("baseline", ""))
	if not (baseline.begins_with("res://") or baseline.begins_with("user://")):
		return _skip("screenshot", "baseline must be a res:// or user:// path")
	var r := _bridge({"cmd": "screenshot"})
	if not bool(r.get("ok", false)):
		return _skip("screenshot", "no RHI (headless?) — screenshot asserts need a windowed play session")
	var cur := Image.new()
	if cur.load_png_from_buffer(Marshalls.base64_to_raw(str(r.get("png", "")))) != OK:
		return _skip("screenshot", "could not decode screenshot")
	if not FileAccess.file_exists(baseline):
		cur.save_png(baseline)
		return _skip("screenshot", "baseline saved (first run): %s" % baseline)
	var base := Image.new()
	if base.load(baseline) != OK:
		return _skip("screenshot", "could not load baseline %s" % baseline)
	cur.resize(64, 64)
	base.resize(64, 64)
	cur.convert(Image.FORMAT_RGBA8)
	base.convert(Image.FORMAT_RGBA8)
	var cd := cur.get_data()
	var bd := base.get_data()
	var diff := 0
	for i in cd.size():
		diff += absi(int(cd[i]) - int(bd[i]))
	var pct := 100.0 * float(diff) / float(maxi(1, cd.size() * 255))
	var tol := float(a.get("tolerance", 2.0))
	if pct <= tol:
		return _pass(a, "screenshot diff %.2f%% <= %.2f%%" % [pct, tol])
	return _fail(a, "screenshot diff %.2f%% > %.2f%%" % [pct, tol])



func _list() -> Dictionary:
	var out: Array = []
	var dir := DirAccess.open(PLAYTEST_DIR)
	if dir != null:
		dir.list_dir_begin()
		var e := dir.get_next()
		while e != "":
			if not dir.current_is_dir() and e.get_extension() == "json":
				var doc := _load(e.get_basename())
				if not doc.has("error"):
					out.append({
						"name": str(doc.get("name", e.get_basename())),
						"scene": str(doc.get("scene", "")),
						"events": (doc.get("events", []) as Array).size() if doc.get("events", []) is Array else 0,
						"asserts": (doc.get("asserts", []) as Array).size() if doc.get("asserts", []) is Array else 0,
					})
			e = dir.get_next()
		dir.list_dir_end()
	return {"json": {"dir": PLAYTEST_DIR, "count": out.size(), "playtests": out}}


func _show(args: Dictionary) -> Dictionary:
	var doc := _load(_sanitize(str(args.get("name", ""))))
	if doc.has("error"):
		return doc
	return {"json": doc}



func _load(pname: String) -> Dictionary:
	if pname.is_empty():
		return {"error": "playtest 'name' required"}
	var path := "%s/%s.json" % [PLAYTEST_DIR, pname]
	if not FileAccess.file_exists(path):
		return {"error": "no playtest at %s (playtest op=list to see saved ones)" % path}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {"error": "playtest %s is not valid JSON" % path}
	var ver := int((parsed as Dictionary).get("schema_version", 1))
	if ver > SCHEMA_VERSION:
		return {"error": "playtest %s is schema_version %d; this build reads up to %d — upgrade Beckett" % [path, ver, SCHEMA_VERSION]}
	return parsed


func _events_have_frames(events: Array) -> bool:
	for e in events:
		if e is Dictionary and (e as Dictionary).has("f"):
			return true
	return false


func _has_perf_assert(asserts: Array) -> bool:
	for a in asserts:
		if a is Dictionary and str((a as Dictionary).get("type", "")).to_lower() == "perf":
			return true
	return false


## Per-metric delta of this run vs the stored baseline: {metric: {baseline, current, delta[,
## delta_pct]}}. Only metrics present in BOTH captures diff; delta_pct is omitted for a zero
## baseline. Positive delta = this run is higher (slower/bigger for the ms/memory metrics).
func _perf_diff(base: Dictionary, cur: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in cur:
		if not base.has(k):
			continue
		if not ((cur[k] is int or cur[k] is float) and (base[k] is int or base[k] is float)):
			continue
		var b := float(base[k])
		var c := float(cur[k])
		var entry := {"baseline": b, "current": c, "delta": c - b}
		if absf(b) > 0.000001:
			entry["delta_pct"] = 100.0 * (c - b) / b
		out[k] = entry
	return out


func _bridge(cmd: Dictionary) -> Dictionary:
	return server.bridge.send_command(cmd)


## Safe file stem: strip any directory + extension, then keep only [A-Za-z0-9_-] so a name can
## never escape PLAYTEST_DIR. Version-safe (no String.validate_filename, which is 4.3+).
func _sanitize(pname: String) -> String:
	var stem := pname.strip_edges().get_file().get_basename()
	const OK_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
	var safe := ""
	for i in stem.length():
		safe += stem[i] if OK_CHARS.find(stem[i]) >= 0 else "_"
	return safe


func _beckett_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/beckett/plugin.cfg") == OK:
		return str(cfg.get_value("plugin", "version", ""))
	return ""


func _pass(a: Dictionary, detail: String) -> Dictionary:
	return {"type": str(a.get("type", "")), "status": "pass", "detail": detail}


func _fail(a: Dictionary, detail: String) -> Dictionary:
	return {"type": str(a.get("type", "")), "status": "fail", "detail": detail}


func _skip(kind: String, detail: String) -> Dictionary:
	return {"type": kind, "status": "skip", "detail": detail}


## Numeric-tolerant equality: an int property read (1) must match a JSON-loaded float expected
## (1.0) - JSON parsing turns every number into a float, so a plain str() compare would spuriously
## fail 1 vs 1.0. Non-numbers fall back to a string compare (covers bool/String/Vector via str()).
func _values_equal(actual: Variant, expected: Variant) -> bool:
	if (actual is int or actual is float) and (expected is int or expected is float):
		return is_equal_approx(float(actual), float(expected))
	return str(actual) == str(expected)
