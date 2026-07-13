class_name IndustryNetworkState
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/industry_network_state.gd"
)

var industry_network_revision: int = 0
var _links: Array[IndustryElectricLink] = []
var _link_by_id: Dictionary = {}
var _pair_keys: Dictionary = {}
var _graph := IndustryElectricGraph.new()
var _cached_topology_revision: int = -1
var _cached_network_revision: int = -1


func list_links() -> Array[IndustryElectricLink]:
	return _links.duplicate()


func get_link(link_id: int) -> IndustryElectricLink:
	return _link_by_id.get(link_id) as IndustryElectricLink


func bump_revision() -> void:
	industry_network_revision += 1


func has_pair(
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> bool:
	var probe := IndustryElectricLink.new_link(
		0,
		element_a_id,
		port_a_id,
		element_b_id,
		port_b_id
	)
	return _pair_keys.has(probe.canonical_pair_key())


func add_link(
	link_id: int,
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> IndustryElectricLink:
	var link := IndustryElectricLink.new_link(
		link_id,
		element_a_id,
		port_a_id,
		element_b_id,
		port_b_id
	)
	_links.append(link)
	_link_by_id[link_id] = link
	_pair_keys[link.canonical_pair_key()] = link_id
	return link


func remove_link(link_id: int) -> IndustryElectricLink:
	var link := get_link(link_id)
	if link == null:
		return null
	_links.erase(link)
	_link_by_id.erase(link_id)
	_pair_keys.erase(link.canonical_pair_key())
	return link


func remove_link_by_endpoints(
	element_a_id: int,
	port_a_id: String,
	element_b_id: int,
	port_b_id: String
) -> IndustryElectricLink:
	for link: IndustryElectricLink in _links:
		if link.matches_endpoints(
			element_a_id,
			port_a_id,
			element_b_id,
			port_b_id
		):
			return remove_link(link.link_id)
	return null


func prune_dangling_links(world: SimulationWorld) -> bool:
	var removed := false
	var survivors: Array[IndustryElectricLink] = []
	for link: IndustryElectricLink in _links:
		if IndustryElectricPortUtil.link_still_valid(world, link):
			survivors.append(link)
			continue
		_link_by_id.erase(link.link_id)
		_pair_keys.erase(link.canonical_pair_key())
		removed = true
	_links = survivors
	if removed:
		bump_revision()
	return removed


func ensure_graph_current(world: SimulationWorld) -> IndustryElectricGraph:
	# Cross-assembly endpoints can move without changing topology. Revalidate the
	# world-space cable span before exposing the graph to budget/presentation.
	prune_dangling_links(world)
	var topology_revision := _max_topology_revision(world)
	if (
		_cached_topology_revision == topology_revision
		and _cached_network_revision == industry_network_revision
	):
		return _graph
	_graph.rebuild(_links)
	_cached_topology_revision = topology_revision
	_cached_network_revision = industry_network_revision
	return _graph


func to_dict() -> Dictionary:
	var rows: Array[Dictionary] = []
	for link: IndustryElectricLink in _links:
		rows.append(link.to_dict())
	return {
		"industry_network_revision": industry_network_revision,
		"electric_links": rows,
	}


func load_from_dict(data: Dictionary) -> void:
	industry_network_revision = int(data.get("industry_network_revision", 0))
	_links.clear()
	_link_by_id.clear()
	_pair_keys.clear()
	var rows: Variant = data.get("electric_links", [])
	if rows is Array:
		for row_variant: Variant in rows:
			if not row_variant is Dictionary:
				continue
			var link := IndustryElectricLink.from_dict(row_variant)
			if link.link_id <= 0:
				continue
			_links.append(link)
			_link_by_id[link.link_id] = link
			_pair_keys[link.canonical_pair_key()] = link.link_id
	_cached_topology_revision = -1
	_cached_network_revision = -1


static func create_default() -> IndustryNetworkState:
	return _SCRIPT.new()


static func _max_topology_revision(world: SimulationWorld) -> int:
	var max_revision := 0
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly.tombstoned:
			continue
		max_revision = maxi(max_revision, assembly.topology_revision)
	return max_revision
