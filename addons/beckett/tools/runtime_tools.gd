@tool
extends RefCounted
class_name BeckettRuntimeTools

## The DRIVE half of the play-test loop (L5): inject input, click UI/3D, drag/scroll,
## write runtime props, call methods, record/replay input — the agent actually plays
## the game. Everything here reaches the running game through the BeckettRuntimeBridge
## and MUTATES it. The read-only observe half (screenshot / live tree / runtime reads /
## perf / game_logs) lives in runtime_observe_tools.gd, a CORE module the free Lite
## build ships — Lite can SEE the game; this module (driving it) is the Full layer.
##
## This module is ALSO the Lite/Full SENTINEL: pack.ps1 trims it from the free build,
## and mcp_server.gd detects its absence to cap Lite at the See tier (L4). Keep it in
## $liteTrimModules and $premiumToolNames — the drive code must never ship as Lite source.

var server

const MCPJobsScript := preload("res://addons/beckett/core/jobs.gd")


func _register(registry) -> void:
	registry.register({
		"name": "simulate_input",
		"description": "Inject input into the running game. Pass one event inline or 'events':[...]. Event types: {type:key,keycode:Space,pressed:true} | {type:action,action:ui_accept,pressed:true} | {type:mouse_button,button:1,position:[x,y],pressed:true} | {type:mouse_motion,position:[x,y],relative:[dx,dy]} | {type:joy_button,button:0,pressed:true,device:0} (button = JOY_BUTTON_* index, 0=A) | {type:joy_axis,axis:0,value:-1.0,device:0} (axis = JOY_AXIS_* index, 0=left-X; value clamped -1..1) | {type:touch,index:0,position:[x,y],pressed:true} | {type:touch_drag,index:0,position:[x,y],relative:[dx,dy]}. LIMITS: injected events drive the action system and _input/_gui_input callbacks; raw polling APIs such as Input.get_joy_axis() or Input.get_connected_joypads() do NOT reflect injected events, so games reading actions (Input.get_vector, Input.is_action_pressed) work, raw-hardware polling does not. Touch events reach _input as InputEventScreenTouch/Drag; set the project's input_devices/pointing/emulate_mouse_from_touch to also drive mouse-based UI.",
		"input_schema": {"type": "object", "properties": {
			"events": {"type": "array"},
			"type": {"type": "string", "description": "key | action | mouse_button | mouse_motion | joy_button | joy_axis | touch | touch_drag"},
			"keycode": {"type": "string"},
			"action": {"type": "string"},
			"button": {"type": "integer", "description": "mouse_button: MOUSE_BUTTON_* (1=left); joy_button: JOY_BUTTON_* index (0=A)"},
			"axis": {"type": "integer", "description": "joy_axis: JOY_AXIS_* index (0=left-X, 1=left-Y, 2=right-X, 3=right-Y)"},
			"value": {"type": "number", "description": "joy_axis: axis value, clamped -1.0..1.0"},
			"device": {"type": "integer", "description": "joy_button/joy_axis: joypad device id (default 0)"},
			"index": {"type": "integer", "description": "touch/touch_drag: finger index (default 0)"},
			"position": {"type": "array"},
			"relative": {"type": "array", "description": "mouse_motion/touch_drag: delta since last event [dx,dy]"},
			"pressed": {"type": "boolean"},
		}},
		"handler": Callable(self, "_simulate_input"),
	})
	registry.register({
		"name": "runtime_set_property",
		"description": "Set a property on a node in the RUNNING game (live, not persisted). Address by path OR a live selector: class (native or custom class_name) / name / text [+ nth].",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "property": {"type": "string"}, "value": {},
			"class": {"type": "string"}, "name": {"type": "string"},
			"text": {"type": "string"}, "nth": {"type": "integer"}, "under": {"type": "string"},
		}, "required": ["property", "value"]},
		"handler": Callable(self, "_runtime_set"),
	})
	registry.register({
		"name": "runtime_call",
		"description": "Call a method on a node in the RUNNING game. args = positional array. Address by path OR a live selector: class (native or custom class_name) / name / text [+ nth] — resolves fresh each call (skip the find step). Returns the result plus the 'resolved' path that matched.",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "method": {"type": "string"}, "args": {"type": "array"},
			"class": {"type": "string"}, "name": {"type": "string"},
			"text": {"type": "string"}, "nth": {"type": "integer"}, "under": {"type": "string"},
		}, "required": ["method"]},
		"handler": Callable(self, "_runtime_call"),
	})
	registry.register({
		"name": "find_ui_elements",
		"description": "List UI nodes in the running game (default class Control; e.g. class=Button). Matches native and custom class_name. Returns path/class/text. For non-UI nodes use find_nodes.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"class": {"type": "string"}, "max": {"type": "integer"},
		}},
		"handler": Callable(self, "_find_ui_elements"),
	})
	registry.register({
		"name": "click_button_by_text",
		"description": "Find a button in the running game whose text contains the string and click it (emits pressed). Disambiguate when the text repeats: nth=pick the Nth match (0-based, document order); under=node path to scope the search; all=true returns every match (path/text/class) instead of clicking.",
		"input_schema": {"type": "object", "properties": {
			"text": {"type": "string"}, "nth": {"type": "integer"},
			"under": {"type": "string"}, "all": {"type": "boolean"},
		}, "required": ["text"]},
		"handler": Callable(self, "_click_button_by_text"),
	})
	registry.register({
		"name": "click_control",
		"description": "Click a Control by node path in the running game — robust against content-scale/stretch. Computes the Control's center and injects press+release straight into the viewport in GUI space, bypassing the screen-pixel mismatch that makes simulate_input miss buttons inside containers. Prefer this over simulate_input for any UI click. If the target is scrolled out of a ScrollContainer it is auto-scrolled into view and the call returns clicked=false (call again to land the click) — never a false 'clicked'. Address by path OR selector (class/name/text [+nth]); a bare text selector is scoped to BaseButton so nth indexes the SAME set/order as click_button_by_text (for a non-button text target, pass class). button=1 left (default), 2 right, 3 middle.",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "button": {"type": "integer"},
			"class": {"type": "string"}, "name": {"type": "string"},
			"text": {"type": "string"}, "nth": {"type": "integer"}, "under": {"type": "string"},
		}},
		"handler": Callable(self, "_click_control"),
	})
	registry.register({
		"name": "click_node3d",
		"description": "Click a 3D node in the running game: projects its world origin to the screen via the active Camera3D and injects mouse motion + press/release there, so the game's own picking (CollisionObject3D._input_event, or a camera raycast from the cursor) fires. Address by path OR selector (class/name/text [+nth]). Returns clicked=false with a warning if the node is behind the camera or projects off-screen. button=1 default.",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "button": {"type": "integer"},
			"class": {"type": "string"}, "name": {"type": "string"},
			"text": {"type": "string"}, "nth": {"type": "integer"}, "under": {"type": "string"},
		}},
		"handler": Callable(self, "_click_node3d"),
	})
	registry.register({
		"name": "click_world",
		"description": "Click at a 3D WORLD position in the running game (unprojected to the screen via the active Camera3D, then motion + press/release). position=[x,y,z]. Use when you know the world coordinate; for a node use click_node3d. Returns clicked=false with a warning if the point is behind the camera or off-screen. button=1 default.",
		"input_schema": {"type": "object", "properties": {
			"position": {"type": "array", "description": "[x,y,z] world coords"},
			"button": {"type": "integer"},
		}, "required": ["position"]},
		"handler": Callable(self, "_click_node3d_world"),
	})
	registry.register({
		"name": "scroll",
		"description": "Mouse-wheel scroll in the running game, at a target Control's center (path OR selector class/name/text[+nth/under]) or an explicit position=[x,y] (gui-space). amount = wheel notches: positive scrolls DOWN, negative UP (default 1). Use to bring off-screen list/menu items into view before click_control.",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"}, "position": {"type": "array"}, "amount": {"type": "integer"},
			"class": {"type": "string"}, "name": {"type": "string"},
			"text": {"type": "string"}, "nth": {"type": "integer"}, "under": {"type": "string"},
		}},
		"handler": Callable(self, "_scroll"),
	})
	registry.register({
		"name": "drag",
		"description": "Drag in the running game: press at from=[x,y], glide to to=[x,y] (gui-space coords), release — for sliders, drag-and-drop, camera pans. button=1 default; steps = motion interpolation count (default 8). Get coords from get_control_rect (gui_center) or get_remote_tree.",
		"input_schema": {"type": "object", "properties": {
			"from": {"type": "array"}, "to": {"type": "array"},
			"button": {"type": "integer"}, "steps": {"type": "integer"},
		}, "required": ["from", "to"]},
		"handler": Callable(self, "_drag"),
	})
	registry.register({
		"name": "get_control_rect",
		"description": "Return a Control's rectangle in the running game: gui_rect (canvas space) + screen_rect (content-scale applied) plus their centers. Use screen_center for simulate_input mouse coordinates, or just call click_control. Address by path OR selector (class/name/text [+nth/under]).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string"},
			"class": {"type": "string"}, "name": {"type": "string"},
			"text": {"type": "string"}, "nth": {"type": "integer"}, "under": {"type": "string"},
		}},
		"handler": Callable(self, "_get_control_rect"),
	})
	registry.register({
		"name": "record_input",
		"description": "Record real input from the running game. action=start begins capture (then drive the game manually); action=stop returns the captured 'events' array (timestamped) to feed into replay_input. Captures keyboard, mouse, gamepad (joy_button/joy_axis) and touch (touch/touch_drag) events: the same set simulate_input injects, so a recorded session round-trips through replay_input.",
		"input_schema": {"type": "object", "properties": {
			"action": {"type": "string", "description": "start | stop"},
		}, "required": ["action"]},
		"handler": Callable(self, "_record_input"),
	})
	registry.register({
		"name": "replay_input",
		"description": "Replay an event sequence (from record_input stop, or hand-authored) into the running game. Handles every simulate_input event type (key/action/mouse/joy_button/joy_axis/touch/touch_drag). realtime=true honors each event's 't' timestamp for original-speed playback; otherwise events fire back-to-back.",
		"input_schema": {"type": "object", "properties": {
			"events": {"type": "array"}, "realtime": {"type": "boolean"},
		}, "required": ["events"]},
		"handler": Callable(self, "_replay_input"),
	})
	registry.register({
		"name": "time_control",
		"description": "Deterministic playtest control of the RUNNING game — freeze time, step exact physics frames, run until a condition, or scale time. op=freeze pauses the game (get_tree().paused); op=unfreeze resumes. op=step {frames:N>=1, default 1} runs EXACTLY N physics ticks from any state then re-pauses (returns the physics-frame delta, which equals N). op=step_until {condition, timeout_sec:10, max_frames?} unpauses and evaluates a GDScript boolean expression against the running scene root each physics tick (e.g. \"get_node('Player').position.y > 500\"), pausing the instant it is true or on timeout/max_frames (reports which terminator fired + frames consumed + final value). op=time_scale {value} sets Engine.time_scale (clamped 0.01..10.0; 0 is rejected — use freeze). op=status reports {running, paused, time_scale, physics_frames, in_step}. Other runtime tools (screenshot / get_remote_tree / runtime_get_property / get_play_state) keep working while frozen.",
		"input_schema": {"type": "object", "properties": {
			"op": {"type": "string", "description": "freeze | unfreeze | step | step_until | time_scale | status"},
			"frames": {"type": "integer", "description": "op=step: physics ticks to run (>=1, default 1)"},
			"condition": {"type": "string", "description": "op=step_until: GDScript boolean expression, scene root in scope"},
			"timeout_sec": {"type": "number", "description": "op=step_until: wall-clock cap (default 10)"},
			"max_frames": {"type": "integer", "description": "op=step_until: optional physics-frame cap"},
			"value": {"type": "number", "description": "op=time_scale: new Engine.time_scale (0.01..10.0)"},
		}, "required": ["op"]},
		"handler": Callable(self, "_time_control"),
	})



