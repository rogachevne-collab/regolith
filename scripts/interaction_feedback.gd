extends CanvasLayer

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")
@export var gateway_path: NodePath = NodePath("../../WorldCommandGateway")

@onready var _reticle: Label = $Reticle
@onready var _prompt: Label = $Prompt
@onready var _progress: ProgressBar = $Progress
@onready var _result: Label = $Result

var _query: InteractionQuery
var _tool_controller: ToolController
var _player: Node
var _result_left := 0.0


func _ready() -> void:
	_query = get_node(query_path)
	_tool_controller = get_node(tool_controller_path)
	_player = get_parent()
	var gateway: WorldCommandGateway = get_node(gateway_path)
	gateway.command_completed.connect(_on_command_completed)
	_result.visible = false
	_progress.visible = false


func _process(delta: float) -> void:
	_result_left = maxf(_result_left - delta, 0.0)
	_result.visible = _result_left > 0.0
	var hit := _query.current_hit
	_reticle.modulate = (
		Color(0.5, 0.95, 1.0)
		if hit.valid else Color(1.0, 1.0, 1.0, 0.72)
	)
	_prompt.text = _prompt_for(hit)
	_prompt.visible = not _prompt.text.is_empty()
	_progress.visible = (
		_tool_controller.state == ToolController.ActionState.HOLDING
		and _tool_controller.progress < 1.0
	)
	_progress.value = _tool_controller.progress * 100.0


func _prompt_for(hit: InteractionHit) -> String:
	if _player.call("is_in_vehicle"):
		return "E — выйти из кокпита"
	if not hit.valid:
		return ""
	if (
		hit.target_kind == InteractionHit.KIND_CONTROL_SEAT
		and hit.distance <= 4.5
	):
		return "E — сесть в кокпит"
	if (
		hit.target_kind == InteractionHit.KIND_VOXEL
		and hit.distance <= 2.2
	):
		return "ЛКМ — бурить  ·  ПКМ — поставить блок"
	if hit.distance <= 4.0:
		return "ПКМ — поставить блок"
	return ""


func _on_command_completed(
	_command_id: int,
	action_result: Dictionary
) -> void:
	var reason := StringName(action_result.get("reason", &"not_ready"))
	if reason == &"ok":
		_result.text = "Готово"
		_result.modulate = Color(0.55, 1.0, 0.7)
		_result_left = 0.35
		return
	_result.text = _reason_text(reason)
	_result.modulate = Color(1.0, 0.55, 0.45)
	_result_left = 1.2


func _reason_text(reason: StringName) -> String:
	match reason:
		&"no_target":
			return "Нет цели"
		&"out_of_range":
			return "Слишком далеко"
		&"invalid_target":
			return "Неподходящая цель"
		&"blocked":
			return "Действие заблокировано"
		_:
			return "Действие недоступно"
