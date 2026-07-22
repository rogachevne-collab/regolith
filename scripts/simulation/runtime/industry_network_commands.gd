class_name IndustryNetworkCommands
extends RefCounted

static func connect_network(world,
	command: ConnectNetworkCommand
) -> StructuralCommandResult:
	if command.is_rope():
		return connect_rope(world, command)
	var validation: StructuralCommandResult = IndustryElectricPortUtil.validate_connect_endpoints(
		world,
		command.element_a_id,
		command.port_a_id,
		command.element_b_id,
		command.port_b_id,
		command.waypoints
	)
	if not validation.is_ok():
		return validation
	var assembly_a_id := int(validation.data["assembly_a_id"])
	var assembly_b_id := int(validation.data["assembly_b_id"])
	if command.assembly_id > 0 and command.assembly_id != assembly_a_id:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	var assembly_a: SimulationAssembly = world.get_assembly_raw(assembly_a_id)
	var assembly_b: SimulationAssembly = world.get_assembly_raw(assembly_b_id)
	if (
		assembly_a == null
		or assembly_a.tombstoned
		or assembly_b == null
		or assembly_b.tombstoned
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var expected_a := command.expected_revision_a
	if expected_a < 0:
		expected_a = command.expected_assembly_revision
	if (
		expected_a >= 0
		and assembly_a.topology_revision != expected_a
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"endpoint": &"a",
				"expected": expected_a,
				"actual": assembly_a.topology_revision,
			}
		)
	if (
		command.expected_revision_b >= 0
		and assembly_b.topology_revision != command.expected_revision_b
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"endpoint": &"b",
				"expected": command.expected_revision_b,
				"actual": assembly_b.topology_revision,
			}
		)
	if world._industry_network.has_pair(
		command.element_a_id,
		command.port_a_id,
		command.element_b_id,
		command.port_b_id
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_DUPLICATE_CONNECTION
		)
	# Validation ran on the world-space clicks; storage keeps each скоба in the
	# frame of the block it was clipped to, so it rides that block afterwards.
	var stored_anchors: PackedInt32Array = (
		IndustryElectricPortUtil.sanitized_waypoint_anchors(
			world,
			command.waypoints,
			command.waypoint_anchors
		)
	)
	var stored_waypoints: PackedVector3Array = (
		IndustryElectricPortUtil.localize_waypoints(
			world,
			command.waypoints,
			stored_anchors
		)
	)
	var link_id: int = world._allocator.allocate_link_id()
	var link: IndustryElectricLink = world._industry_network.add_link(
		link_id,
		command.element_a_id,
		command.port_a_id,
		command.element_b_id,
		command.port_b_id,
		stored_waypoints,
		stored_anchors
	)
	world._industry_network.bump_revision()
	world._emit_structural_event({
		"kind": &"electric_link_added",
		"command_id": command.command_id,
		"assembly_id": assembly_a_id,
		"assembly_a_id": assembly_a_id,
		"assembly_b_id": assembly_b_id,
		"topology_revision": assembly_a.topology_revision,
		"industry_network_revision": world._industry_network.industry_network_revision,
		"link_id": link.link_id,
		"element_a_id": link.element_a,
		"port_a_id": link.port_a,
		"element_b_id": link.element_b,
		"port_b_id": link.port_b,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly_a_id,
		"assembly_a_id": assembly_a_id,
		"assembly_b_id": assembly_b_id,
		"topology_revision": assembly_a.topology_revision,
		"industry_network_revision": world._industry_network.industry_network_revision,
		"link_id": link.link_id,
		"distance_m": validation.data["distance_m"],
	})