func _simulate_input(args: Dictionary) -> Dictionary:
	var events: Variant = args.get("events", null)
	if events == null or not (events is Array):
		events = [args]
	var prepared: Array = []
	for ev in events:
		if ev is Dictionary:
			prepared.append(_infer_event_type(ev))
	var r: Dictionary = server.bridge.send_command({"cmd": "input", "events": prepared})
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "input failed"))}
	var n := int(r.get("dispatched", 0))
	if n == 0:
		return {"error": "0 events dispatched: each event needs one of these shapes: {action, pressed} | {keycode, pressed} | {button, position, pressed} | {position} (mouse motion) | {type:joy_button, button} | {type:joy_axis, axis, value} | {type:touch, index, position, pressed} | {type:touch_drag, index, position, relative}."}
	return {"text": "dispatched %d input event(s)" % n}


## A missing 'type' was the #1 silent failure here (the game skips unknown events
## and reports success with 0 dispatched) — infer it from the fields instead.
func _infer_event_type(ev: Dictionary) -> Dictionary:
	if ev.has("type"):
		return ev
	var e := ev.duplicate()
	if e.has("action"):
		e["type"] = "action"
	elif e.has("keycode"):
		e["type"] = "key"
	elif e.has("axis"):
		e["type"] = "joy_axis"
	elif e.has("index"):
		e["type"] = "touch_drag" if e.has("relative") else "touch"
	elif e.has("button"):
		e["type"] = "mouse_button"
	elif e.has("position"):
		e["type"] = "mouse_motion"
	return e


