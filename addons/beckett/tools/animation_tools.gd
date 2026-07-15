@tool
extends RefCounted
class_name BeckettAnimationTools

## Animation authoring (rollup). The one content domain where reflection alone is too
## painful: keying a clip means many ordered add_track / track_insert_key / length calls
## that are easy to get subtly wrong. This wraps the AnimationPlayer + AnimationLibrary +
## Animation API behind a single `op`-dispatched tool, plus four motion presets
## (fade / slide / shake / pulse) that mint a ready-to-play clip in one call.
##
## Clips live in the player's default ("") AnimationLibrary, saved inline with the scene —
## call save_scene to persist. Player creation is undoable; clip edits are not (they mutate
## a sub-resource), so the result flags the scene unsaved where possible.

const Reflect := preload("res://addons/beckett/core/reflection.gd")

var server


func _register(registry) -> void:
	registry.register({
		"name": "animation_manage",
		"description": "Author/inspect AnimationPlayer clips. Pass 'op' plus op-specific fields:\n"
			+ "• player_create {parent?, name?} — add an AnimationPlayer\n"
			+ "• list {player} — libraries + animation names\n"
			+ "• get {player, name} — length, loop, tracks, keys\n"
			+ "• create {player, name, length?, loop?} — new empty clip\n"
			+ "• add_property_track {player, name, (path | node+property), keys:[{time,value}], interp?} — keyframe a property; path is Godot's \"Node:property\" form, or give node + property\n"
			+ "• add_method_track {player, name, node, calls:[{time, method, args?}]} — fire method calls\n"
			+ "• set_autoplay {player, name|\"\"} — play this clip when the scene runs\n"
			+ "• remove {player, name} — delete a clip\n"
			+ "• play {player, name, time?} / stop {player} — editor playback state\n"
			+ "• preset_fade/preset_slide/preset_shake/preset_pulse {target, player?, name?, duration?, ...} — mint a motion clip; auto-creates a sibling AnimationPlayer if 'player' is omitted",
		"input_schema": {"type": "object", "properties": {
			"op": {"type": "string", "description": "operation (see description)"},
			"player": {"type": "string", "description": "AnimationPlayer node path/name"},
			"parent": {"type": "string", "description": "player_create: where to add it (default scene root)"},
			"target": {"type": "string", "description": "preset_*: the node to animate"},
			"name": {"type": "string", "description": "animation name"},
			"length": {"type": "number"},
			"loop": {"type": "boolean"},
			"path": {"type": "string", "description": "add_property_track: \"Node:property\" track path"},
			"node": {"type": "string", "description": "add_*_track: node to target (alt to path)"},
			"property": {"type": "string", "description": "add_property_track: property on 'node'"},
			"keys": {"type": "array", "description": "[{time, value}] for add_property_track"},
			"calls": {"type": "array", "description": "[{time, method, args?}] for add_method_track"},
			"interp": {"type": "string", "description": "nearest | linear | cubic (default linear)"},
			"time": {"type": "number", "description": "play: seek to this time"},
			"duration": {"type": "number", "description": "preset_*: clip length (s)"},
			"from": {"type": "number", "description": "preset_fade: start alpha"},
			"to": {"type": "number", "description": "preset_fade: end alpha"},
			"offset": {"description": "preset_slide: start offset (\"x y\" or [x,y])"},
			"scale": {"type": "number", "description": "preset_pulse: peak scale multiplier"},
			"strength": {"type": "number", "description": "preset_shake: max pixel offset"},
			"count": {"type": "integer", "description": "preset_shake: number of shakes"},
			"autoplay": {"type": "boolean", "description": "preset_*: also set as autoplay"},
		}, "required": ["op"]},
		"handler": Callable(self, "_animation_manage"),
	})



