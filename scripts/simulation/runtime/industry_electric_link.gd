class_name IndustryElectricLink
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/industry_electric_link.gd"
)
const _CODEC := preload("res://scripts/simulation/snapshot_codec.gd")

var link_id: int = 0
## Endpoint element, or 0 for a rope end nailed to the world (terrain, boulder).
var element_a: int = 0
## Legacy port endpoint. Empty on a free-attached rope — the end then hangs at
## `attach_a` instead of at a port face. See CableAnchorUtil.
var port_a: String = ""
var element_b: int = 0
var port_b: String = ""
## Rope end attach points. Block-local (body-group frame) when the endpoint is
## an element, world-space when it is 0. Unused for port endpoints.
var attach_a: Vector3 = Vector3.ZERO
var attach_b: Vector3 = Vector3.ZERO
## Unstretched rope length. 0 = old wire without rope behaviour (drawn taut,
## no tension). Slack = rest_length_m − straight span: the rope hangs free and
## pulls nothing until the span reaches this length.
var rest_length_m: float = 0.0
## Tension that snaps the rope, in newtons. 0 = CableTensionUtil default.
## A force, not an impulse: per-tick impulse scales with the frame time, so an
## impulse threshold would mean a different rope at every frame rate.
var break_force_n: float = 0.0
## Player-routed cable path (скобы) between the two port anchors, in order from
## element_a to element_b. Empty = straight cable.
## A скоба is either nailed to the world or clipped onto a block, decided per
## point by `waypoint_anchors` — see there. Never read this array directly for
## geometry: resolve it with `IndustryElectricPortUtil.resolved_waypoints()`.
var waypoints: PackedVector3Array = PackedVector3Array()
## Per-waypoint mount, parallel to `waypoints`:
##   0  → world-pinned (terrain, anchored structure); the point is world-space;
##   >0 → element_id the скоба is clipped to; the point is stored in that
##        element's body-group frame, so the скоба rides its block through
##        assembly motion, splits and actuator sub-bodies.
## Shorter/absent array (pre-mount saves) reads as all-zero: world-pinned.
var waypoint_anchors: PackedInt32Array = PackedInt32Array()


static func new_link(
	new_link_id: int,
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String,
	link_waypoints: PackedVector3Array = PackedVector3Array(),
	link_waypoint_anchors: PackedInt32Array = PackedInt32Array(),
	rope: Dictionary = {}
) -> IndustryElectricLink:
	var link: IndustryElectricLink = _SCRIPT.new()
	link.link_id = new_link_id
	link.element_a = element_a_id
	link.port_a = port_a_id
	link.element_b = element_b_id
	link.port_b = port_b_id
	link.waypoints = link_waypoints.duplicate()
	link.waypoint_anchors = _fit_anchors(
		link_waypoint_anchors,
		link.waypoints.size()
	)
	link.attach_a = rope.get("attach_a", Vector3.ZERO)
	link.attach_b = rope.get("attach_b", Vector3.ZERO)
	link.rest_length_m = maxf(float(rope.get("rest_length_m", 0.0)), 0.0)
	link.break_force_n = maxf(float(rope.get("break_force_n", 0.0)), 0.0)
	return link


## Free-attached rope: no ports, endpoints clicked anywhere, tension physics.
func is_rope() -> bool:
	return rest_length_m > 0.0


## An end nailed to the world instead of to a block.
func has_world_endpoint() -> bool:
	return element_a <= 0 or element_b <= 0


## Element the скоба at `index` is clipped to, 0 when world-pinned.
func waypoint_anchor(index: int) -> int:
	if index < 0 or index >= waypoint_anchors.size():
		return 0
	return waypoint_anchors[index]


## Anchors always match the waypoint count: missing entries are world-pinned,
## extra ones are dropped, so callers can zip the two arrays without guards.
static func _fit_anchors(
	anchors: PackedInt32Array,
	count: int
) -> PackedInt32Array:
	var fitted := PackedInt32Array()
	fitted.resize(count)
	for index: int in range(mini(anchors.size(), count)):
		fitted[index] = maxi(anchors[index], 0)
	return fitted


func involves_element(element_id: int) -> bool:
	return element_a == element_id or element_b == element_id


func involves_port(element_id: int, port_id: String) -> bool:
	return (
		(element_a == element_id and port_a == port_id)
		or (element_b == element_id and port_b == port_id)
	)


func matches_endpoints(
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> bool:
	return (
		(
			element_a == element_a_id
			and port_a == port_a_id
			and element_b == element_b_id
			and port_b == port_b_id
		)
		or (
			element_a == element_b_id
			and port_a == port_b_id
			and element_b == element_a_id
			and port_b == port_a_id
		)
	)


## Dedup key for port wires only. Ropes return "" — you may tie as many as you
## like between the same two blocks, each with its own path and slack.
func canonical_pair_key() -> String:
	if port_a.is_empty() or port_b.is_empty():
		return ""
	var low_element := mini(element_a, element_b)
	var high_element := maxi(element_a, element_b)
	var low_port := port_a
	var high_port := port_b
	if element_a != low_element:
		low_port = port_b
		high_port = port_a
	return "%d:%s|%d:%s" % [low_element, low_port, high_element, high_port]


func to_dict(for_snapshot := false) -> Dictionary:
	var waypoint_row: Variant
	var anchor_row: Variant
	if for_snapshot:
		waypoint_row = _CODEC.packed_vector3_array_to_array(waypoints)
		anchor_row = _CODEC.packed_int32_array_to_array(waypoint_anchors)
	else:
		waypoint_row = waypoints.duplicate()
		anchor_row = waypoint_anchors.duplicate()
	return {
		"link_id": link_id,
		"element_a": element_a,
		"port_a": port_a,
		"element_b": element_b,
		"port_b": port_b,
		"waypoints": waypoint_row,
		"waypoint_anchors": anchor_row,
		"attach_a": (
			_CODEC.vector3_to_array(attach_a) if for_snapshot else attach_a
		),
		"attach_b": (
			_CODEC.vector3_to_array(attach_b) if for_snapshot else attach_b
		),
		"rest_length_m": rest_length_m,
		"break_force_n": break_force_n,
	}


static func from_dict(data: Dictionary) -> IndustryElectricLink:
	var link: IndustryElectricLink = _SCRIPT.new()
	link.link_id = int(data.get("link_id", 0))
	link.element_a = int(data.get("element_a", 0))
	link.port_a = str(data.get("port_a", ""))
	link.element_b = int(data.get("element_b", 0))
	link.port_b = str(data.get("port_b", ""))
	link.waypoints = _CODEC.packed_vector3_array_from_variant(
		data.get("waypoints", PackedVector3Array())
	)
	link.waypoint_anchors = _fit_anchors(
		_CODEC.packed_int32_array_from_variant(
			data.get("waypoint_anchors", PackedInt32Array())
		),
		link.waypoints.size()
	)
	link.attach_a = _CODEC.vector3_from_variant(data.get("attach_a", Vector3.ZERO))
	link.attach_b = _CODEC.vector3_from_variant(data.get("attach_b", Vector3.ZERO))
	link.rest_length_m = maxf(float(data.get("rest_length_m", 0.0)), 0.0)
	link.break_force_n = maxf(float(data.get("break_force_n", 0.0)), 0.0)
	return link
