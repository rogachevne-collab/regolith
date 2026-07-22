class_name IndustryElectricPortUtil
extends RefCounted

## Maximum length of a single cable SPAN: between the port anchor and the
## first скоба, between consecutive скобы, and from the last скоба to the far
## port anchor. Total routed length is unbounded — long runs just need a скоба
## at least every MAX_CABLE_LENGTH_M. A cable without waypoints (inter-grid
## umbilical) is a single span, so it keeps the plain max-span rule.
const MAX_CABLE_LENGTH_M := 999.0

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
	var compatible_direction_found := false
	var shortest_span := INF
	var best_pair: Dictionary = {}
	var best_span := INF
	for port_a: PortDefinition in ports_a:
		for port_b: PortDefinition in ports_b:
			if not electric_directions_compatible(port_a, port_b):
				continue
			compatible_direction_found = true
			var span_m := cable_max_span_m(
				world,
				element_a,
				port_a,
				element_b,
				port_b,
				waypoints
			)
			shortest_span = minf(shortest_span, span_m)
			if span_m > MAX_CABLE_LENGTH_M + 0.000001:
				continue
			if span_m < best_span:
				best_span = span_m
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
			"distance_m": best_span,
			"max_distance_m": MAX_CABLE_LENGTH_M,
		}
	if compatible_direction_found:
		return {
			"pair": {},
			"reason": &"cable_too_long",
			"distance_m": shortest_span,
			"max_distance_m": MAX_CABLE_LENGTH_M,
		}
	return {"pair": {}, "reason": &"incompatible_connection"}


## World-space скобы of a stored link. World-pinned points pass through;
## block-clipped ones ride their element's current body-group transform, so a
## cable routed over a machine keeps its shape when that machine drives off.
## A скоба whose block no longer exists drops out of the route — the clip fell
## off with the block, the neighbouring spans close over it.
static func resolved_waypoints(
	world: SimulationWorld,
	link: IndustryElectricLink
) -> PackedVector3Array:
	if link == null:
		return PackedVector3Array()
	if world == null:
		return link.waypoints.duplicate()
	var resolved := PackedVector3Array()
	for index: int in range(link.waypoints.size()):
		var anchor_element_id := link.waypoint_anchor(index)
		if anchor_element_id <= 0:
			resolved.append(link.waypoints[index])
			continue
		if world.get_element(anchor_element_id) == null:
			continue
		resolved.append(
			world.element_group_transform(anchor_element_id)
			* link.waypoints[index]
		)
	return resolved


## Inverse of `resolved_waypoints`: the connect command carries world-space
## clicks, storage keeps block-clipped ones in their block's frame.
static func localize_waypoints(
	world: SimulationWorld,
	world_points: PackedVector3Array,
	anchors: PackedInt32Array
) -> PackedVector3Array:
	if world == null:
		return world_points.duplicate()
	var localized := PackedVector3Array()
	for index: int in range(world_points.size()):
		var anchor_element_id := 0
		if index < anchors.size():
			anchor_element_id = anchors[index]
		if (
			anchor_element_id <= 0
			or world.get_element(anchor_element_id) == null
		):
			localized.append(world_points[index])
			continue
		localized.append(
			world.element_group_transform(anchor_element_id).affine_inverse()
			* world_points[index]
		)
	return localized


## Anchors as they will be stored: a mount whose element vanished between the
## click and the command degrades to world-pinned, matching localize_waypoints.
static func sanitized_waypoint_anchors(
	world: SimulationWorld,
	world_points: PackedVector3Array,
	anchors: PackedInt32Array
) -> PackedInt32Array:
	var sanitized := PackedInt32Array()
	sanitized.resize(world_points.size())
	for index: int in range(world_points.size()):
		if index >= anchors.size():
			continue
		var anchor_element_id := anchors[index]
		if anchor_element_id <= 0 or world == null:
			continue
		if world.get_element(anchor_element_id) == null:
			continue
		sanitized[index] = anchor_element_id
	return sanitized


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


## Total routed length (anchor → скобы → anchor). Informational only; the
## connect limit applies per span via cable_max_span_m.
## `waypoints` are world-space here — stored links must go through
## `resolved_waypoints()` first.
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


