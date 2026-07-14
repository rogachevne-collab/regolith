class_name BlueprintConnectivity
extends RefCounted


static func connected_components(
	blueprint: Blueprint
) -> Array[Array]:
	var adjacency: Array[Dictionary] = []
	for _placement: BlueprintElementPlacement in blueprint.placements:
		adjacency.append({})

	for left_index: int in range(blueprint.placements.size()):
		for right_index: int in range(
			left_index + 1,
			blueprint.placements.size()
		):
			if placements_have_rigid_connection(
				blueprint.placements[left_index],
				blueprint.placements[right_index]
			):
				adjacency[left_index][right_index] = true
				adjacency[right_index][left_index] = true

	var components: Array[Array] = []
	var visited: Dictionary = {}
	for start_index: int in range(blueprint.placements.size()):
		if visited.has(start_index):
			continue
		var component: Array = []
		var pending: Array[int] = [start_index]
		visited[start_index] = true
		while not pending.is_empty():
			var current: int = pending.pop_back()
			component.append(blueprint.placements[current].local_id)
			for neighbor: Variant in adjacency[current].keys():
				var neighbor_index: int = int(neighbor)
				if not visited.has(neighbor_index):
					visited[neighbor_index] = true
					pending.append(neighbor_index)
		component.sort()
		components.append(component)
	return components


static func placements_have_rigid_connection(
	left: BlueprintElementPlacement,
	right: BlueprintElementPlacement
) -> bool:
	return GridSurfaceUtil.placements_have_rigid_connection(left, right)
