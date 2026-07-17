class_name IndustryElectricGraph
extends RefCounted

var _adjacency: Dictionary = {}
var _components: Array[Array] = []


func rebuild(links: Array[IndustryElectricLink]) -> void:
	_adjacency.clear()
	_components.clear()
	for link: IndustryElectricLink in links:
		_ensure_node(link.element_a)
		_ensure_node(link.element_b)
		_adjacency[link.element_a][link.element_b] = true
		_adjacency[link.element_b][link.element_a] = true

	var starts: Array[int] = []
	for element_id: Variant in _adjacency.keys():
		starts.append(int(element_id))
	starts.sort()

	var visited: Dictionary = {}
	for start_id: int in starts:
		if visited.has(start_id):
			continue
		var component: Array[int] = []
		var pending: Array[int] = [start_id]
		visited[start_id] = true
		while not pending.is_empty():
			var current: int = pending.pop_back()
			component.append(current)
			var neighbor_keys: Array = _adjacency[current].keys()
			neighbor_keys.sort()
			for neighbor_variant: Variant in neighbor_keys:
				var neighbor_id: int = int(neighbor_variant)
				if not visited.has(neighbor_id):
					visited[neighbor_id] = true
					pending.append(neighbor_id)
		component.sort()
		_components.append(component)


func components() -> Array[Array]:
	return _components


func neighbors(element_id: int) -> Array[int]:
	if not _adjacency.has(element_id):
		return []
	var result: Array[int] = []
	for neighbor_variant: Variant in _adjacency[element_id].keys():
		result.append(int(neighbor_variant))
	result.sort()
	return result


func _ensure_node(element_id: int) -> void:
	if not _adjacency.has(element_id):
		_adjacency[element_id] = {}
