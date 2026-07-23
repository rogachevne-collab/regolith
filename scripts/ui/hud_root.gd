extends CanvasLayer
## Production HUD root. Owns the shared Theme (via the Screen child) and injects
## authoritative read-only sources into its widgets. Contains no simulation
## logic: presentation only (see docs/specs/HUD-UI-01.md — presentation-only).

@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")
@export var gateway_path: NodePath = NodePath("../../WorldCommandGateway")
@export var preview_path: NodePath = NodePath("../ConstructionPreview")
@export var camera_path: NodePath = NodePath("../Camera")
@export var player_path: NodePath = NodePath("..")
@export var suit_path: NodePath = NodePath("../SuitState")

@onready var _screen: Control = $Screen


func _ready() -> void:
	var ctx := {
		"query": get_node_or_null(query_path),
		"tools": get_node_or_null(tool_controller_path),
		"gateway": get_node_or_null(gateway_path),
		"preview": get_node_or_null(preview_path),
		"camera": get_node_or_null(camera_path),
		"player": get_node_or_null(player_path),
		"suit": get_node_or_null(suit_path),
		# Компактному бару и строй-тулбару нужно знать, открыто ли полное окно
		# пульта — оно и так занимает весь экран, дублировать под ним нечего.
		"control_terminal": _screen.get_node_or_null("ControlTerminal"),
	}
	for widget: Node in _screen.get_children():
		if widget.has_method("setup"):
			widget.setup(ctx)
