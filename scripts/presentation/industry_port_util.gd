class_name IndustryPortUtil
extends RefCounted
## Shared industry port geometry for simulation + presentation.


static func is_industry_port(port: PortDefinition) -> bool:
	if port == null:
		return false
	return (
		port.kind == PortDefinition.Kind.ELECTRIC
		or port.kind == PortDefinition.Kind.CARGO
	)


static func list_ports_of_kind(
	element: SimulationElement,
	kind: PortDefinition.Kind
) -> Array[PortDefinition]:
	var ports: Array[PortDefinition] = []
	var archetype: ElementArchetype = element.get_archetype() if element != null else null
	if archetype == null:
		return ports
	for port: PortDefinition in archetype.ports:
		if port != null and port.kind == kind:
			ports.append(port)
	return ports


static func list_industry_ports(element: SimulationElement) -> Array[PortDefinition]:
	var ports: Array[PortDefinition] = []
	var archetype: ElementArchetype = element.get_archetype() if element != null else null
	if archetype == null:
		return ports
	for port: PortDefinition in archetype.ports:
		if is_industry_port(port):
			ports.append(port)
	return ports


static func find_port(
	element: SimulationElement,
	port_id: String
) -> PortDefinition:
	var archetype: ElementArchetype = element.get_archetype() if element != null else null
	if archetype == null:
		return null
	for port: PortDefinition in archetype.ports:
		if port.port_id == port_id:
			return port
	return null


static func element_port_cell(
	element: SimulationElement,
	port: PortDefinition
) -> Vector3i:
	return (
		element.origin_cell
		+ OrientationUtil.rotate_cell(
			port.local_cell,
			element.orientation_index
		)
	)


static func element_port_direction(
	element: SimulationElement,
	port: PortDefinition
) -> Vector3i:
	return OrientationUtil.rotate_direction(
		OrientationUtil.face_to_vector(port.local_face),
		element.orientation_index
	)


static func port_local_transform(
	element: SimulationElement,
	port: PortDefinition,
	face_offset: float = 0.23
) -> Transform3D:
	if element == null or port == null:
		return Transform3D.IDENTITY
	var basis := OrientationUtil.orientation_basis(element.orientation_index)
	var face_dir := Vector3(element_port_direction(element, port))
	var cell_center := GridPoseUtil.element_cell_center(
		element.origin_cell,
		port.local_cell,
		element.orientation_index
	)
	return Transform3D(basis, cell_center + face_dir * face_offset)


static func port_world_transform(
	world: SimulationWorld,
	element: SimulationElement,
	port: PortDefinition,
	face_offset: float = 0.23
) -> Transform3D:
	if world == null or element == null or port == null:
		return Transform3D.IDENTITY
	if world.get_assembly_raw(element.assembly_id) == null:
		return Transform3D.IDENTITY
	return (
		world.element_group_motion(element.element_id).transform
		* port_local_transform(element, port, face_offset)
	)


## Port decal transform in assembly-local space (matches collider ghost compose).
static func port_marker_local_transform(
	element: SimulationElement,
	port: PortDefinition,
	face_offset: float = 0.23
) -> Transform3D:
	var port_tf := port_local_transform(element, port, face_offset)
	if element == null or port == null:
		return Transform3D.IDENTITY
	# Marker meshes are modeled along local +Y. Build their basis directly from
	# the already oriented assembly-local face normal; composing element basis
	# with an unrotated face basis applies rotation twice and twists the decal.
	var face_dir := Vector3(
		element_port_direction(element, port)
	)
	return Transform3D(
		port_marker_basis(face_dir),
		port_tf.origin
	)


static func port_marker_world_transform(
	world: SimulationWorld,
	element: SimulationElement,
	port: PortDefinition,
	face_offset: float = 0.23
) -> Transform3D:
	if world == null or element == null or port == null:
		return Transform3D.IDENTITY
	return (
		world.element_group_motion(element.element_id).transform
		* port_marker_local_transform(element, port, face_offset)
	)


static func port_marker_basis(face_dir: Vector3) -> Basis:
	if face_dir.length_squared() <= 0.000001:
		return Basis.IDENTITY
	var normal := face_dir.normalized()
	var reference := Vector3.FORWARD
	if absf(normal.dot(reference)) > 0.999:
		reference = Vector3.RIGHT
	var tangent := reference.cross(normal).normalized()
	var bitangent := tangent.cross(normal).normalized()
	return Basis(tangent, normal, bitangent)
