class_name IndustryElectricPortUtil
extends RefCounted

enum Direction {
	INPUT,
	OUTPUT,
	BIDIRECTIONAL,
	UNKNOWN,
}


static func is_electric_port(port: PortDefinition) -> bool:
	return port != null and port.kind == PortDefinition.Kind.ELECTRIC


static func list_electric_ports(
	element: SimulationElement
) -> Array[PortDefinition]:
	var ports: Array[PortDefinition] = []
	var archetype: ElementArchetype = element.get_archetype() if element != null else null
	if archetype == null:
		return ports
	for port: PortDefinition in archetype.ports:
		if is_electric_port(port):
			ports.append(port)
	return ports


static func find_adjacent_electric_pair(
	world: SimulationWorld,
	element_a_id: int,
	element_b_id: int
) -> Dictionary:
	return find_electric_pair(
		world,
		element_a_id,
		element_b_id
	)


static func diagnose_adjacent_electric_pair(
	world: SimulationWorld,
	element_a_id: int,
	element_b_id: int
) -> Dictionary:
	return diagnose_electric_pair(world, element_a_id, element_b_id)


static func find_electric_pair(
	world: SimulationWorld,
	element_a_id: int,
	element_b_id: int
) -> Dictionary:
	return diagnose_electric_pair(
		world,
		element_a_id,
		element_b_id
	).get("pair", {})


static func diagnose_electric_pair(
	world: SimulationWorld,
	element_a_id: int,
	element_b_id: int,
	requested_port_a_id: String = "",
	requested_port_b_id: String = "",
	waypoints: PackedVector3Array = PackedVector3Array()
) -> Dictionary:
	if world == null or element_a_id <= 0 or element_b_id <= 0:
		return {"pair": {}, "reason": &"invalid_target"}
	if element_a_id == element_b_id:
		return {"pair": {}, "reason": &"invalid_target"}
	var element_a := world.get_element(element_a_id)
	var element_b := world.get_element(element_b_id)
	if element_a == null or element_b == null:
		return {"pair": {}, "reason": &"invalid_target"}
	var ports_a := list_electric_ports(element_a)
	var ports_b := list_electric_ports(element_b)
	if not requested_port_a_id.is_empty():
		var requested_a := find_port(element_a, requested_port_a_id)
		ports_a.clear()
		if is_electric_port(requested_a):
			ports_a.append(requested_a)
	if not requested_port_b_id.is_empty():
		var requested_b := find_port(element_b, requested_port_b_id)
		ports_b.clear()
		if is_electric_port(requested_b):
			ports_b.append(requested_b)
	if ports_a.is_empty() or ports_b.is_empty():
		return {"pair": {}, "reason": &"no_electric_ports"}
	var shortest_distance := INF
	var best_pair: Dictionary = {}
	for port_a: PortDefinition in ports_a:
		for port_b: PortDefinition in ports_b:
			if not electric_directions_compatible(port_a, port_b):
				continue
			var distance_m := cable_distance_m(
				world,
				element_a,
				port_a,
				element_b,
				port_b,
				waypoints
			)
			if distance_m >= shortest_distance:
				continue
			shortest_distance = distance_m
			best_pair = {
				"element_a_id": element_a_id,
				"port_a_id": port_a.port_id,
				"element_b_id": element_b_id,
				"port_b_id": port_b.port_id,
			}
	if not best_pair.is_empty():
		return {
			"pair": best_pair,
			"reason": &"ok",
			"distance_m": shortest_distance,
		}
	return {"pair": {}, "reason": &"incompatible_connection"}


static func port_anchor_world_position(
	world: SimulationWorld,
	element: SimulationElement,
	port_id: String
) -> Vector3:
	var port := find_port(element, port_id)
	if port == null or world == null or element == null:
		return Vector3.ZERO
	var assembly := world.get_assembly_raw(element.assembly_id)
	if assembly == null:
		return Vector3.ZERO
	return IndustryPortUtil.port_world_transform(
		world,
		element,
		port
	).origin


static func find_port(
	element: SimulationElement,
	port_id: String
) -> PortDefinition:
	var archetype: ElementArchetype = element.get_archetype()
	if archetype == null:
		return null
	for port: PortDefinition in archetype.ports:
		if port.port_id == port_id:
			return port
	return null


static func electric_direction(port: PortDefinition) -> Direction:
	if not is_electric_port(port):
		return Direction.UNKNOWN
	var port_id := port.port_id.to_lower()
	if port_id.ends_with("_out") or port_id.contains("output"):
		return Direction.OUTPUT
	if port_id.ends_with("_in") or port_id.contains("input"):
		return Direction.INPUT
	if port_id.ends_with("_io") or port_id.contains("bidirectional"):
		return Direction.BIDIRECTIONAL
	return Direction.UNKNOWN