## Copy path + selector fields (class/name/text/nth) from tool args into a bridge cmd,
## so every runtime node op accepts either a path or a live selector. (Also in
## runtime_observe_tools.gd — a tiny helper shared by the drive and observe halves.)
func _add_target(cmd: Dictionary, args: Dictionary) -> void:
	for k in ["path", "class", "name", "text", "nth", "under"]:
		if args.has(k):
			cmd[k] = args[k]


func _runtime_set(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "set", "prop": str(args.get("property", "")), "value": args.get("value")}
	_add_target(cmd, args)
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "set failed"))}
	return {"text": "set (runtime) %s.%s" % [str(r.get("resolved", args.get("path", ""))), str(args.get("property", ""))]}


func _runtime_call(args: Dictionary) -> Dictionary:
	var call_args: Variant = args.get("args", [])
	if not (call_args is Array):
		call_args = []
	var cmd := {"cmd": "call", "method": str(args.get("method", "")), "args": call_args}
	_add_target(cmd, args)
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "call failed"))}
	return {"json": {"result": r.get("result"), "resolved": r.get("resolved", "")}}


func _find_ui_elements(args: Dictionary) -> Dictionary:
	var cls := str(args.get("class", "Control"))
	var r: Dictionary = server.bridge.send_command({"cmd": "find", "class": cls, "max": int(args.get("max", 100))})
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "find failed"))}
	return {"json": {"nodes": r.get("nodes", [])}}


