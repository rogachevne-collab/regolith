class_name IndustryElectricLink
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/industry_electric_link.gd"
)
const _CODEC := preload("res://scripts/simulation/snapshot_codec.gd")

var link_id: int = 0
var element_a: int = 0
var port_a: String = ""
var element_b: int = 0
var port_b: String = ""
## Player-routed cable path (скобы): world-space points between the two port
## anchors, in order from element_a to element_b. Empty = straight cable.
## Waypoints are pinned to the world (terrain / anchored structures) and do
## not follow moving assemblies.
var waypoints: PackedVector3Array = PackedVector3Array()


static func new_link(
	link_id: int,
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String,
	link_waypoints: PackedVector3Array = PackedVector3Array()
) -> IndustryElectricLink:
	var link: IndustryElectricLink = _SCRIPT.new()
	link.link_id = link_id
	link.element_a = element_a_id
	link.port_a = port_a_id
	link.element_b = element_b_id
	link.port_b = port_b_id
	link.waypoints = link_waypoints.duplicate()
	return link


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


func canonical_pair_key() -> String:
	var low_element := mini(element_a, element_b)
	var high_element := maxi(element_a, element_b)
	var low_port := port_a
	var high_port := port_b
	if element_a != low_element:
		low_port = port_b
		high_port = port_a
	return "%d:%s|%d:%s" % [low_element, low_port, high_element, high_port]


func to_dict(for_snapshot := false) -> Dictionary:
	var waypoint_row: Variant = (
		_CODEC.packed_vector3_array_to_array(waypoints)
		if for_snapshot
		else waypoints.duplicate()
	)
	return {
		"link_id": link_id,
		"element_a": element_a,
		"port_a": port_a,
		"element_b": element_b,
		"port_b": port_b,
		"waypoints": waypoint_row,
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
	return link