func _animation_manage(args: Dictionary) -> Dictionary:
	var op := str(args.get("op", ""))
	match op:
		"player_create":
			return _player_create(args)
		"list":
			return _list(args)
		"get":
			return _get_info(args)
		"create", "create_simple":
			return _create(args)
		"add_property_track":
			return _add_property_track(args)
		"add_method_track":
			return _add_method_track(args)
		"set_autoplay":
			return _set_autoplay(args)
		"remove", "delete":
			return _remove(args)
		"play":
			return _play(args)
		"stop":
			return _stop(args)
		"preset_fade":
			return _preset_fade(args)
		"preset_slide":
			return _preset_slide(args)
		"preset_shake":
			return _preset_shake(args)
		"preset_pulse":
			return _preset_pulse(args)
		_:
			return {"error": "Unknown op: %s" % op,
				"suggestion": "Valid ops: player_create, list, get, create, add_property_track, add_method_track, set_autoplay, remove, play, stop, preset_fade, preset_slide, preset_shake, preset_pulse."}



func _player_create(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open in the editor.", "suggestion": "Call open_scene first."}
	var parent := _node(str(args.get("parent", "")))
	if parent == null:
		parent = root
	var player := _make_player(parent, str(args.get("name", "AnimationPlayer")))
	return {"text": "created AnimationPlayer '%s' under %s" % [player.name, parent.name]}


func _list(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	var libs: Array = []
	for ln in player.get_animation_library_list():
		libs.append(String(ln))
	var anims: Array = []
	for an in player.get_animation_list():
		anims.append(String(an))
	return {"json": {
		"player": str(player.name),
		"libraries": libs,
		"animations": anims,
		"autoplay": str(player.autoplay),
		"current": str(player.current_animation),
	}}


func _get_info(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	var name := str(args.get("name", ""))
	if not player.has_animation(name):
		return {"error": "No animation '%s' on %s" % [name, player.name],
			"suggestion": "animation_manage op=list to see clip names."}
	var anim: Animation = player.get_animation(name)
	var tracks: Array = []
	for ti in range(anim.get_track_count()):
		var keys: Array = []
		for ki in range(anim.track_get_key_count(ti)):
			keys.append({
				"time": anim.track_get_key_time(ti, ki),
				"value": Reflect.to_json_safe(anim.track_get_key_value(ti, ki)),
			})
		tracks.append({
			"path": str(anim.track_get_path(ti)),
			"type": _track_type_name(anim.track_get_type(ti)),
			"keys": keys,
		})
	return {"json": {
		"name": name,
		"length": anim.length,
		"loop_mode": int(anim.loop_mode),
		"tracks": tracks,
	}}


func _create(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	var name := str(args.get("name", ""))
	if name.is_empty():
		return {"error": "name is required"}
	var lib := _default_lib(player)
	if lib.has_animation(name):
		return {"error": "animation '%s' already exists" % name,
			"suggestion": "Use op=remove first, or add tracks to it with add_property_track."}
	var anim := Animation.new()
	anim.length = float(args.get("length", 1.0))
	anim.loop_mode = Animation.LOOP_LINEAR if bool(args.get("loop", false)) else Animation.LOOP_NONE
	lib.add_animation(name, anim)
	_dirty()
	return {"text": "created animation '%s' (%.2fs%s)" % [name, anim.length, ", looping" if bool(args.get("loop", false)) else ""]}


func _remove(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	var name := str(args.get("name", ""))
	if not player.has_animation(name):
		return {"error": "No animation '%s' on %s" % [name, player.name]}
	var lib := _default_lib(player)
	if not lib.has_animation(name):
		return {"error": "animation '%s' is not in the default library (qualified names not removable here)" % name}
	lib.remove_animation(name)
	_dirty()
	return {"text": "removed animation '%s'" % name}


func _set_autoplay(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	var name := str(args.get("name", ""))
	if not name.is_empty() and not player.has_animation(name):
		return {"error": "No animation '%s' on %s" % [name, player.name]}
	player.autoplay = name
	_dirty()
	return {"text": "autoplay = '%s'" % name if not name.is_empty() else "autoplay cleared"}



func _add_property_track(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	var anim := _anim(player, args)
	if anim == null:
		return {"error": "No animation '%s' on %s" % [str(args.get("name", "")), player.name],
			"suggestion": "Create it first with op=create."}
	var track_path := ""
	var leaf_node: Node = null
	var leaf_prop := ""
	if args.has("path") and not str(args["path"]).is_empty():
		track_path = str(args["path"])
		var split := _split_track_path(player, track_path)
		leaf_node = split[0]
		leaf_prop = split[1]
	else:
		leaf_node = _node(str(args.get("node", "")))
		leaf_prop = str(args.get("property", ""))
		if leaf_node == null:
			return {"error": "Could not resolve node: %s" % str(args.get("node", "")),
				"suggestion": "Provide a full 'path' (\"Node:property\") instead."}
		if leaf_prop.is_empty():
			return {"error": "property is required (or pass a full 'path')."}
		track_path = "%s:%s" % [_rel_path(player, leaf_node), leaf_prop]
	var keys: Variant = args.get("keys", [])
	if not (keys is Array) or keys.is_empty():
		return {"error": "keys must be a non-empty array of {time, value}."}
	var ti := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(ti, NodePath(track_path))
	anim.track_set_interpolation_type(ti, _interp(str(args.get("interp", "linear"))))
	var maxt := anim.length
	for k in keys:
		if not (k is Dictionary):
			continue
		var t := float(k.get("time", 0.0))
		var value: Variant = _coerce_key(leaf_node, leaf_prop, k.get("value"))
		anim.track_insert_key(ti, t, value)
		maxt = max(maxt, t)
	anim.length = maxt
	_dirty()
	return {"text": "added value track %s (%d keys) to '%s'" % [track_path, keys.size(), str(args.get("name", ""))]}


func _add_method_track(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	var anim := _anim(player, args)
	if anim == null:
		return {"error": "No animation '%s' on %s" % [str(args.get("name", "")), player.name],
			"suggestion": "Create it first with op=create."}
	var target := _node(str(args.get("node", "")))
	if target == null:
		return {"error": "Could not resolve node: %s" % str(args.get("node", ""))}
	var calls: Variant = args.get("calls", [])
	if not (calls is Array) or calls.is_empty():
		return {"error": "calls must be a non-empty array of {time, method, args?}."}
	var ti := anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(ti, NodePath(_rel_path(player, target)))
	var maxt := anim.length
	for c in calls:
		if not (c is Dictionary):
			continue
		var t := float(c.get("time", 0.0))
		var cargs: Variant = c.get("args", [])
		anim.track_insert_key(ti, t, {
			"method": StringName(str(c.get("method", ""))),
			"args": cargs if cargs is Array else [],
		})
		maxt = max(maxt, t)
	anim.length = maxt
	_dirty()
	return {"text": "added method track on %s (%d calls) to '%s'" % [target.name, calls.size(), str(args.get("name", ""))]}



func _play(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	var name := str(args.get("name", ""))
	if not name.is_empty() and not player.has_animation(name):
		return {"error": "No animation '%s' on %s" % [name, player.name]}
	player.play(name)
	if args.has("time"):
		player.seek(float(args["time"]), true)
	return {"text": "playing '%s' on %s (motion is visible at runtime / in the Animation panel)" % [name, player.name]}


func _stop(args: Dictionary) -> Dictionary:
	var player := _player(args)
	if player == null:
		return _no_player(args)
	player.stop()
	return {"text": "stopped %s" % player.name}



func _preset_fade(args: Dictionary) -> Dictionary:
	var ctx := _preset_ctx(args, "modulate")
	if ctx.has("error"):
		return ctx
	var target: Node = ctx["target"]
	var base_a := float((target.get("modulate") as Color).a)
	var from := float(args.get("from", base_a))
	var to := float(args.get("to", 0.0))
	var dur := float(args.get("duration", 0.5))
	return _build(ctx, str(args.get("name", "fade")),
		"%s:modulate:a" % ctx["rel"], [[0.0, from], [dur, to]], args)


func _preset_slide(args: Dictionary) -> Dictionary:
	var ctx := _preset_ctx(args, "position")
	if ctx.has("error"):
		return ctx
	var target: Node = ctx["target"]
	var base: Variant = target.get("position")
	var dims := TYPE_VECTOR3 if base is Vector3 else TYPE_VECTOR2
	var offset: Variant = Reflect.coerce_to_type(args.get("offset", "-100 0"), dims)
	var dur := float(args.get("duration", 0.4))
	return _build(ctx, str(args.get("name", "slide")),
		"%s:position" % ctx["rel"], [[0.0, base + offset], [dur, base]], args)


func _preset_shake(args: Dictionary) -> Dictionary:
	var ctx := _preset_ctx(args, "position")
	if ctx.has("error"):
		return ctx
	var target: Node = ctx["target"]
	var base: Variant = target.get("position")
	var is3d := base is Vector3
	var strength := float(args.get("strength", 8.0))
	var count := int(args.get("count", 6))
	var dur := float(args.get("duration", 0.4))
	var step := dur / float(max(count, 1))
	var pairs: Array = [[0.0, base]]
	for i in range(1, count):
		var jitter: Variant
		if is3d:
			jitter = Vector3(randf_range(-strength, strength), randf_range(-strength, strength), randf_range(-strength, strength))
		else:
			jitter = Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		pairs.append([step * i, base + jitter])
	pairs.append([dur, base])
	return _build(ctx, str(args.get("name", "shake")), "%s:position" % ctx["rel"], pairs, args)


func _preset_pulse(args: Dictionary) -> Dictionary:
	var ctx := _preset_ctx(args, "scale")
	if ctx.has("error"):
		return ctx
	var target: Node = ctx["target"]
	var base: Variant = target.get("scale")
	var peak := float(args.get("scale", 1.2))
	var dur := float(args.get("duration", 0.3))
	return _build(ctx, str(args.get("name", "pulse")),
		"%s:scale" % ctx["rel"], [[0.0, base], [dur * 0.5, base * peak], [dur, base]], args)


## Resolve target + host player for a preset. Auto-creates a sibling AnimationPlayer
## when 'player' is omitted. require_prop is validated on the target BEFORE the player
## is made, so a target that can't be animated never leaves a dangling player behind.
## Returns {target, player, rel} or {error}.
func _preset_ctx(args: Dictionary, require_prop: String = "") -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open in the editor.", "suggestion": "Call open_scene first."}
	var target := _node(str(args.get("target", "")))
	if target == null:
		return {"error": "Could not resolve target: %s" % str(args.get("target", "")),
			"suggestion": "preset_* needs 'target' = the node to animate."}
	if require_prop != "" and not _has_prop(target, require_prop):
		var hint := " — needs a CanvasItem (2D/Control); for 3D, animate the material's albedo alpha" if require_prop == "modulate" else ""
		return {"error": "%s (%s) has no '%s'%s." % [target.name, target.get_class(), require_prop, hint]}
	var player: AnimationPlayer
	if args.has("player") and not str(args["player"]).is_empty():
		player = _player(args)
		if player == null:
			return {"error": "Could not resolve player: %s" % str(args["player"])}
	else:
		var parent := target.get_parent()
		if parent == null or target == root:
			parent = root
		player = _make_player(parent, "AnimationPlayer")
	return {"target": target, "player": player, "rel": _rel_path(player, target)}


## Shared preset builder: (over)writes a single-track value clip and returns a summary.
func _build(ctx: Dictionary, name: String, track_path: String, pairs: Array, args: Dictionary) -> Dictionary:
	var player: AnimationPlayer = ctx["player"]
	var lib := _default_lib(player)
	if lib.has_animation(name):
		lib.remove_animation(name)
	var anim := Animation.new()
	var ti := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(ti, NodePath(track_path))
	var maxt := 0.0
	for pair in pairs:
		var t := float(pair[0])
		anim.track_insert_key(ti, t, pair[1])
		maxt = max(maxt, t)
	anim.length = maxt
	anim.loop_mode = Animation.LOOP_LINEAR if bool(args.get("loop", false)) else Animation.LOOP_NONE
	lib.add_animation(name, anim)
	if bool(args.get("autoplay", false)):
		player.autoplay = name
	_dirty()
	return {"text": "built clip '%s' on %s (%.2fs, %d keys) — track %s" % [name, player.name, maxt, pairs.size(), track_path]}



func _player(args: Dictionary) -> AnimationPlayer:
	var n := _node(str(args.get("player", "")))
	return n as AnimationPlayer if n is AnimationPlayer else null


func _no_player(args: Dictionary) -> Dictionary:
	return {"error": "Could not resolve an AnimationPlayer: %s" % str(args.get("player", "")),
		"suggestion": "Pass 'player' (a node path/name), or create one with op=player_create."}


func _make_player(parent: Node, name: String) -> AnimationPlayer:
	var root := EditorInterface.get_edited_scene_root()
	var player := AnimationPlayer.new()
	player.name = name
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP animation player_create")
	ur.add_do_method(parent, "add_child", player)
	ur.add_do_method(player, "set_owner", root)
	ur.add_do_reference(player)
	ur.add_undo_method(parent, "remove_child", player)
	ur.commit_action()
	return player


func _default_lib(player: AnimationPlayer) -> AnimationLibrary:
	if player.has_animation_library(""):
		return player.get_animation_library("")
	var lib := AnimationLibrary.new()
	player.add_animation_library("", lib)
	return lib


func _anim(player: AnimationPlayer, args: Dictionary) -> Animation:
	var name := str(args.get("name", ""))
	if not player.has_animation(name):
		return null
	return player.get_animation(name)


## Node path relative to the player's root_node (what Animation tracks resolve against).
func _rel_path(player: AnimationPlayer, node: Node) -> String:
	var base := player.get_node_or_null(player.root_node)
	if base == null:
		base = player.get_parent()
	if base == null:
		base = EditorInterface.get_edited_scene_root()
	if base == null:
		return str(node.name)
	return str(base.get_path_to(node))


## Split a "Node:prop[:sub]" track path into [leaf_node, first_property]. Best-effort.
func _split_track_path(player: AnimationPlayer, track_path: String) -> Array:
	var parts := track_path.split(":")
	if parts.size() < 2:
		return [null, ""]
	var base := player.get_node_or_null(player.root_node)
	if base == null:
		base = player.get_parent()
	var node: Node = null
	if base != null:
		node = base.get_node_or_null(NodePath(parts[0]))
	return [node, str(parts[1])]


## Coerce a key value to the leaf property's type when we have a single property segment.
func _coerce_key(node: Node, prop: String, value: Variant) -> Variant:
	if node != null and not prop.is_empty() and _has_prop(node, prop):
		return Reflect.coerce_for_property(node, prop, value)
	return value


func _interp(s: String) -> int:
	match s.to_lower():
		"nearest":
			return Animation.INTERPOLATION_NEAREST
		"cubic":
			return Animation.INTERPOLATION_CUBIC
		_:
			return Animation.INTERPOLATION_LINEAR


func _track_type_name(t: int) -> String:
	match t:
		Animation.TYPE_VALUE:
			return "value"
		Animation.TYPE_METHOD:
			return "method"
		Animation.TYPE_POSITION_3D:
			return "position_3d"
		Animation.TYPE_ROTATION_3D:
			return "rotation_3d"
		Animation.TYPE_SCALE_3D:
			return "scale_3d"
		Animation.TYPE_BEZIER:
			return "bezier"
		_:
			return str(t)


func _has_prop(obj: Object, prop: String) -> bool:
	for p in obj.get_property_list():
		if String(p.get("name", "")) == prop:
			return true
	return false


func _dirty() -> void:
	if Engine.is_editor_hint() and EditorInterface.has_method("mark_scene_as_unsaved"):
		EditorInterface.mark_scene_as_unsaved()


func _node(target: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	if target.is_empty() or target == "." or target == "/root" or target == root.name:
		return root
	var n := root.get_node_or_null(NodePath(target))
	if n == null:
		n = root.find_child(target, true, false)
	return n