## Rope form: two free anchors, no ports, no requirements. The rest length is
## derived here from the span the player actually dragged, so what was on the
## screen is what gets stored.
static func connect_rope(world,
	command: ConnectNetworkCommand
) -> StructuralCommandResult:
	var validation: StructuralCommandResult = (
		IndustryElectricPortUtil.validate_rope_endpoints(
			world,
			command.element_a_id,
			command.attach_a,
			command.element_b_id,
			command.attach_b
		)
	)
	if not validation.is_ok():
		return validation
	var span_m := float(validation.data["distance_m"])
	var link_id: int = world._allocator.allocate_link_id()
	var link: IndustryElectricLink = world._industry_network.add_link(
		link_id,
		command.element_a_id,
		"",
		command.element_b_id,
		"",
		PackedVector3Array(),
		PackedInt32Array(),
		{
			# Клик — в мире, хранение — в системе координат блока: канат едет
			# вместе с тем, к чему привязан.
			"attach_a": CableAnchorUtil.localize(
				world,
				command.element_a_id,
				command.attach_a
			),
			"attach_b": CableAnchorUtil.localize(
				world,
				command.element_b_id,
				command.attach_b
			),
			# The slack wheel prices the rope off the STRAIGHT span, but the
			# player laid it along `routed_m` — around a block that path is
			# metres longer than the chord. Built shorter than its own path the
			# rope is born overstretched, and the tension solver takes the
			# phantom stretch out of the machine it is tied to: a sustained
			# multi-kN pull out of nowhere, usually ending in the rope snapping.
			# The routed length is the floor; for an unobstructed rope the
			# preview's routed length ≈ span·slack and this is a no-op.
			"rest_length_m": maxf(
				CableAnchorUtil.rest_length_m(span_m, command.slack),
				command.routed_m
			),
		}
	)
	world._industry_network.bump_revision()
	var assembly_a_id := int(validation.data.get("assembly_a_id", 0))
	var assembly_b_id := int(validation.data.get("assembly_b_id", 0))
	var event_assembly_id := (
		assembly_a_id if assembly_a_id > 0 else assembly_b_id
	)
	world._emit_structural_event({
		"kind": &"electric_link_added",
		"command_id": command.command_id,
		"assembly_id": event_assembly_id,
		"assembly_a_id": assembly_a_id,
		"assembly_b_id": assembly_b_id,
		"industry_network_revision": world._industry_network.industry_network_revision,
		"link_id": link.link_id,
		"element_a_id": link.element_a,
		"port_a_id": link.port_a,
		"element_b_id": link.element_b,
		"port_b_id": link.port_b,
		"rest_length_m": link.rest_length_m,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": event_assembly_id,
		"assembly_a_id": assembly_a_id,
		"assembly_b_id": assembly_b_id,
		"industry_network_revision": world._industry_network.industry_network_revision,
		"link_id": link.link_id,
		"distance_m": span_m,
		"rest_length_m": link.rest_length_m,
	})

static func disconnect_network(world,
	command: DisconnectNetworkCommand
) -> StructuralCommandResult:
	var link: IndustryElectricLink = null
	if command.link_id > 0:
		link = world._industry_network.get_link(command.link_id)
	else:
		link = IndustryNetworkCommands.find_electric_link_by_endpoints(world, 
			command.element_a_id,
			command.port_a_id,
			command.element_b_id,
			command.port_b_id
		)
	if link == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	# A rope may hang off a world anchor, so the reference assembly is whichever
	# end is an element at all.
	var reference_element: SimulationElement = world.get_element(link.element_a)
	if reference_element == null:
		reference_element = world.get_element(link.element_b)
	if reference_element == null:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	var assembly: SimulationAssembly = world.get_assembly_raw(
		reference_element.assembly_id
	)
	if assembly == null or assembly.tombstoned:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_REFERENCE
		)
	if command.assembly_id > 0 and command.assembly_id != assembly.assembly_id:
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_INVALID_TARGET
		)
	if (
		command.expected_assembly_revision >= 0
		and assembly.topology_revision != command.expected_assembly_revision
	):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_STALE_REVISION,
			{
				"expected": command.expected_assembly_revision,
				"actual": assembly.topology_revision,
			}
		)
	var removed: IndustryElectricLink = world._industry_network.remove_link(link.link_id)
	world._industry_network.bump_revision()
	world._emit_structural_event({
		"kind": &"electric_link_removed",
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"industry_network_revision": world._industry_network.industry_network_revision,
		"link_id": removed.link_id,
	})
	return StructuralCommandResult.ok({
		"command_id": command.command_id,
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"industry_network_revision": world._industry_network.industry_network_revision,
		"link_id": removed.link_id,
	})

static func find_electric_link_by_endpoints(world, 
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> IndustryElectricLink:
	for link: IndustryElectricLink in world._industry_network.list_links():
		if link.matches_endpoints(
			element_a_id,
			port_a_id,
			element_b_id,
			port_b_id
		):
			return link
	return null
