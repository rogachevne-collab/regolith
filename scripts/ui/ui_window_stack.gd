extends Node

var _stack: Array[Dictionary] = []


func push(window: Node, close_cb: Callable, handle_escape_cb: Callable = Callable(), exclusive: bool = true) -> bool:
	if exclusive and not _stack.is_empty() and not _has(window):
		return false
	remove(window)
	_stack.append({
		"window": window,
		"close": close_cb,
		"handle_escape": handle_escape_cb if handle_escape_cb.is_valid() else close_cb,
	})
	return true


func remove(window: Node) -> void:
	for i in range(_stack.size() - 1, -1, -1):
		if _stack[i]["window"] == window:
			_stack.remove_at(i)


func any_open() -> bool:
	return not _stack.is_empty()


func top_window() -> Node:
	return _stack.back()["window"] if not _stack.is_empty() else null


func _has(window: Node) -> bool:
	for entry: Dictionary in _stack:
		if entry["window"] == window:
			return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if _stack.is_empty():
		return
	if event.is_action_pressed(&"release_mouse"):
		var top: Dictionary = _stack.back()
		(top["handle_escape"] as Callable).call()
		get_viewport().set_input_as_handled()