static func electric_directions_compatible(
	port_a: PortDefinition,
	port_b: PortDefinition
) -> bool:
	if not _electric_tags_compatible(
		port_a.compatibility_tags,
		port_b.compatibility_tags
	):
		return false
	var direction_a := electric_direction(port_a)
	var direction_b := electric_direction(port_b)
	return (
		(direction_a == Direction.OUTPUT and direction_b == Direction.INPUT)
		or (direction_a == Direction.INPUT and direction_b == Direction.OUTPUT)
		or (
			direction_a == Direction.BIDIRECTIONAL
			and direction_b != Direction.UNKNOWN
		)
		or (
			direction_b == Direction.BIDIRECTIONAL
			and direction_a != Direction.UNKNOWN
		)
	)


static func cable_distance_m(
	world: SimulationWorld,
	element_a: SimulationElement,
	port_a: PortDefinition,
	element_b: SimulationElement,
	port_b: PortDefinition,
	waypoints: PackedVector3Array = PackedVector3Array()
) -> float:
	var anchor_a := port_anchor_world_position(world, element_a, port_a.port_id)
	var anchor_b := port_anchor_world_position(world, element_b, port_b.port_id)
	if waypoints.is_empty():
		return anchor_a.distance_to(anchor_b)
	var length := 0.0
	var previous := anchor_a
	for waypoint: Vector3 in waypoints:
		length += previous.distance_to(waypoint)
		previous = waypoint
	return length + previous.distance_to(anchor_b)


static func ports_are_face_adjacent(
	left: SimulationElement,
	left_port: PortDefinition,
	right: SimulationElement,
	right_port: PortDefinition
) -> bool:
	if (
		left == null
		or right == null
		or left_port == null
		or right_port == null
		or left.assembly_id != right.assembly_id
	):
		return false
	if left_port.face_slot != right_port.face_slot:
		return false
	if not _electric_tags_compatible(
		left_port.compatibility_tags,
		right_port.compatibility_tags
	):
		return false
	var left_cell: Vector3i = IndustryPortUtil.element_port_cell(left, left_port)
	var left_direction: Vector3i = IndustryPortUtil.element_port_direction(
		left,
		left_port
	)
	var right_cell: Vector3i = IndustryPortUtil.element_port_cell(right, right_port)
	var right_direction: Vector3i = IndustryPortUtil.element_port_direction(
		right,
		right_port
	)
	return (
		right_cell == left_cell + left_direction
		and right_direction == -left_direction
	)


static func validate_connect_endpoints(
	world: SimulationWorld,
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String,
	waypoints: PackedVector3Array = PackedVector3Array()
) -> StructuralCommandResult:
	if element_a_id <= 0 or element_b_id <= 0 or element_a_id == element_b_id:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var element_a := world.get_element(element_a_id)
	var element_b := world.get_element(element_b_id)
	if element_a == null or element_b == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if not element_a.is_operational() or not element_b.is_operational():
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ELEMENT_INCOMPLETE
			if (
				not element_a.is_operational()
				and not element_a.is_broken()
			)
			or (
				not element_b.is_operational()
				and not element_b.is_broken()
			)
			else StructuralCommandResult.REASON_ELEMENT_BROKEN
		)
	var port_a := find_port(element_a, port_a_id)
	var port_b := find_port(element_b, port_b_id)
	if port_a == null or port_b == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if (
		not is_electric_port(port_a)
		or not is_electric_port(port_b)
		or not electric_directions_compatible(port_a, port_b)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
		)
	var distance_m := cable_distance_m(
		world,
		element_a,
		port_a,
		element_b,
		port_b,
		waypoints
	)
	return StructuralCommandResult.ok({
		"element_a_id": element_a_id,
		"port_a_id": port_a_id,
		"element_b_id": element_b_id,
		"port_b_id": port_b_id,
		"assembly_a_id": element_a.assembly_id,
		"assembly_b_id": element_b.assembly_id,
		"distance_m": distance_m,
	})


## Deletion criterion: a link may only be removed from the network state when an
## endpoint element no longer exists in the world. Temporary conditions (damaged
## endpoint, overstretched cable) make the link dormant, never delete it.
static func link_endpoints_exist(
	world: SimulationWorld,
	link: IndustryElectricLink
) -> bool:
	if link == null:
		return false
	return (
		world.get_element(link.element_a) != null
		and world.get_element(link.element_b) != null
	)


## Activity criterion: dormant links (endpoint not operational) stay stored but
## drop out of the electric graph until the condition clears.
static func link_still_valid(
	world: SimulationWorld,
	link: IndustryElectricLink
) -> bool:
	if link == null:
		return false
	var element_a := world.get_element(link.element_a)
	var element_b := world.get_element(link.element_b)
	if element_a == null or element_b == null:
		return false
	if not element_a.is_operational() or not element_b.is_operational():
		return false
	var port_a := find_port(element_a, link.port_a)
	var port_b := find_port(element_b, link.port_b)
	if (
		not is_electric_port(port_a)
		or not is_electric_port(port_b)
		or not electric_directions_compatible(port_a, port_b)
	):
		return false
	return true


static func _electric_tags_compatible(
	left_tags: PackedStringArray,
	right_tags: PackedStringArray
) -> bool:
	for tag: String in left_tags:
		if tag == "electric" and right_tags.has("electric"):
			return true
	return left_tags.has("electric") and right_tags.has("electric")


