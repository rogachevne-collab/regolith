class_name CargoGraph
extends RefCounted

## Derived undirected cargo adjacency; rebuilt only on topology revision changes.

var _topology_revision_by_assembly: Dictionary = {}
var _adjacency: Dictionary = {}
var _edge_keys: Dictionary = {}
var _edges: Array[Dictionary] = []


func clear() -> void:
	_topology_revision_by_assembly.clear()
	_adjacency.clear()
	_edge_keys.clear()
	_edges.clear()


func list_edges() -> Array[Dictionary]:
	return _edges.duplicate(true)


## Keep graph current after topology edits. Skips the O(n²) cargo edge scan when
## every dirty assembly has no cargo ports (lone frame place next to rovers).
func sync(world: SimulationWorld) -> void:
	if world == null:
		return
	var live_ids: Dictionary = {}
	var needs_edge_rebuild := false
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly == null or assembly.tombstoned:
			continue
		live_ids[assembly.assembly_id] = true
		var previous := int(
			_topology_revision_by_assembly.get(assembly.assembly_id, -1)
		)
		if previous == assembly.topology_revision:
			continue
		if _assembly_has_cargo_capable_element(world, assembly):
			needs_edge_rebuild = true
		else:
			_topology_revision_by_assembly[assembly.assembly_id] = (
				assembly.topology_revision
			)
	for assembly_id_variant: Variant in _topology_revision_by_assembly.keys():
		if not live_ids.has(int(assembly_id_variant)):
			# Removed assembly may have owned cargo edges.
			needs_edge_rebuild = true
			break
	if needs_edge_rebuild:
		rebuild(world)


func rebuild(world: SimulationWorld) -> void:
	clear()
	if world == null:
		return
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly.tombstoned:
			continue
		_topology_revision_by_assembly[assembly.assembly_id] = (
			assembly.topology_revision
		)
	# Neighbor-cell probe per cargo port (not pairwise all×all).
	var operational: Array[SimulationElement] = []
	for element: SimulationElement in world.list_elements_unsorted():
		if (
			element != null
			and element.is_operational()
			and CargoConnectivity.element_has_cargo_port(element)
		):
			operational.append(element)
	for edge: Dictionary in CargoConnectivity.find_adjacent_cargo_edges(
		operational
	):
		_register_edge(
			int(edge["element_a"]),
			int(edge["element_b"]),
			str(edge["port_a"]),
			str(edge["port_b"])
		)


static func _assembly_has_cargo_capable_element(
	world: SimulationWorld,
	assembly: SimulationAssembly
) -> bool:
	if world == null or assembly == null:
		return false
	for element_id_variant: Variant in assembly.element_ids:
		var element: SimulationElement = world.get_element(int(element_id_variant))
		if (
			element != null
			and element.is_operational()
			and CargoConnectivity.element_has_cargo_port(element)
		):
			return true
	return false


func needs_rebuild_for_assembly(
	assembly_id: int,
	topology_revision: int
) -> bool:
	return int(
		_topology_revision_by_assembly.get(assembly_id, -1)
	) != topology_revision


func neighbors(element_id: int) -> Array[int]:
	var links: Variant = _adjacency.get(element_id, {})
	if links is not Dictionary:
		return []
	var result: Array[int] = []
	for neighbor_variant: Variant in links.keys():
		result.append(int(neighbor_variant))
	result.sort()
	return result


func elements_are_connected(left_id: int, right_id: int) -> bool:
	if left_id == right_id:
		return true
	var links: Variant = _adjacency.get(left_id, {})
	return links is Dictionary and links.has(right_id)


func shortest_hop_distance(from_id: int, to_id: int) -> int:
	if from_id == to_id:
		return 0
	if from_id <= 0 or to_id <= 0:
		return -1
	var pending: Array[Dictionary] = [{"id": from_id, "distance": 0}]
	var visited: Dictionary = {from_id: true}
	while not pending.is_empty():
		var current: Dictionary = pending.pop_front()
		var current_id: int = int(current["id"])
		var distance: int = int(current["distance"])
		for neighbor_id: int in neighbors(current_id):
			if neighbor_id == to_id:
				return distance + 1
			if visited.has(neighbor_id):
				continue
			visited[neighbor_id] = true
			pending.append({
				"id": neighbor_id,
				"distance": distance + 1,
			})
	return -1


