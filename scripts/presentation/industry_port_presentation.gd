class_name IndustryPortPresentation
extends Node
## Drives IndustryPortProjection visibility from player tool + target state.

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tools_path: NodePath = NodePath("../ToolController")
@export var preview_path: NodePath = NodePath("../ConstructionPreview")
@export var session_path: NodePath = NodePath("../../SimulationSession")

var _query: InteractionQuery
var _tools: ToolController
var _preview: ConstructionPreview
var _session: SimulationSession
var _port_projection: IndustryPortProjection
var _last_show := false
var _last_active_tool := &""
var _last_hovered_element_id := -1
var _last_pending_element_id := -1
var _last_snap_target_element_id := -1
var _last_archetype_id := ""
var _last_orientation_index := -1


func _ready() -> void:
	_query = get_node_or_null(query_path) as InteractionQuery
	_tools = get_node_or_null(tools_path) as ToolController
	_preview = get_node_or_null(preview_path) as ConstructionPreview
	if not session_path.is_empty():
		_session = get_node_or_null(session_path) as SimulationSession
	if _session != null:
		_port_projection = _session.industry_ports
	if _tools != null:
		_tools.active_tool_changed.connect(_on_tool_changed)
		_tools.construction_selection_changed.connect(_on_selection_changed)


func _physics_process(_delta: float) -> void:
	_refresh()


func _on_tool_changed(_active_tool: StringName) -> void:
	_refresh()


func _on_selection_changed(_archetype_id: String, _orientation_index: int) -> void:
	_refresh()


func _refresh() -> void:
	if _port_projection == null or _tools == null:
		return
	var active_tool := _tools.active_tool
	var show := active_tool == &"connect" or active_tool == &"build"
	var hovered_element_id := _hovered_element_id()
	var pending_element_id := _tools.connect_pending_element_id()
	var snap_target_element_id := _snap_target_element_id()
	if (
		show == _last_show
		and active_tool == _last_active_tool
		and hovered_element_id == _last_hovered_element_id
		and pending_element_id == _last_pending_element_id
		and snap_target_element_id == _last_snap_target_element_id
		and _tools.selected_archetype_id == _last_archetype_id
		and _tools.selected_orientation_index == _last_orientation_index
	):
		return
	_last_show = show
	_last_active_tool = active_tool
	_last_hovered_element_id = hovered_element_id
	_last_pending_element_id = pending_element_id
	_last_snap_target_element_id = snap_target_element_id
	_last_archetype_id = _tools.selected_archetype_id
	_last_orientation_index = _tools.selected_orientation_index
	if not show:
		_port_projection.set_presentation_state(false)
		return
	var highlight_ids: Array = []
	var compatible_ports: Array = []
	if active_tool == &"connect":
		_collect_connect_state(
			highlight_ids,
			compatible_ports,
			pending_element_id,
			hovered_element_id
		)
	elif active_tool == &"build":
		if snap_target_element_id > 0:
			highlight_ids.append(snap_target_element_id)
	_port_projection.set_presentation_state(true, highlight_ids, compatible_ports)


func _collect_connect_state(
	highlight_ids: Array,
	compatible_ports: Array,
	pending_id: int,
	hovered_id: int
) -> void:
	if pending_id > 0:
		highlight_ids.append(pending_id)
		if hovered_id > 0 and hovered_id != pending_id:
			highlight_ids.append(hovered_id)
			_append_compatible_ports(pending_id, hovered_id, compatible_ports)
	elif hovered_id > 0:
		highlight_ids.append(hovered_id)


func _hovered_element_id() -> int:
	if _query == null:
		return 0
	var hit := _query.current_hit
	if (
		hit == null
		or not hit.valid
		or hit.target_kind != InteractionHit.KIND_SIMULATION_ELEMENT
		or hit.distance > 4.0
	):
		return 0
	return int(hit.metadata.get("element_id", 0))


func _snap_target_element_id() -> int:
	if _preview == null:
		return _hovered_element_id()
	var target: Dictionary = _preview.resolved_target
	if target.is_empty():
		return _hovered_element_id()
	if (
		StringName(target.get("target_kind", &""))
		!= InteractionHit.KIND_SIMULATION_ELEMENT
	):
		return 0
	return int(target.get("metadata", {}).get("element_id", 0))


func _append_compatible_ports(
	element_a_id: int,
	element_b_id: int,
	compatible_ports: Array
) -> void:
	if _session == null:
		return
	var diagnosis := IndustryElectricPortUtil.diagnose_electric_pair(
		_session.world,
		element_a_id,
		element_b_id
	)
	var pair: Dictionary = diagnosis.get("pair", {})
	if pair.is_empty():
		return
	compatible_ports.append({
		"element_id": int(pair["element_a_id"]),
		"port_id": str(pair["port_a_id"]),
	})
	compatible_ports.append({
		"element_id": int(pair["element_b_id"]),
		"port_id": str(pair["port_b_id"]),
	})