## Longest single span of the routed polyline — the metric the cable length
## limit applies to.
static func cable_max_span_m(
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
	var max_span := 0.0
	var previous := anchor_a
	for waypoint: Vector3 in waypoints:
		max_span = maxf(max_span, previous.distance_to(waypoint))
		previous = waypoint
	return maxf(max_span, previous.distance_to(anchor_b))


## Anything with an electric port takes a cable now (CABLE-ROPE-V0). The old
## "only source / distributor / battery" gate is gone: consumers can be wired
## directly, and the distributor radius is the wireless alternative, not the
## only way to power a machine.
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
	# Cables have no placement requirements any more (CABLE-ROPE-V0): the
	# endpoint role and the port direction stopped gating the connection. Both
	# ends still have to be electric ports — that is what a port link *is*.
	var port_a := find_port(element_a, port_a_id)
	var port_b := find_port(element_b, port_b_id)
	if port_a == null or port_b == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if not is_electric_port(port_a) or not is_electric_port(port_b):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INCOMPATIBLE_CONNECTION
		)
	var span_m := cable_max_span_m(
		world,
		element_a,
		port_a,
		element_b,
		port_b,
		waypoints
	)
	if span_m > MAX_CABLE_LENGTH_M + 0.000001:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_CABLE_TOO_LONG,
			{
				"distance_m": span_m,
				"max_distance_m": MAX_CABLE_LENGTH_M,
			}
		)
	return StructuralCommandResult.ok({
		"element_a_id": element_a_id,
		"port_a_id": port_a_id,
		"element_b_id": element_b_id,
		"port_b_id": port_b_id,
		"assembly_a_id": element_a.assembly_id,
		"assembly_b_id": element_b.assembly_id,
		"distance_m": span_m,
		"max_distance_m": MAX_CABLE_LENGTH_M,
	})


## Rope endpoints (CABLE-ROPE-V0). There are no placement requirements: any
## block, in any state, at any distance, to any other block or to a point on
## terrain. The only things that can fail are a vanished element, two world
## anchors (nothing to hold) and a span too short to be a rope.
##
## Both attach points are **world-space** here — these are the player's clicks,
## localization into block frames happens afterwards, at storage. Resolving
## them through endpoint_world_position() would apply the block transform a
## second time; near the origin that is invisible, on the moon it inflates the
## span by kilometres and the rope hangs into the planet.
static func validate_rope_endpoints(
	world: SimulationWorld,
	element_a_id: int,
	attach_a: Vector3,
	element_b_id: int,
	attach_b: Vector3
) -> StructuralCommandResult:
	if world == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if element_a_id <= 0 and element_b_id <= 0:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var element_a := (
		world.get_element(element_a_id) if element_a_id > 0 else null
	)
	var element_b := (
		world.get_element(element_b_id) if element_b_id > 0 else null
	)
	if (
		(element_a_id > 0 and element_a == null)
		or (element_b_id > 0 and element_b == null)
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var span_m := attach_a.distance_to(attach_b)
	if span_m < CableAnchorUtil.MIN_SPAN_M:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET,
			{"distance_m": span_m}
		)
	return StructuralCommandResult.ok({
		"element_a_id": element_a_id,
		"element_b_id": element_b_id,
		"assembly_a_id": element_a.assembly_id if element_a != null else 0,
		"assembly_b_id": element_b.assembly_id if element_b != null else 0,
		"distance_m": span_m,
	})


## Deletion criterion: a link may only be removed from the network state when an
## endpoint element no longer exists in the world. Temporary conditions (damaged
## endpoint, overstretched cable) make the link dormant, never delete it.
## A world-nailed rope end (element 0) always "exists" — it is a point in space.
static func link_endpoints_exist(
	world: SimulationWorld,
	link: IndustryElectricLink
) -> bool:
	if link == null:
		return false
	return (
		_endpoint_exists(world, link.element_a)
		and _endpoint_exists(world, link.element_b)
	)


static func _endpoint_exists(world: SimulationWorld, element_id: int) -> bool:
	if element_id <= 0:
		return true
	return world.get_element(element_id) != null


## Activity criterion: dormant links (endpoint not operational, cable stretched
## beyond max length) stay stored but drop out of the electric graph until the
## condition clears.
## Conduction rule: a cable carries current between any two operational
## elements that have an electric port at all — a rope tied to a drill powers
## the drill. Ends nailed to the world conduct nothing (the rope is purely
## mechanical there), and neither does a rope to a portless block.
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
	if (
		list_electric_ports(element_a).is_empty()
		or list_electric_ports(element_b).is_empty()
	):
		return false
	if link.is_rope():
		# A rope has no length limit: pull it too hard and it snaps outright
		# (CableTensionUtil), it never quietly goes dead.
		return true
	# Stiff port wires keep the old overstretch dormancy — that is what stops
	# an umbilical between two grids from conducting across the map.
	var port_a := find_port(element_a, link.port_a)
	var port_b := find_port(element_b, link.port_b)
	if not is_electric_port(port_a) or not is_electric_port(port_b):
		return false
	return (
		cable_max_span_m(
			world,
			element_a,
			port_a,
			element_b,
			port_b,
			resolved_waypoints(world, link)
		)
		<= MAX_CABLE_LENGTH_M + 0.000001
	)


static func _electric_tags_compatible(
	left_tags: PackedStringArray,
	right_tags: PackedStringArray
) -> bool:
	for tag: String in left_tags:
		if tag == "electric" and right_tags.has("electric"):
			return true
	return left_tags.has("electric") and right_tags.has("electric")


