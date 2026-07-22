class_name ConnectNetworkCommand
extends StructuralCommand

var assembly_id: int = 0
var expected_assembly_revision: int = -1
var expected_revision_a: int = -1
var expected_revision_b: int = -1
var element_a_id: int = 0
var port_a_id: String = ""
var element_b_id: int = 0
var port_b_id: String = ""
## Optional player-routed cable path (world-space, a→b order). The cable
## length limit applies to the whole polyline.
var waypoints: PackedVector3Array = PackedVector3Array()
## Optional per-waypoint mount, parallel to `waypoints`: element_id the скоба
## is clipped to, 0 = world-pinned. Stored on the link in block-local space so
## the cable follows machines that later drive away.
var waypoint_anchors: PackedInt32Array = PackedInt32Array()
## Rope form (CABLE-ROPE-V0), used when either port id is empty: the ends are
## free attach points instead of ports. `attach_*` are world-space here — the
## command is authored from world clicks, storage localizes them.
## `element_*_id` may be 0, meaning "nailed to this point in the world".
var attach_a: Vector3 = Vector3.ZERO
var attach_b: Vector3 = Vector3.ZERO
## Wheel knob at build time: 0 внатяг … 1 болтается. Rest length is derived
## from the span at execution, so the rope is built exactly as it was dragged.
var slack: float = CableAnchorUtil.DEFAULT_SLACK
## Length of the rope-in-hand as the routing preview actually laid it through
## the world, metres. Zero = unknown (headless, scripted call). A rope routed
## around an obstacle is longer than its chord; this is the floor under the
## rest length so it is not born overstretched.
var routed_m: float = 0.0


func is_rope() -> bool:
	return port_a_id.is_empty() or port_b_id.is_empty()


func kind() -> StringName:
	return &"connect_network"


func execution_copy() -> StructuralCommand:
	var copy := ConnectNetworkCommand.new()
	copy.assembly_id = assembly_id
	copy.expected_assembly_revision = expected_assembly_revision
	copy.expected_revision_a = expected_revision_a
	copy.expected_revision_b = expected_revision_b
	copy.element_a_id = element_a_id
	copy.port_a_id = port_a_id
	copy.element_b_id = element_b_id
	copy.port_b_id = port_b_id
	copy.waypoints = waypoints.duplicate()
	copy.waypoint_anchors = waypoint_anchors.duplicate()
	copy.attach_a = attach_a
	copy.attach_b = attach_b
	copy.slack = slack
	copy.routed_m = routed_m
	return copy