func _click_button_by_text(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "click_text", "text": str(args.get("text", ""))}
	for k in ["nth", "under", "all"]:
		if args.has(k):
			cmd[k] = args[k]
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "click failed"))}
	if r.has("matches"):
		return {"json": {"matches": r.get("matches", []), "count": r.get("count", 0)}}
	return {"text": "clicked %s (%d match(es))" % [str(r.get("path", "")), int(r.get("match_count", 1))]}


func _click_control(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "click_control"}
	if args.has("button"):
		cmd["button"] = int(args["button"])
	_add_target(cmd, args)
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "click_control failed"))}
	if not bool(r.get("clicked", false)):
		return {"text": "NOT clicked %s — %s" % [str(r.get("path", "")), str(r.get("warning", "no reason given"))]}
	return {"text": "clicked %s at %s" % [str(r.get("path", "")), str(r.get("at", []))]}


func _click_node3d(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "click_node3d"}
	if args.has("button"):
		cmd["button"] = int(args["button"])
	_add_target(cmd, args)
	return _click3d_result(server.bridge.send_command(cmd), "click_node3d")


func _click_node3d_world(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "click_world", "position": args.get("position", [])}
	if args.has("button"):
		cmd["button"] = int(args["button"])
	return _click3d_result(server.bridge.send_command(cmd), "click_world")


func _click3d_result(r: Dictionary, what: String) -> Dictionary:
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", what + " failed"))}
	if not bool(r.get("clicked", false)):
		return {"text": "NOT clicked (%s) — %s" % [str(r.get("target", "")), str(r.get("warning", "off-screen"))]}
	return {"text": "clicked %s at screen %s (world %s)" % [str(r.get("target", "")), str(r.get("at", [])), str(r.get("world", []))]}


func _scroll(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "scroll"}
	for k in ["position", "amount"]:
		if args.has(k):
			cmd[k] = args[k]
	_add_target(cmd, args)
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "scroll failed"))}
	return {"text": "scrolled %s x%d at %s" % [str(r.get("direction", "")), int(r.get("scrolled", 0)), str(r.get("at", []))]}


func _drag(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "drag", "from": args.get("from", []), "to": args.get("to", [])}
	for k in ["button", "steps"]:
		if args.has(k):
			cmd[k] = args[k]
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "drag failed"))}
	return {"text": "dragged %s -> %s (%d steps)" % [str(r.get("from", [])), str(r.get("to", [])), int(r.get("steps", 0))]}