func nearest_cargo_store_element_id(
	world: SimulationWorld,
	from_element_id: int
) -> int:
	var best_id := 0
	var best_distance := 2147483647
	for element: SimulationElement in world.list_elements():
		if (
			not element.is_operational()
			or not IndustryArchetypeProfile.has_keyed_store(
				element.archetype_id
			)
		):
			continue
		var distance := shortest_hop_distance(
			from_element_id,
			element.element_id
		)
		if distance < 0:
			continue
		if (
			distance < best_distance
			or (
				distance == best_distance
				and (
					best_id == 0
					or element.element_id < best_id
				)
			)
		):
			best_distance = distance
			best_id = element.element_id
	return best_id


func nearest_cargo_store_element_id_with_resource(
	world: SimulationWorld,
	from_element_id: int,
	resource_id: String,
	min_amount: float = 0.000001
) -> int:
	if world == null or from_element_id <= 0 or resource_id.is_empty():
		return 0
	var best_id := 0
	var best_distance := 2147483647
	for element: SimulationElement in world.list_elements():
		if (
			not element.is_operational()
			or not IndustryArchetypeProfile.has_keyed_store(
				element.archetype_id
			)
		):
			continue
		var store := IndustryStoreService.ensure_element_keyed_store(
			world,
			element
		)
		if store == null or store.amount(resource_id) + 0.000001 < min_amount:
			continue
		var distance := shortest_hop_distance(
			from_element_id,
			element.element_id
		)
		if distance < 0:
			continue
		if (
			distance < best_distance
			or (
				distance == best_distance
				and (
					best_id == 0
					or element.element_id < best_id
				)
			)
		):
			best_distance = distance
			best_id = element.element_id
	return best_id


func connected_store_element_ids_with_resource(
	world: SimulationWorld,
	from_element_id: int,
	resource_id: String,
	min_amount: float = 0.000001
) -> Array[int]:
	var matches: Array[Dictionary] = []
	if world == null or from_element_id <= 0 or resource_id.is_empty():
		return []
	for element: SimulationElement in world.list_elements():
		if (
			not element.is_operational()
			or not IndustryArchetypeProfile.has_keyed_store(
				element.archetype_id
			)
		):
			continue
		var store := IndustryStoreService.ensure_element_keyed_store(
			world,
			element
		)
		if store == null or store.amount(resource_id) + 0.000001 < min_amount:
			continue
		var distance := shortest_hop_distance(
			from_element_id,
			element.element_id
		)
		if distance < 0:
			continue
		matches.append({
			"element_id": element.element_id,
			"distance": distance,
		})
	matches.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			var left_distance := int(left["distance"])
			var right_distance := int(right["distance"])
			if left_distance != right_distance:
				return left_distance < right_distance
			return int(left["element_id"]) < int(right["element_id"])
	)
	var result: Array[int] = []
	for match: Dictionary in matches:
		result.append(int(match["element_id"]))
	return result


func has_connected_cargo_store(world: SimulationWorld, from_element_id: int) -> bool:
	return nearest_cargo_store_element_id(world, from_element_id) > 0


func connected_component(element_ids: Array[int]) -> Array[int]:
	var allowed: Dictionary = {}
	for element_id: int in element_ids:
		allowed[element_id] = true
	var starts: Array[int] = element_ids.duplicate()
	starts.sort()
	var visited: Dictionary = {}
	var component: Array[int] = []
	for start_id: int in starts:
		if visited.has(start_id):
			continue
		var pending: Array[int] = [start_id]
		visited[start_id] = true
		while not pending.is_empty():
			var current_id: int = int(pending.pop_back())
			component.append(current_id)
			for neighbor_id: int in neighbors(current_id):
				if not allowed.has(neighbor_id) or visited.has(neighbor_id):
					continue
				visited[neighbor_id] = true
				pending.append(neighbor_id)
	component.sort()
	return component


func _register_edge(
	element_a_id: int,
	element_b_id: int,
	port_a_id: String,
	port_b_id: String
) -> void:
	if element_a_id == element_b_id:
		return
	var low_id := mini(element_a_id, element_b_id)
	var high_id := maxi(element_a_id, element_b_id)
	var low_port := port_a_id if element_a_id == low_id else port_b_id
	var high_port := port_b_id if element_b_id == high_id else port_a_id
	var edge_key := "%d|%s|%d|%s" % [
		low_id,
		low_port,
		high_id,
		high_port,
	]
	if _edge_keys.has(edge_key):
		return
	_edge_keys[edge_key] = true
	_edges.append({
		"element_a": low_id,
		"port_a": low_port,
		"element_b": high_id,
		"port_b": high_port,
	})
	_link(low_id, high_id)
	_link(high_id, low_id)


func _link(from_id: int, to_id: int) -> void:
	var links: Dictionary = _adjacency.get(from_id, {})
	links[to_id] = true
	_adjacency[from_id] = links
