extends RefCounted

signal structure_changed(change: Dictionary)

const DIRECTIONS: Array[Vector3i] = [
	Vector3i.LEFT,
	Vector3i.RIGHT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.FORWARD,
	Vector3i.BACK,
]

var _elements: Dictionary = {}
var _commands: Array[Dictionary] = []
var _flush_scheduled := false


func initialize(elements: Dictionary) -> void:
	_elements = elements.duplicate(true)
	structure_changed.emit({
		"kind": "initialize",
		"elements": snapshot(),
		"fragments": [],
	})


func request_attach(cell: Vector3i, element: Dictionary) -> bool:
	if (
		_elements.has(cell)
		or float(element.get("mass", 0.0)) <= 0.0
	):
		return false
	if not _elements.is_empty() and not _has_neighbor(cell):
		return false
	_enqueue({
		"kind": "attach",
		"cell": cell,
		"element": element.duplicate(true),
	})
	return true


func request_detach(cell: Vector3i) -> bool:
	if not _elements.has(cell) or _elements.size() <= 1:
		return false
	_enqueue({
		"kind": "detach",
		"cell": cell,
	})
	return true


func snapshot() -> Dictionary:
	return _elements.duplicate(true)


func has_element(cell: Vector3i) -> bool:
	return _elements.has(cell)


func element_count() -> int:
	return _elements.size()


func _enqueue(command: Dictionary) -> void:
	_commands.append(command)
	if _flush_scheduled:
		return
	_flush_scheduled = true
	call_deferred("_flush_commands")


func _flush_commands() -> void:
	_flush_scheduled = false
	while not _commands.is_empty():
		var command: Dictionary = _commands.pop_front()
		var kind: String = command["kind"]
		if kind == "attach":
			_apply_attach(command)
		elif kind == "detach":
			_apply_detach(command)


func _apply_attach(command: Dictionary) -> void:
	var cell: Vector3i = command["cell"]
	if _elements.has(cell):
		return
	_elements[cell] = Dictionary(command["element"]).duplicate(true)
	structure_changed.emit({
		"kind": "attach",
		"cell": cell,
		"elements": snapshot(),
		"fragments": [],
	})


func _apply_detach(command: Dictionary) -> void:
	var cell: Vector3i = command["cell"]
	if not _elements.has(cell) or _elements.size() <= 1:
		return

	var detached_element: Dictionary = Dictionary(
		_elements[cell]
	).duplicate(true)
	_elements.erase(cell)
	var fragments: Array[Dictionary] = [{
		"elements": {cell: detached_element},
	}]
	var components: Array = _connected_components()
	var root_cell: Vector3i = (
		Vector3i.ZERO if _elements.has(Vector3i.ZERO)
		else _first_element_cell()
	)
	for component_value: Variant in components:
		var component: Array[Vector3i] = component_value
		if component.has(root_cell):
			continue
		var fragment_elements: Dictionary = {}
		for component_cell: Vector3i in component:
			fragment_elements[component_cell] = Dictionary(
				_elements[component_cell]
			).duplicate(true)
			_elements.erase(component_cell)
		fragments.append({"elements": fragment_elements})

	structure_changed.emit({
		"kind": "detach",
		"cell": cell,
		"elements": snapshot(),
		"fragments": fragments,
	})


func _connected_components() -> Array:
	var components: Array = []
	var visited: Dictionary = {}
	for start: Vector3i in _elements:
		if visited.has(start):
			continue
		var component: Array[Vector3i] = []
		var queue: Array[Vector3i] = [start]
		visited[start] = true
		while not queue.is_empty():
			var cell: Vector3i = queue.pop_front()
			component.append(cell)
			for direction: Vector3i in DIRECTIONS:
				var neighbor: Vector3i = cell + direction
				if _elements.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		components.append(component)
	return components


func _has_neighbor(cell: Vector3i) -> bool:
	for direction: Vector3i in DIRECTIONS:
		if _elements.has(cell + direction):
			return true
	return false


func _first_element_cell() -> Vector3i:
	for cell: Vector3i in _elements:
		return cell
	return Vector3i.ZERO