func _get_control_rect(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "control_rect"}
	_add_target(cmd, args)
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "control_rect failed"))}
	return {"json": r.get("rect", {})}


func _record_input(args: Dictionary) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running"}
	var action := str(args.get("action", "")).to_lower()
	if action == "start":
		var r1: Dictionary = server.bridge.send_command({"cmd": "record_start"})
		if not bool(r1.get("ok", false)):
			return {"error": str(r1.get("error", "record_start failed"))}
		return {"text": "recording input — drive the game, then call record_input action=stop"}
	if action == "stop":
		var r2: Dictionary = server.bridge.send_command({"cmd": "record_stop"})
		if not bool(r2.get("ok", false)):
			return {"error": str(r2.get("error", "record_stop failed"))}
		var events: Array = r2.get("events", [])
		return {"json": {"count": events.size(), "events": events, "note": "Feed this 'events' array to replay_input."}}
	return {"error": "action must be start or stop"}


func _replay_input(args: Dictionary) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running"}
	var events: Variant = args.get("events", [])
	if not (events is Array) or events.is_empty():
		return {"error": "events array required (from record_input action=stop)"}
	var realtime := bool(args.get("realtime", false))
	var dispatched := 0
	var last_t := 0.0
	for e in events:
		if not (e is Dictionary):
			continue
		if realtime:
			var t := float(e.get("t", 0.0))
			var gap := int(clampf(t - last_t, 0.0, 5000.0))
			if gap > 0:
				server.bridge.poll_once()
				OS.delay_msec(gap)
			last_t = t
		var r: Dictionary = server.bridge.send_command({"cmd": "input", "events": [e]})
		if bool(r.get("ok", false)):
			dispatched += int(r.get("dispatched", 0))
	return {"text": "replayed %d input event(s)%s" % [dispatched, " (realtime)" if realtime else ""]}



## One op-dispatched rollup (house rule: one tool, not N wrappers — cf. animation_manage).
## freeze/unfreeze/time_scale/status are single bridge round-trips. step/step_until can't
## complete inside one round-trip — the game must run physics FRAMES, which only advance
## between game-loop iterations, so a synchronous handler would block the very frames it
## waits for (the same reason wait_until yields). Instead the game OPENS a stepping window
## and replies at once; we POLL tc_step_status here — mirroring wait_until's bounded loop +
## bridge.poll_once() — until the window closes, then return the frame delta.
func _time_control(args: Dictionary) -> Dictionary:
	if not server.bridge.is_game_connected():
		return {"error": "game not running (runtime channel not connected) — play_scene, then wait_until condition=game_connected"}
	var op := str(args.get("op", "")).to_lower()
	match op:
		"freeze":
			return _tc_simple({"cmd": "tc_freeze"})
		"unfreeze":
			return _tc_simple({"cmd": "tc_unfreeze"})
		"status":
			return _tc_simple({"cmd": "tc_status"})
		"time_scale":
			var cmd := {"cmd": "tc_time_scale"}
			if args.has("value"):
				cmd["value"] = args["value"]
			return _tc_simple(cmd)
		"step":
			return _tc_step(args)
		"step_until":
			return _tc_step_until(args)
		_:
			return {"error": "unknown op '%s' — use freeze | unfreeze | step | step_until | time_scale | status" % op}


## Single bridge round-trip; strip the transport 'ok'/'_id' keys and surface the rest as
## structuredContent (the serializer gives text + structuredContent from a {json} dict).
func _tc_simple(cmd: Dictionary) -> Dictionary:
	var r: Dictionary = server.bridge.send_command(cmd)
	if not bool(r.get("ok", false)):
		return {"error": str(r.get("error", "time_control failed"))}
	return {"json": _tc_clean(r)}


func _tc_clean(r: Dictionary) -> Dictionary:
	var out := r.duplicate()
	out.erase("ok")
	out.erase("_id")
	return out


