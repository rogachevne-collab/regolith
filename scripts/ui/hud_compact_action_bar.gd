extends Control
## Компактная лента активной страницы бара — снизу экрана, пока игрок сидит
## в ControlSeat-хосте (кокпит) и полное окно пульта не открыто. Открыто окно
## (в т.ч. с control_terminal) — лента прячется, у окна свой пульт 9×9
## (CONTROL-ACTIONS-V0 §«Единый виджет тулбара, разные источники данных»).
##
## Данные и исполнение — не своя копия: читает bar/страницу и стреляет через
## hud_control_terminal.gd (active_page_slots/active_page_number/fire_slot/
## set_active_page), одна модель бара на обе поверхности пульта.

## Источник размерности — ActionBarState (симуляция), не своя константа.
const SLOT_COUNT := ActionBarState.SLOTS_PER_PAGE
const REFRESH_S := 0.1

const SLOT_ACTIONS: Array[StringName] = [
	&"toolbar_slot_1", &"toolbar_slot_2", &"toolbar_slot_3",
	&"toolbar_slot_4", &"toolbar_slot_5", &"toolbar_slot_6",
	&"toolbar_slot_7", &"toolbar_slot_8", &"toolbar_slot_9",
]

var _player: Node
var _control_terminal: Node

var _slots_root: Control
var _page_label: Label
var _slots: Array = []  # [{panel, label}]
var _slots_signature := ""
var _refresh_left := 0.0


func setup(ctx: Dictionary) -> void:
	_player = ctx.get("player")
	_control_terminal = ctx.get("control_terminal")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	visible = false


func _build() -> void:
	_slots_root = Control.new()
	_slots_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_slots_root)

	_page_label = Label.new()
	_page_label.theme_type_variation = &"HudSmall"
	_page_label.add_theme_color_override("font_color", HudTokens.COL_DIM)
	_page_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_page_label)


func _is_active() -> bool:
	if (
		_control_terminal != null
		and _control_terminal.has_method("is_open")
		and bool(_control_terminal.call("is_open"))
	):
		return false
	return (
		_player != null
		and _player.has_method("is_in_vehicle")
		and bool(_player.call("is_in_vehicle"))
	)


func _process(delta: float) -> void:
	var active := _is_active()
	visible = active
	if not active:
		return
	_refresh_left = maxf(_refresh_left - delta, 0.0)
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_S
	_refresh()


func _refresh() -> void:
	if _control_terminal == null or not _control_terminal.has_method("active_page_slots"):
		return
	var slots: Array = _control_terminal.call("active_page_slots")
	var page: int = int(_control_terminal.call("active_page_number"))
	var signature := "%d|%s|%s" % [
		page,
		str(get_viewport_rect().size),
		JSON.stringify(_labels_of(slots)),
	]
	if signature == _slots_signature:
		return
	_slots_signature = signature
	_rebuild_slots(slots, page)


static func _labels_of(slots: Array) -> Array:
	var labels: Array = []
	for slot_variant: Variant in slots:
		var slot: Dictionary = slot_variant if slot_variant is Dictionary else {}
		labels.append(str(slot.get("label", "")))
	return labels


func _rebuild_slots(slots: Array, page: int) -> void:
	for child_node: Node in _slots_root.get_children():
		child_node.queue_free()
	_slots.clear()

	var slot_size := HudTokens.SLOT_SIZE
	var gap := HudTokens.SLOT_GAP
	var total_w := SLOT_COUNT * int(slot_size.x) + (SLOT_COUNT - 1) * gap
	var vp := get_viewport_rect().size
	var origin := Vector2(
		(vp.x - total_w) * 0.5,
		vp.y - slot_size.y - HudTokens.TOOLBAR_BOTTOM
	)

	_page_label.text = "СТР %d/9" % (page + 1)
	_page_label.position = Vector2(origin.x, origin.y - 20.0)
	_page_label.size = Vector2(total_w, 16)

	for i in range(SLOT_COUNT):
		var slot: Dictionary = slots[i] if i < slots.size() and slots[i] is Dictionary else {}
		var empty := slot.is_empty()

		var panel := Panel.new()
		panel.theme_type_variation = &"HudSlot"
		panel.size = slot_size
		panel.position = origin + Vector2(i * (slot_size.x + gap), 0)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_slots_root.add_child(panel)

		var num := Label.new()
		num.text = str(i + 1)
		num.theme_type_variation = &"HudSmall"
		num.add_theme_color_override("font_color", HudTokens.COL_DIM)
		num.position = Vector2(6, 2)
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(num)

		var label := Label.new()
		label.theme_type_variation = &"HudSmall"
		label.add_theme_color_override(
			"font_color",
			HudTokens.COL_DIM if empty else HudTokens.COL_VALID
		)
		label.text = "—" if empty else str(slot.get("label", ""))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.clip_text = true
		label.offset_left = 4
		label.offset_right = slot_size.x - 4
		label.offset_top = 16
		label.offset_bottom = slot_size.y - 4
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(label)

		_slots.append({"panel": panel, "label": label})


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"toolbar_page_prev"):
		_set_page_relative(-1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"toolbar_page_next"):
		_set_page_relative(1)
		get_viewport().set_input_as_handled()
		return
	for index in range(SLOT_ACTIONS.size()):
		var action := SLOT_ACTIONS[index]
		if event.is_action_pressed(action) and not event.is_echo():
			_fire(index, true)
			get_viewport().set_input_as_handled()
			return
		if event.is_action_released(action):
			_fire(index, false)
			get_viewport().set_input_as_handled()
			return


func _set_page_relative(delta: int) -> void:
	if _control_terminal == null or not _control_terminal.has_method("set_active_page"):
		return
	var current: int = int(_control_terminal.call("active_page_number"))
	_control_terminal.call("set_active_page", current + delta)
	_refresh_left = 0.0


## Источник не передаём — fire_slot сам по умолчанию берёт "slot:N", ровно
## тот же ключ, что использует само окно от своих хоткеев: hud_control_
## terminal.gd уже отслеживает и подчищает такие holds в своём _process (не
## гейтует на _open — CONTROL-ACTIONS-V0 «компактная лента»), второй
## held-набор здесь не нужен.
func _fire(index: int, pressed: bool) -> void:
	if _control_terminal == null or not _control_terminal.has_method("fire_slot"):
		return
	_control_terminal.call("fire_slot", index, pressed)