## op=step: open a fixed-frame window, then poll until it closes. The physics-frame delta
## (after - before) MUST equal the frames requested — we compute and assert it here so the
## agent gets a hard, checkable number rather than trusting the tick counter alone.
func _tc_step(args: Dictionary) -> Dictionary:
	var frames: int = maxi(1, int(args.get("frames", 1)))
	var open_r: Dictionary = server.bridge.send_command({"cmd": "tc_step", "frames": frames})
	if not bool(open_r.get("ok", false)):
		return {"error": str(open_r.get("error", "step failed"))}
	var before := int(open_r.get("physics_frames_before", 0))
	var final := _tc_poll_window(frames)
	if final.has("error"):
		return final
	var after := int(final.get("physics_frames_after", before))
	var stepped := int(final.get("frames", 0))
	var delta := after - before
	var out := {
		"op": "step",
		"frames_requested": frames,
		"frames_stepped": stepped,
		"physics_frames_before": before,
		"physics_frames_after": after,
		"physics_frame_delta": delta,
		"delta_matches": delta == frames,
		"paused": final.get("paused", true),
		"time_scale": final.get("time_scale", 1.0),
		"in_step": final.get("in_step", false),
	}
	if not bool(final.get("in_step", false)) and delta != frames:
		out["warning"] = "physics frame delta %d != frames requested %d" % [delta, frames]
	return {"json": out}


## op=step_until: open a condition window (or take the immediate-true fast path), then poll
## until the game reports a terminator (condition | timeout | max_frames).
func _tc_step_until(args: Dictionary) -> Dictionary:
	var cond := str(args.get("condition", "")).strip_edges()
	if cond.is_empty():
		return {"error": "step_until needs a 'condition' expression"}
	var cmd := {"cmd": "tc_step_until", "condition": cond}
	for k in ["timeout_sec", "max_frames"]:
		if args.has(k):
			cmd[k] = args[k]
	var open_r: Dictionary = server.bridge.send_command(cmd)
	if not bool(open_r.get("ok", false)):
		return {"error": str(open_r.get("error", "step_until failed"))}
	var before := int(open_r.get("physics_frames_before", 0))
	if not bool(open_r.get("started", false)) and bool(open_r.get("immediate", false)):
		return {"json": {
			"op": "step_until", "condition": cond, "terminator": "condition",
			"immediate": true, "frames": 0, "physics_frames_before": before,
			"condition_value": open_r.get("condition_value"),
		}}
	var timeout_sec := float(open_r.get("timeout_sec", 10.0))
	var final := _tc_poll_window(-1, int(timeout_sec * 1000.0) + 2000)
	if final.has("error"):
		return final
	if bool(final.get("in_step", false)):
		return {"json": {
			"op": "step_until", "condition": cond, "terminator": "in_progress",
			"frames": final.get("frames", 0), "in_step": true,
			"note": "still running after the editor poll cap — call time_control op=status, or step_until again with a smaller timeout_sec",
		}}
	var after := int(final.get("physics_frames_after", before))
	return {"json": {
		"op": "step_until",
		"condition": cond,
		"terminator": final.get("terminator", ""),
		"frames": final.get("frames", 0),
		"physics_frames_before": before,
		"physics_frames_after": after,
		"physics_frame_delta": after - before,
		"condition_value": final.get("condition_value"),
		"paused": final.get("paused", true),
	}}


## Poll the game's tc_step_status until the window closes (in_step=false) or the editor-side
## cap elapses. Mirrors wait_until: hold the main thread briefly, pump the bridge each pass so
## its _process can't starve, and sleep a beat between polls. expected_frames>0 gives a tight
## cap for fixed steps (they finish in ~frames/physics_fps seconds); pass -1 for step_until.
func _tc_poll_window(expected_frames: int, cap_ms: int = -1) -> Dictionary:
	if cap_ms < 0:
		var phys_fps: int = maxi(1, int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))
		cap_ms = maxi(2000, int(1000.0 * float(expected_frames + 5) / float(phys_fps)) + 1500)
	var lastbox: Array = [{}]
	var tick := func() -> Dictionary:
		var r: Dictionary = server.bridge.send_command({"cmd": "tc_step_status"}, 1500)
		if not bool(r.get("ok", false)):
			return {"error": str(r.get("error", "tc_step_status failed"))}
		lastbox[0] = r
		if not bool(r.get("in_step", false)):
			return {"closed": r}
		return {}
	var res: Dictionary = MCPJobsScript.poll_until(cap_ms, 16, tick, Callable(server.bridge, "poll_once"))
	if res.has("error"):
		return res
	if res.has("closed"):
		return _tc_clean(res["closed"])
	var last: Dictionary = lastbox[0]
	return _tc_clean(last) if not last.is_empty() else {"error": "no status from game while stepping"}
