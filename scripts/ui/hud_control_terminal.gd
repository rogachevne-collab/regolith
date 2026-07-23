extends Control
## Инженерный SCADA/HMI терминал управления сборкой (CONTROL-ACTIONS-V0).
## Светлая приборная палитра — намеренно отдельная от HudTokens (тёмный игровой
## HUD): это встроенный приборный экран, а не игровой оверлей.
##
## Данные — из ControlTerminalSnapshotBuilder через WorldCommandGateway
## (обновление 10 Гц). Уставки и их шаг/единицы/диапазоны берутся из
## ParameterCatalog (game_balance.json), а не хардкодятся здесь. Иконки — глифы
## Lucide из lucide.ttf. Mock-данные остаются фолбэком, когда гейтвея нет
## (изолированная сцена вёрстки scenes/ui/test_control_terminal.tscn).

const COL_L := 322.0
const COL_R := 262.0

# --- Светлая приборная палитра (high-performance HMI / ISA-101) ---
const HOUSING := Color(0.612, 0.635, 0.663)
const PANEL := Color(0.874, 0.886, 0.898)
const HEAD := Color(0.812, 0.827, 0.847)
const CELL := Color(0.914, 0.922, 0.933)
const CELLALT := Color(0.890, 0.898, 0.910)
const LINE := Color(0.745, 0.769, 0.796)
const LINE2 := Color(0.663, 0.690, 0.721)
const SEL := Color(0.792, 0.839, 0.878)
const TXT := Color(0.114, 0.133, 0.157)
const TXT2 := Color(0.306, 0.333, 0.365)
const DIM := Color(0.463, 0.494, 0.525)
const FAINT := Color(0.604, 0.631, 0.663)
const AMBER := Color(0.690, 0.455, 0.102)
const RED := Color(0.753, 0.224, 0.169)
const FLD := Color(0.945, 0.953, 0.961)
const DARKCHIP := Color(0.227, 0.255, 0.282)
const NOM := Color(0.243, 0.478, 0.314)

const ICON_TTF := "res://resources/ui/icons/lucide/font/lucide.ttf"
const GLYPHS := {
	"extend": 58459, "retract": 58453, "stop": 57703, "reverse": 58385,
	"power": 57664, "rotate_cw": 57673, "rotate_ccw": 57672, "gauge": 57791,
	"piston": 57799, "rotor": 57673, "hinge": 58251, "drill": 58765,
	"cpu": 57513, "battery": 57431, "package": 57641,
	"ok": 57894, "idle": 57471, "warn": 57747, "no_power": 58461, "broken": 57476,
	"plus": 57661, "minus": 57628, "grip": 57579, "sliders": 58010, "equal": 57789,
	"pencil": 57849, "search": 57681, "close": 57778, "check": 57452,
}

## Хоткеи клавиш пульта — существующие действия тулбара, не сырые keycode:
## раскладка и ремап живут в project.godot (AGENTS «Input actions»).
const SLOT_ACTIONS: Array[StringName] = [
	&"toolbar_slot_1", &"toolbar_slot_2", &"toolbar_slot_3",
	&"toolbar_slot_4", &"toolbar_slot_5", &"toolbar_slot_6",
	&"toolbar_slot_7", &"toolbar_slot_8", &"toolbar_slot_9",
]
## Единственный источник размерности бара — ActionBarState (симуляция);
## своей константы тут больше нет, иначе рассинхрон с сервером ловится не
## компилятором, а игроком в проде (Dictionary-ключи GDScript не типизирует).
const PAGE_COUNT := ActionBarState.PAGE_COUNT
const SLOTS_PER_PAGE := ActionBarState.SLOTS_PER_PAGE

## Перетаскиваемая команда/параметр. Payload несёт всё, что нужно слоту, чтобы
## потом собрать команду без обратных ссылок на UI. Не кликается: единственный
## сигнал «это можно перетащить» — подсветка под курсором (см. set_hover_style).
class DragSource:
	extends PanelContainer

	var payload: Dictionary = {}
	var _normal_style: StyleBox
	var _hover_style: StyleBox

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if payload.is_empty():
			return null
		var preview := Label.new()
		preview.text = str(payload.get("label", "—"))
		preview.add_theme_color_override("font_color", Color(0.114, 0.133, 0.157))
		set_drag_preview(preview)
		return payload

	func set_hover_style(normal: StyleBox, hover: StyleBox) -> void:
		_normal_style = normal
		_hover_style = hover
		add_theme_stylebox_override("panel", normal)
		if payload.is_empty():
			return
		mouse_default_cursor_shape = Control.CURSOR_DRAG
		if not mouse_entered.is_connected(_on_hover_enter):
			mouse_entered.connect(_on_hover_enter)
			mouse_exited.connect(_on_hover_exit)

	func _on_hover_enter() -> void:
		if _hover_style != null:
			add_theme_stylebox_override("panel", _hover_style)

	func _on_hover_exit() -> void:
		if _normal_style != null:
			add_theme_stylebox_override("panel", _normal_style)


## Клавиша пульта: принимает и команду, и параметр.
class DropKey:
	extends PanelContainer

	var terminal: Node
	var slot_index := 0

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return (
			data is Dictionary
			and str((data as Dictionary).get("kind", "")).begins_with("control_")
		)

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if terminal != null and data is Dictionary:
			terminal.call("bind_slot", slot_index, data)


## Трек параметра — физическая шкала, не картинка: клик и протяг по нему пишут
## абсолютное значение (param.set) прямо во время движения, как реальный
## слайдер на приборной панели, а не только после отпускания.
class SliderTrack:
	extends Control

	var terminal: Node
	var param_id: String = ""
	var _dragging := false

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index != MOUSE_BUTTON_LEFT:
				return
			accept_event()
			if mouse.pressed:
				_dragging = true
				_apply(mouse.position.x)
			elif _dragging:
				_dragging = false
				if terminal != null:
					terminal.call("_end_slider_drag")
		elif _dragging and event is InputEventMouseMotion:
			accept_event()
			_apply((event as InputEventMouseMotion).position.x)

	func _apply(local_x: float) -> void:
		if terminal == null or param_id.is_empty() or size.x <= 0.0:
			return
		terminal.call(
			"_apply_slider_ratio", param_id, clampf(local_x / size.x, 0.0, 1.0)
		)


var _frame: PanelContainer
var _icon_font: FontFile
## Локальный кэш бара текущего хоста — источник правды теперь
## SimulationWorld (ActionBarState по element_id ControlSeat-хоста), сюда
## приезжает из control_terminal_snapshot.action_bar. bind_slot/clear_slot
## шлют команду в симуляцию, а не мутируют это напрямую (кроме фолбэка без
## гейтвея — см. _submit_action_slot).
var _bar_pages: Array = []
## Хост текущего бара (element_id элемента с ролью ControlSeat), 0 = не
## резолвлен. Отдельно от _target_assembly: бар принадлежит хосту, список
## узлов — сборке, это разные скоупы (CONTROL-ACTIONS-V0 «Хосты бара»).
var _host_element_id := 0
var _page := 0
var _strip: HBoxContainer
var _page_row: HBoxContainer
var _gateway: Node
var _query: Node
var _player: Node
var _open := false

## Обновление живых значений — 10 Гц (окно модальное, чаще не нужно).
const REFRESH_S := 0.1
var _refresh_left := 0.0
var _interact_release_latch := false
var _list_box: VBoxContainer
var _list_scroll: ScrollContainer
var _alarm_box: VBoxContainer
var _nodes_count: Label
var _alarms_count: Label
var _alarms_head: Label
var _last_kv_value: Label
var _unit_name: Label
var _unit_tag: Label
var _power_value: Label
var _fp_box: VBoxContainer
var _nodes: Array = []
## Выбор живёт на element_id, а не на индексе строки: список фильтруется,
## сортируется и приезжает заново 10 раз в секунду.
var _selected_element_id := 0
var _filter := "all"
var _search := ""
var _search_edit: LineEdit
var _rename_edit: LineEdit
var _renaming := false
var _seg_row: HBoxContainer
## Живые хэндлы ползунков текущего фейсплейта: param_id → {fill, knob, value}.
## Нужны, чтобы двигать шкалу во время протяга без полной пересборки (иначе
## пересборка убивает захват мыши по перетаскиваемому SliderTrack на середине
## жеста).
var _slider_rows: Dictionary = {}
var _slider_drag_active := false
## Сборка, к которой прицепился пульт при открытии. Держим защёлку: после
## открытия курсор свободен, прицел больше не двигается, и перерезолв по
## наведению просто гасил бы панель.
var _target_assembly := 0
## Команды вида «удерж», ждущие отпускания: source → spec.
var _held: Dictionary = {}
## Отправленные команды, чей результат ещё не пришёл (для показа отказа).
var _pending_commands: Dictionary = {}
const FAULT_HOLD_S := 4.0
var _fault_left := 0.0
var _fault_text := ""
var _fault_cell: Label

## Какие параметры показывать для вида узла (id из ParameterCatalog).
const SETPOINTS := {
	"piston": [
		"piston.extend_velocity", "piston.retract_velocity", "piston.force",
		"piston.lower_limit", "piston.upper_limit",
	],
	"rotor": ["rotor.forward_velocity", "rotor.reverse_velocity", "rotor.torque"],
	"hinge": [
		"hinge.forward_velocity", "hinge.reverse_velocity", "hinge.torque",
		"hinge.lower_limit", "hinge.upper_limit",
	],
	"wheel": ["wheel.drive_torque", "wheel.brake_torque"],
	"suspension": [
		"suspension.stiffness", "suspension.damping", "suspension.travel",
	],
}

## ActionCatalog (спека §ActionCatalog MVP) по виду узла:
## [action_id, глиф, подпись, вид ввода]. Глаголы — тонкие обёртки над уже
## существующими командами гейтвея, своего стока у пульта нет.
const COMMANDS := {
	"piston": [
		["piston.extend", "extend", "Выдвинуть", "удерж"],
		["piston.retract", "retract", "Втянуть", "удерж"],
		["actuator.stop", "stop", "Стоп", "раз"],
		["actuator.reverse", "reverse", "Реверс", "раз"],
		["actuator.motor_toggle", "power", "Мотор", "тумб"],
	],
	"hinge": [
		["hinge.extend", "extend", "Согнуть", "удерж"],
		["hinge.retract", "retract", "Разогнуть", "удерж"],
		["actuator.stop", "stop", "Стоп", "раз"],
		["actuator.reverse", "reverse", "Реверс", "раз"],
		["actuator.motor_toggle", "power", "Мотор", "тумб"],
	],
	"rotor": [
		["rotor.spin_cw", "rotate_cw", "Вращать →", "удерж"],
		["rotor.spin_ccw", "rotate_ccw", "Вращать ←", "удерж"],
		["actuator.stop", "stop", "Стоп", "раз"],
		["actuator.reverse", "reverse", "Реверс", "раз"],
		["actuator.motor_toggle", "power", "Мотор", "тумб"],
	],
	"wheel": [
		["wheel.steerable_toggle", "sliders", "Поворотное", "тумб"],
		["wheel.invert_drive_toggle", "reverse", "Направление", "тумб"],
	],
}

## Глаголы «удерж»: нажал — поехал, отпустил — стоп. Всё остальное — разовое.
const MOMENTARY_ACTIONS: Array[String] = [
	"piston.extend", "piston.retract",
	"hinge.extend", "hinge.retract",
	"rotor.spin_cw", "rotor.spin_ccw",
]

## Сегмент-фильтр списка узлов: [id, подпись]. `alarm` — не категория, а срез.
const FILTERS := [
	["all", "Все"], ["actuator", "Приводы"], ["machine", "Машины"],
	["alarm", "Аварии"],
]


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_query = ctx.get("query")
	_player = ctx.get("player")
	if _gateway != null and _gateway.has_signal("command_completed"):
		_gateway.command_completed.connect(_on_command_completed)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_icon_font()
	_build()
	_apply_open_state()


func is_open() -> bool:
	return _open


## Контракт для ToolController: пока окно открыто, мир не трогаем. Без этого
## клики по кнопкам пульта уходили ещё и в игру (бурили технику на фоне).
## Латч держит блок до отпускания `interact`, иначе то же нажатие,
## закрывшее окно, сразу же сработает по миру.
func blocks_world_interact() -> bool:
	return _open or _interact_release_latch


func close_for_interact() -> void:
	# `interact` (E) is polled from the raw Input singleton by ToolController,
	# bypassing whatever the GUI focus consumed — so typing the letter "e" into
	# a field here would otherwise close the whole terminal mid-keystroke.
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	_interact_release_latch = true
	close()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


## Точка входа из ToolController (`E` в interaction-range архетипа
## `control_terminal`) — тот же контракт `try_open_on_target`, что у
## actuator/wheel/industry-панелей. Архетип несёт роль `ControlSeat`, поэтому
## перехватывается ДО того, как интеракт успеет собраться в `toggle_control_seat`
## и попытаться посадить игрока в стационарную консоль (CONTROL-ACTIONS-V0
## «Хосты бара»).
const INTERACT_RANGE_M := 4.0


func try_open_on_target(hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.distance > INTERACT_RANGE_M
		or str(hit.metadata.get("archetype_id", "")) != "control_terminal"
	):
		return false
	open()
	return true


func open() -> void:
	if _open:
		return
	if not UIWindowStack.push(self, Callable(self, "close"), Callable(self, "_on_stack_escape")):
		return
	_open = true
	# Сидя — бар и так резолвится непрерывно фоном (см. _process), сбрасывать
	# цель незачем: это стёрло бы страницу/выбор узла, которые игрок уже
	# выставил через компактную ленту, закрытым окном. Не сидя — прицел мог
	# уйти на другую машину с прошлого открытия, тут сброс на месте: цель
	# фиксируется заново, дальше игрок работает мышью и прицел стоит там, где
	# его бросили.
	var seated := (
		_player != null
		and _player.has_method("is_in_vehicle")
		and bool(_player.call("is_in_vehicle"))
	)
	if not seated:
		_target_assembly = 0
	_refresh_left = 0.0
	_apply_open_state()
	_refresh()


func close() -> void:
	if not _open:
		return
	_open = false
	_release_holds()
	_apply_open_state()
	UIWindowStack.remove(self)


## Esc сначала отменяет правку имени и только потом закрывает окно.
func _on_stack_escape() -> void:
	if _renaming:
		_cancel_rename()
	else:
		close()


func _apply_open_state() -> void:
	if _frame != null:
		_frame.visible = _open
	if _open:
		if _player != null and _player.has_method("set_gameplay_input_enabled"):
			_player.call("set_gameplay_input_enabled", false)
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		if _player != null and _player.has_method("set_gameplay_input_enabled"):
			_player.call("set_gameplay_input_enabled", true)
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(delta: float) -> void:
	if _interact_release_latch and not Input.is_action_pressed(&"interact"):
		_interact_release_latch = false
	_release_stale_holds()
	# Бар обновляется, пока игрок сидит, даже если окно закрыто — компактная
	# лента (hud_compact_action_bar.gd) переиспользует именно этот бар и эту
	# же _fire_slot, а не дублирует резолв цели и исполнение глаголов.
	# Список узлов/фейсплейт/аварии — тяжелее и нужны только открытому окну.
	var seated := (
		_player != null
		and _player.has_method("is_in_vehicle")
		and bool(_player.call("is_in_vehicle"))
	)
	if not _open and not seated:
		return
	if _open and _fault_left > 0.0:
		_fault_left = maxf(_fault_left - delta, 0.0)
		if _fault_left <= 0.0:
			_fault_text = ""
			_update_fault_cell()
	_refresh_left = maxf(_refresh_left - delta, 0.0)
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_S
	_refresh()


## Живые данные: сидя — своя сборка, иначе — сборка наведённого элемента.
## Без гейтвея (изолированная сцена вёрстки) остаются mock-данные.
func _refresh() -> void:
	if _gateway == null or not _gateway.has_method("control_terminal_snapshot"):
		return
	# Пока тащат (drag-drop или протяг ползунка) — не перестраиваем: иначе
	# drag-источник освободится под курсором либо SliderTrack посреди жеста
	# уедет вместе со своим захватом мыши.
	if get_viewport().gui_is_dragging() or _slider_drag_active:
		return
	var snap: Dictionary = _gateway.call(
		"control_terminal_snapshot",
		_target_assembly,
		_aimed_element_id()
	)
	if not bool(snap.get("valid", false)):
		# Молча оставлять на экране mock-данные нельзя: пульт врал бы живыми на
		# вид показаниями несуществующей техники.
		_set_target_assembly(0)
		_apply_bar_snapshot(0, [])
		if _open:
			_fill_unit(snap)
			_fill_nodes([])
			_fill_alarms([])
		return
	if _target_assembly <= 0:
		_set_target_assembly(int(snap.get("assembly_id", 0)))
	var bar: Dictionary = snap.get("action_bar", {})
	_apply_bar_snapshot(
		int(snap.get("control_seat_element_id", 0)),
		bar.get("pages", [])
	)
	if _open:
		_fill_unit(snap)
		_fill_nodes(snap.get("nodes", []))
		_fill_alarms(snap.get("alarms", []))


# ---------- компактная лента (hud_compact_action_bar.gd) ----------
# Читает и стреляет через тот же бар и ту же _fire_slot, что и полное окно —
# не копия логики, один источник правды на оба поверхности пульта.

func active_page_slots() -> Array:
	return _page_slots()


func active_page_number() -> int:
	return _page


func fire_slot(index: int, pressed: bool, source := "") -> void:
	_fire_slot(index, pressed, source)


func set_active_page(index: int) -> void:
	_set_page(index)


## Бар приезжает целиком из снапшота — это хостовое авторитетное состояние,
## не то, что рисует сама панель. Смена хоста (в т.ч. на «нет хоста») сбрасывает
## текущую страницу: чужая страница №7 на новом хосте ничего не значит.
func _apply_bar_snapshot(host_element_id: int, pages: Array) -> void:
	var host_changed := host_element_id != _host_element_id
	_host_element_id = host_element_id
	_bar_pages = pages if not pages.is_empty() else _empty_bar_pages()
	if host_changed:
		_page = 0
	# Полоса пульта — часть закрытого окна (_frame.visible=false), пока
	# не открыто перестраивать её незачем: данные (_bar_pages) для компактной
	# ленты уже свежие вне зависимости от этого.
	if _open:
		_fill_pages()
		_fill_slots()


static func _empty_bar_pages() -> Array:
	var pages: Array = []
	for _page_index in range(PAGE_COUNT):
		var slots: Array = []
		for _slot_index in range(SLOTS_PER_PAGE):
			slots.append({})
		pages.append(slots)
	return pages


## Смена цели тянет за собой бар: клавиши принадлежат технике, а не игроку,
## поэтому полоса пульта и выбор узла перерисовываются под новую сборку.
func _set_target_assembly(assembly_id: int) -> void:
	if assembly_id == _target_assembly:
		return
	_release_holds()
	_target_assembly = assembly_id
	_selected_element_id = 0
	_cancel_rename()
	_page = 0
	_fill_pages()
	_fill_slots()


func _aimed_element_id() -> int:
	if _query == null:
		return 0
	var hit: Variant = _query.get("current_hit")
	if hit == null or not bool(hit.get("valid")):
		return 0
	var meta: Dictionary = hit.get("metadata")
	return int(meta.get("element_id", 0))


func _unhandled_input(event: InputEvent) -> void:
	# Открытие — через InputMap-действие (physical K), чтобы биндилось как всё
	# остальное управление и не зависело от раскладки.
	if event.is_action_pressed("control_terminal_toggle"):
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not _open:
		return
	if event.is_action_pressed("toolbar_page_prev"):
		_set_page(_page - 1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toolbar_page_next"):
		_set_page(_page + 1)
		get_viewport().set_input_as_handled()
		return
	# Пока курсор в поле ввода, цифры — это текст, а не команды пульта.
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	for index in range(SLOT_ACTIONS.size()):
		var action := SLOT_ACTIONS[index]
		if event.is_action_pressed(action) and not event.is_echo():
			_fire_slot(index, true)
			get_viewport().set_input_as_handled()
			return
		if event.is_action_released(action):
			_fire_slot(index, false)
			get_viewport().set_input_as_handled()
			return


## Срабатывает на ОТПУСКАНИЕ, не на нажатие. Это не стиль, а необходимость:
## элементы, что кликабельны, часто же и перетаскиваются (DragSource). Годот
## распознаёт drag только после нажатия, поэтому нажатие ещё не значит клик.
## Если жест стал перетаскиванием, control вообще не получает событие
## отпускания (viewport забирает мышь под DnD) — то есть клик просто не
## сработает, ровно как нужно. Огонь на нажатии стрелял бы всегда, ещё до
## того, как понятно, тащит игрок или кликает.
func _on_click(event: InputEvent, action: Callable) -> void:
	if (
		event is InputEventMouseButton
		and not event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
	):
		action.call()


## Единственная точка отправки параметра в симуляцию: её используют и клик по ±,
## и слот `param.*`, и будущий ввод числа с клавиатуры.
func _submit(command_kind: String, element_id: int, params: Dictionary) -> void:
	if _gateway == null or command_kind.is_empty():
		return
	var command_id: int = _gateway.call("submit", {
		"kind": StringName(command_kind),
		"source": self,
		"target": {
			"valid": true,
			"target_kind": &"element",
			"metadata": {"element_id": element_id},
		},
		"parameters": params,
	})
	_pending_commands[command_id] = true


## Диагностика без логов (спека §Диагностика): отказ команды пульта выводится
## причиной в статус-баре, а не молчит. Успех ничего не пишет.
func _on_command_completed(command_id: int, result: Dictionary) -> void:
	if not _pending_commands.erase(command_id):
		return
	var reason := StringName(result.get("reason", &"ok"))
	if reason == &"ok":
		return
	_fault_text = HudTokens.status_label(reason).to_lower()
	_fault_left = FAULT_HOLD_S
	_update_fault_cell()


func _update_fault_cell() -> void:
	if _fault_cell == null:
		return
	_fault_cell.text = _fault_text
	_fault_cell.visible = not _fault_text.is_empty()


func _submit_param(
	param_id: String,
	value: float,
	element_id: int,
	joint_id: int
) -> void:
	var entry := GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return
	var command_kind := str(entry.get("command", ""))
	var params := {str(entry.get("field", "")): value}
	match str(entry.get("target", "element")):
		"joint":
			params["joint_id"] = joint_id
		_:
			if command_kind == "configure_wheel":
				params["wheel_element_id"] = element_id
			else:
				params["suspension_element_id"] = element_id
	_submit(command_kind, element_id, params)


## Часть уставок клампится не постоянным диапазоном каталога, а фактическим
## паспортом конкретного узла (предел хода этой подвески, тормозной момент
## этой модели колеса) — каталог даёт разумный дефолт, живой снапшот, если
## несёт точные границы этого экземпляра, их переопределяет. Без этого шаг
## либо упирался бы в чужой лимит раньше времени, либо разрешал то, что
## authoritative-сторона всё равно отклонит.
func _effective_bounds(param_id: String, detail: Dictionary, entry: Dictionary) -> Vector2:
	var lo := float(entry.get("soft_min", 0.0))
	var hi := float(entry.get("soft_max", 1.0))
	match param_id:
		"suspension.travel":
			lo = float(detail.get("min_travel_m", lo))
			hi = float(detail.get("max_travel_m", hi))
		"wheel.brake_torque":
			hi = float(detail.get("max_brake_torque_n_m", hi))
	return Vector2(lo, hi)


## Клик по «−»/«+»: шаг из каталога от текущего живого значения, кламп по
## soft-диапазону. Авторитетный кламп всё равно за симуляцией.
func _apply_param_step(param_id: String, direction: int) -> void:
	var entry := GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return
	var node := _selected_node()
	var detail: Dictionary = node.get("detail", {})
	var field := str(entry.get("field", ""))
	var bounds := _effective_bounds(param_id, detail, entry)
	var value := clampf(
		float(detail.get(field, 0.0)) + float(entry.get("step", 0.0)) * direction,
		bounds.x,
		bounds.y
	)
	_submit_param(
		param_id,
		value,
		int(node.get("element_id", 0)),
		int(node.get("joint_id", 0))
	)


## Живое состояние цели из последнего снапшота. Инверсия тумблера и
## относительный шаг обязаны считаться от того, что сейчас в симуляции, а не от
## того, что запомнил слот при привязке.
func _live_detail(element_id: int, joint_id: int) -> Dictionary:
	for node_variant: Variant in _nodes:
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		var matches := (
			(joint_id > 0 and int(node.get("joint_id", 0)) == joint_id)
			or (joint_id <= 0 and int(node.get("element_id", -1)) == element_id)
		)
		if matches:
			var detail: Variant = node.get("detail", {})
			return detail if detail is Dictionary else {}
	return {}


static func _is_momentary(action_id: String) -> bool:
	return action_id in MOMENTARY_ACTIONS


## Вид узла для глагола: у ротора цель — скорость, у поршня/шарнира — позиция.
static func _spec_kind(spec: Dictionary) -> String:
	var kind := str(spec.get("node_kind", ""))
	if not kind.is_empty():
		return kind
	return str(spec.get("action_id", "")).split(".")[0]


## Единственный исполнитель глаголов: и клавиша пульта, и кнопка в фейсплейте
## идут сюда. `pressed=false` приходит на отпускании — только для «удерж».
## Пульт ничего не мутирует сам: собирает существующую команду гейтвея.
func _run_action(spec: Dictionary, pressed: bool) -> void:
	if _gateway == null or spec.is_empty():
		return
	var action := str(spec.get("action_id", ""))
	if action.is_empty():
		return
	var element_id := int(spec.get("element_id", 0))
	var joint_id := int(spec.get("joint_id", 0))
	if not pressed:
		if _is_momentary(action):
			_submit("set_actuator_target", element_id, {
				"joint_id": joint_id,
				"mode": SimulationMotorState.ControlMode.STOP,
			})
		return
	if action.begins_with("param."):
		_run_param_action(spec, element_id, joint_id)
		return
	match action:
		"wheel.steerable_toggle":
			_submit("configure_wheel", element_id, {
				"wheel_element_id": element_id,
				"steerable": not bool(
					_live_detail(element_id, 0).get("steerable", false)
				),
			})
		"wheel.invert_drive_toggle":
			_submit("configure_wheel", element_id, {
				"wheel_element_id": element_id,
				"invert_drive": not bool(
					_live_detail(element_id, 0).get("drive_inverted", false)
				),
			})
		"actuator.stop":
			_submit("set_actuator_target", element_id, {
				"joint_id": joint_id,
				"mode": SimulationMotorState.ControlMode.STOP,
			})
		"actuator.motor_toggle":
			# Мотор включается/выключается только через set_actuator_target:
			# у configure_actuator поля `enabled` нет.
			_submit("set_actuator_target", element_id, {
				"joint_id": joint_id,
				"mode": SimulationMotorState.ControlMode.STOP,
				"enabled": not bool(
					_live_detail(element_id, joint_id).get("enabled", true)
				),
			})
		"actuator.reverse":
			_submit(
				"set_actuator_target",
				element_id,
				_reverse_params(spec, element_id, joint_id)
			)
		"piston.extend", "hinge.extend", "rotor.spin_cw":
			_submit(
				"set_actuator_target",
				element_id,
				_drive_params(spec, element_id, joint_id, true)
			)
		"piston.retract", "hinge.retract", "rotor.spin_ccw":
			_submit(
				"set_actuator_target",
				element_id,
				_drive_params(spec, element_id, joint_id, false)
			)


## `param.set` пишет абсолютное значение, `increase/decrease` — относительный
## шаг от живого значения с клампом по soft-диапазону каталога.
func _run_param_action(spec: Dictionary, element_id: int, joint_id: int) -> void:
	var param_id := str(spec.get("param_id", ""))
	var entry := GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return
	var action := str(spec.get("action_id", ""))
	var value := float(spec.get("value", 0.0))
	if action != "param.set":
		var detail := _live_detail(element_id, joint_id)
		var delta := float(spec.get("delta", 0.0))
		if action == "param.decrease":
			delta = -delta
		var field := str(entry.get("field", ""))
		var bounds := _effective_bounds(param_id, detail, entry)
		value = clampf(
			float(detail.get(field, 0.0)) + delta,
			bounds.x,
			bounds.y
		)
	_submit_param(param_id, value, element_id, joint_id)


## Поршень/шарнир идут на предел хода, ротор — на скорость: у него ход не задан.
func _drive_params(
	spec: Dictionary,
	element_id: int,
	joint_id: int,
	forward: bool
) -> Dictionary:
	var detail := _live_detail(element_id, joint_id)
	if _spec_kind(spec) == "rotor":
		var speed := float(detail.get(
			"extend_velocity_mps" if forward else "retract_velocity_mps",
			0.0
		))
		return {
			"joint_id": joint_id,
			"mode": SimulationMotorState.ControlMode.VELOCITY,
			"target_velocity_mps": speed if forward else -speed,
		}
	return {
		"joint_id": joint_id,
		"mode": SimulationMotorState.ControlMode.POSITION,
		"target_position_m": float(detail.get(
			"upper_limit_m" if forward else "lower_limit_m",
			0.0
		)),
	}


## Зеркало текущей цели (спека: «reverse читает текущий mode/target и шлёт
## зеркальный»). Ротор — знак скорости, поршень/шарнир — дальний предел хода.
func _reverse_params(
	spec: Dictionary,
	element_id: int,
	joint_id: int
) -> Dictionary:
	var detail := _live_detail(element_id, joint_id)
	if _spec_kind(spec) == "rotor":
		var velocity := float(detail.get("target_velocity_mps", 0.0))
		if absf(velocity) < 0.000001:
			velocity = float(detail.get("observed_velocity", 0.0))
		if absf(velocity) < 0.000001:
			velocity = float(detail.get("extend_velocity_mps", 0.0))
		return {
			"joint_id": joint_id,
			"mode": SimulationMotorState.ControlMode.VELOCITY,
			"target_velocity_mps": -velocity,
		}
	var lower := float(detail.get("lower_limit_m", 0.0))
	var upper := float(detail.get("upper_limit_m", 0.0))
	var target := float(detail.get("target_position_m", 0.0))
	var to_lower := absf(target - lower) > absf(target - upper)
	return {
		"joint_id": joint_id,
		"mode": SimulationMotorState.ControlMode.POSITION,
		"target_position_m": lower if to_lower else upper,
	}


# ---------- удержание ----------

## Нажатие «удерж» регистрируется здесь, чтобы отпускание нашлось даже когда
## событие до окна не дошло: курсор ушёл с кнопки, начался drag, окно закрылось.
## Иначе поршень уезжает в предел и остаётся там.
func _begin_hold(source: String, spec: Dictionary) -> void:
	if _is_momentary(str(spec.get("action_id", ""))):
		_held[source] = spec.duplicate(true)


func _release_stale_holds() -> void:
	for source: Variant in _held.keys():
		var key := str(source)
		var alive := false
		if key == "mouse":
			alive = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		elif key.begins_with("slot:"):
			# Не гейтуем на _open: тот же хоткей держит слот и через окно
			# (открыто), и через компактную ленту (окно закрыто, сидя) —
			# живо, пока физически зажата клавиша, а не пока видно окно.
			var index := int(key.substr(5))
			alive = (
				index >= 0
				and index < SLOT_ACTIONS.size()
				and Input.is_action_pressed(SLOT_ACTIONS[index])
			)
		if not alive:
			var spec: Dictionary = _held[key]
			_held.erase(key)
			_run_action(spec, false)


func _release_holds() -> void:
	for source: Variant in _held.keys():
		var spec: Dictionary = _held[source]
		_held.erase(source)
		_run_action(spec, false)


func _load_icon_font() -> void:
	if not FileAccess.file_exists(ICON_TTF):
		return
	_icon_font = FontFile.new()
	_icon_font.data = FileAccess.get_file_as_bytes(ICON_TTF)


func _icon(key: String, col: Color, size := 15) -> Control:
	var l := Label.new()
	if _icon_font != null and GLYPHS.has(key):
		l.text = String.chr(int(GLYPHS[key]))
		l.add_theme_font_override("font", _icon_font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# ---------- style helpers ----------

func _sbox(bg: Color, bl := 0, bt := 0, br := 0, bb := 0, bc := LINE) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.anti_aliasing = false
	s.bg_color = bg
	s.border_color = bc
	s.border_width_left = bl
	s.border_width_top = bt
	s.border_width_right = br
	s.border_width_bottom = bb
	s.content_margin_left = 0
	s.content_margin_right = 0
	s.content_margin_top = 0
	s.content_margin_bottom = 0
	return s


func _panel(bg: Color, bl := 0, bt := 0, br := 0, bb := 0, bc := LINE) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _sbox(bg, bl, bt, br, bb, bc))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _lbl(text: String, col: Color, size := 13, halign := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	l.horizontal_alignment = halign
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _vbox(sep := 0) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v


func _hbox(sep := 0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h


func _vrule() -> Panel:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", _sbox(LINE))
	p.custom_minimum_size = Vector2(1, 0)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _hrule() -> Panel:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", _sbox(LINE))
	p.custom_minimum_size = Vector2(0, 1)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _pad(node: Control, l := 0, t := 0, r := 0, b := 0) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_bottom", b)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(node)
	return m


# ---------- build ----------

func _build() -> void:
	# Пульт занимает весь экран: это рабочий терминал, а не всплывающее окошко.
	# Фиксированный размер резал контент на широких экранах и оставлял поля.
	_frame = _panel(PANEL, 1, 1, 1, 1, LINE2)
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_frame)

	var root := _vbox(0)
	_frame.add_child(root)

	root.add_child(_build_topbar())
	root.add_child(_hrule())

	var body := _build_body()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	root.add_child(_build_softbar())
	root.add_child(_build_statusbar())


func _build_topbar() -> Control:
	var bar := _panel(HEAD)
	var h := _hbox(0)
	bar.add_child(h)

	var unit := _vbox(1)
	_unit_name = _lbl("Нет цели", TXT, 14)
	unit.add_child(_unit_name)
	_unit_tag = _lbl("наведись на технику", DIM, 11)
	unit.add_child(_unit_tag)
	h.add_child(_pad_col(unit, 14, 8, 14, 8, 0, 1))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(spacer)

	h.add_child(_kv("Питание", "—", TXT))
	_power_value = _last_kv_value
	h.add_child(_kv("Узлов", "0", TXT))
	_nodes_count = _last_kv_value
	h.add_child(_kv("Аварии", "0", DIM))
	_alarms_head = _last_kv_value
	return bar


## Шапка из живого снапшота: тег сборки, потребление против выработки, счётчики.
## Красный «нет питания» — единственный цвет, который здесь допустим.
func _fill_unit(snap: Dictionary) -> void:
	var valid := bool(snap.get("valid", false))
	var assembly_id := int(snap.get("assembly_id", 0))
	if _unit_name != null:
		_unit_name.text = "Сборка %02d" % assembly_id if valid else "Нет цели"
	if _unit_tag != null:
		_unit_tag.text = (
			"ASM‑%02d · %d элем." % [assembly_id, int(snap.get("element_count", 0))]
			if valid
			else "наведись на технику и открой пульт"
		)
	if _power_value == null:
		return
	var power: Dictionary = snap.get("power", {})
	if not valid or not bool(power.get("valid", false)):
		_power_value.text = "—"
		_power_value.add_theme_color_override("font_color", DIM)
		return
	# Генераторов на сборке может не быть вовсе — тогда «0.0 кВт выработки» не
	# отказ, а норма: питание идёт из АКБ. Показываем расход и заряд.
	_power_value.text = "%.2f кВт · АКБ %.0f %%" % [
		float(power.get("demand_w", 0.0)) * 0.001,
		float(power.get("battery_fraction", 0.0)) * 100.0,
	]
	_power_value.add_theme_color_override(
		"font_color",
		TXT if bool(power.get("powered", false)) else RED
	)


func _pad_col(node: Control, l: int, t: int, r: int, b: int, _x: int, br_w: int) -> Control:
	var wrap := _panel(Color(0, 0, 0, 0), 0, 0, br_w, 0)
	wrap.add_child(_pad(node, l, t, r, b))
	return wrap


func _kv(k: String, v: String, vcol: Color) -> Control:
	var wrap := _panel(Color(0, 0, 0, 0), 1, 0, 0, 0)
	var col := _vbox(1)
	col.custom_minimum_size = Vector2(100, 0)
	col.add_child(_lbl(k, DIM, 10))
	_last_kv_value = _lbl(v, vcol, 13)
	col.add_child(_last_kv_value)
	wrap.add_child(_pad(col, 14, 8, 14, 8))
	return wrap


func _build_body() -> Control:
	var h := _hbox(0)

	var left := _build_equipment()
	left.custom_minimum_size = Vector2(COL_L, 0)
	h.add_child(left)
	h.add_child(_vrule())

	var center := _build_faceplate()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(center)
	h.add_child(_vrule())

	var right := _build_alarms()
	right.custom_minimum_size = Vector2(COL_R, 0)
	h.add_child(right)
	return h


# ---------- left: equipment ----------

func _build_equipment() -> Control:
	var v := _vbox(0)

	_seg_row = _hbox(0)
	var seg_wrap := _panel(PANEL, 0, 0, 0, 1)
	seg_wrap.add_child(_seg_row)
	v.add_child(seg_wrap)
	_fill_filters()

	v.add_child(_build_search())

	# header row
	v.add_child(_eq_head())

	_list_box = _vbox(0)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll = _scroll(_list_box)
	v.add_child(_list_scroll)
	_fill_nodes(_mock_nodes())
	return v


func _fill_filters() -> void:
	if _seg_row == null:
		return
	for child: Node in _seg_row.get_children():
		_seg_row.remove_child(child)
		child.queue_free()
	for entry_variant: Variant in FILTERS:
		var entry: Array = entry_variant
		var id := str(entry[0])
		_seg_row.add_child(_seg_btn(str(entry[1]), id, id == "alarm"))


func _set_filter(id: String) -> void:
	if _filter == id:
		return
	_filter = id
	_fill_filters()
	_rebuild_list()


## Поиск по имени и тегу узла. Строка живёт вне перестройки списка, иначе
## обновление 10 Гц забирало бы фокус на каждом кадре.
func _build_search() -> Control:
	var wrap := _panel(PANEL, 0, 0, 0, 1)
	wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	var h := _hbox(6)
	h.add_child(_icon("search", DIM, 13))
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "поиск узла…"
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_edit(_search_edit)
	_search_edit.text_changed.connect(_on_search_changed)
	h.add_child(_search_edit)
	wrap.add_child(_pad(h, 12, 4, 12, 4))
	return wrap


## Поле ввода в приборной палитре: рамки нет, фон плоский — строка должна
## читаться как ячейка таблицы, а не как виджет игрового HUD.
func _style_edit(edit: LineEdit) -> void:
	edit.add_theme_stylebox_override("normal", _sbox(Color(0, 0, 0, 0)))
	edit.add_theme_stylebox_override("focus", _sbox(FLD, 0, 0, 0, 1, TXT2))
	edit.add_theme_color_override("font_color", TXT)
	edit.add_theme_color_override("font_placeholder_color", DIM)
	edit.add_theme_color_override("caret_color", TXT)
	edit.add_theme_color_override("font_selected_color", TXT)
	edit.add_theme_color_override("selection_color", SEL)
	edit.add_theme_font_size_override("font_size", 12)


func _on_search_changed(text: String) -> void:
	_search = text.strip_edges().to_lower()
	_rebuild_list()


## Срез списка под фильтр и поиск. Полный `_nodes` при этом не режем: живые
## значения слотов и фейсплейта читаются из него независимо от того, что видно.
func _visible_nodes() -> Array:
	var rows: Array = []
	for node_variant: Variant in _nodes:
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		match _filter:
			"alarm":
				if str(node.get("severity", "ok")) == "ok":
					continue
			"all":
				pass
			_:
				if str(node.get("category", "other")) != _filter:
					continue
		if not _search.is_empty():
			var haystack := "%s %s" % [_node_name(node), _node_tag(node)]
			if not haystack.to_lower().contains(_search):
				continue
		rows.append(node)
	return rows


## Вертикальная прокрутка для длинных списков (сборка легко даёт сотню узлов).
func _scroll(content: Control) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(content)
	return sc


## Fallback-данные, пока нет живого снапшота (изолированная сцена вёрстки).
static func _mock_nodes() -> Array:
	var piston_detail := {
		"observed": 0.82, "observed_velocity": 0.30, "target_position_m": 1.20,
		"power_draw_w": 120.0, "extend_velocity_mps": 0.50,
		"retract_velocity_mps": 0.50, "force_limit_n": 8000.0,
		"lower_limit_m": 0.0, "upper_limit_m": 1.20,
	}
	var rotor_detail := {
		"observed": 0.21, "observed_velocity": 0.21, "target_position_m": 0.0,
		"power_draw_w": 90.0, "extend_velocity_mps": 1.0,
		"retract_velocity_mps": 1.0, "force_limit_n": 6000.0,
	}
	return [
		{"element_id": 1, "joint_id": 1, "category": "actuator",
			"archetype_id": "piston_base", "ordinal": 1, "custom_name": "",
			"kind": "piston", "detail": piston_detail,
			"value_text": "0.82 м", "status": &"moving", "severity": "ok"},
		{"element_id": 2, "joint_id": 2, "category": "actuator",
			"archetype_id": "piston_base", "ordinal": 2, "custom_name": "",
			"kind": "piston", "detail": piston_detail,
			"value_text": "0.00 м", "status": &"idle", "severity": "ok"},
		{"element_id": 3, "joint_id": 3, "category": "actuator",
			"archetype_id": "rotor_base", "ordinal": 1, "custom_name": "",
			"kind": "rotor", "detail": rotor_detail,
			"value_text": "12.0 °/с", "status": &"moving", "severity": "ok"},
		{"element_id": 4, "joint_id": 4, "category": "actuator",
			"archetype_id": "hinge_base", "ordinal": 1, "custom_name": "",
			"kind": "hinge", "detail": {
				"observed": 0.77, "observed_velocity": 0.0,
				"target_position_m": 0.77, "power_draw_w": 40.0,
				"extend_velocity_mps": 0.8, "retract_velocity_mps": 0.8,
				"force_limit_n": 5000.0, "lower_limit_m": -0.79,
				"upper_limit_m": 0.79,
			},
			"value_text": "44 °", "status": &"joint_limit", "severity": "warn"},
		{"archetype_id": "drive_wheel", "ordinal": 1, "custom_name": "",
			"kind": "wheel", "detail": {
				"steerable": true, "drive_inverted": false,
				"drive_torque_scale": 0.8, "brake_torque_n_m": 180.0,
			},
			"value_text": "", "status": &"ok", "severity": "ok"},
		{"archetype_id": "stationary_drill", "ordinal": 1, "custom_name": "",
			"value_text": "", "status": &"no_power", "severity": "warn"},
		{"archetype_id": "processor", "ordinal": 1, "custom_name": "",
			"value_text": "62 %", "status": &"ok", "severity": "ok"},
		{"archetype_id": "rotor_base", "ordinal": 2, "custom_name": "",
			"kind": "rotor", "detail": rotor_detail,
			"value_text": "", "status": &"actuator_broken", "severity": "fault"},
		{"archetype_id": "power_battery", "ordinal": 1, "custom_name": "",
			"value_text": "70 %", "status": &"ok", "severity": "ok"},
		{"archetype_id": "cargo_store", "ordinal": 1, "custom_name": "",
			"value_text": "340/500", "status": &"ok", "severity": "ok"},
	]


func _seg_btn(text: String, id: String, alarm: bool) -> Control:
	var on := _filter == id
	var col := AMBER if alarm else (TXT if on else DIM)
	var bg := SEL if on else Color(0, 0, 0, 0)
	var b := _panel(bg, 0, 0, 1, 0)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.gui_input.connect(_on_click.bind(_set_filter.bind(id)))
	b.add_child(_pad(_lbl(text, col, 11, HORIZONTAL_ALIGNMENT_CENTER), 4, 6, 4, 6))
	return b


func _eq_head() -> Control:
	var wrap := _panel(CELLALT, 0, 0, 0, 1)
	var h := _hbox(0)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 5)
	m.add_theme_constant_override("margin_bottom", 5)
	m.add_child(h)
	var st := _lbl("", DIM, 10)
	st.custom_minimum_size = Vector2(20, 0)
	h.add_child(st)
	var nm := _lbl("УЗЕЛ", DIM, 10)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(nm)
	h.add_child(_lbl("ЗНАЧЕНИЕ", DIM, 10, HORIZONTAL_ALIGNMENT_RIGHT))
	wrap.add_child(m)
	return wrap


## Заполнение списка узлов из снапшота (или mock).
func _fill_nodes(nodes: Array) -> void:
	_nodes = nodes
	if _nodes_count != null:
		_nodes_count.text = str(nodes.size())
	_rebuild_list()


## Перестройка строк из уже полученных данных: её же зовут фильтр и поиск.
func _rebuild_list() -> void:
	if _list_box == null:
		return
	for child: Node in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	var visible_nodes := _visible_nodes()
	# Узел мог уехать из снапшота (разобрали, сменили цель) — тогда садимся на
	# первый видимый, а не показываем пустой фейсплейт.
	if _selected_node().is_empty() and not visible_nodes.is_empty():
		_selected_element_id = int(
			(visible_nodes[0] as Dictionary).get("element_id", 0)
		)
	# Перестройка сбрасывает прокрутку — возвращаем её, иначе длинный список
	# при обновлении 10 Гц просто невозможно листать.
	var keep_scroll := 0
	if _list_scroll != null:
		keep_scroll = _list_scroll.scroll_vertical
	var idx := 0
	for node_variant: Variant in visible_nodes:
		var node: Dictionary = node_variant
		var element_id := int(node.get("element_id", 0))
		_list_box.add_child(
			_eq_row(node, idx, element_id == _selected_element_id)
		)
		idx += 1
	if idx == 0:
		var empty := _panel(PANEL)
		empty.add_child(_pad(
			_lbl(_empty_list_text(), FAINT, 12),
			12, 14, 12, 14
		))
		_list_box.add_child(empty)
	if _list_scroll != null and keep_scroll > 0:
		_restore_scroll.call_deferred(keep_scroll)
	_fill_faceplate()


func _empty_list_text() -> String:
	if _nodes.is_empty():
		return "Нет цели — наведись на технику и открой пульт"
	if not _search.is_empty():
		return "Ничего не найдено"
	return "В этом срезе узлов нет"


func _restore_scroll(value: int) -> void:
	if _list_scroll != null:
		_list_scroll.scroll_vertical = value


func _on_row_input(event: InputEvent, element_id: int) -> void:
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
		and element_id != _selected_element_id
	):
		select_element(element_id)


## Выбор узла (клик по строке списка либо по строке аварии).
func select_element(element_id: int) -> void:
	if element_id == _selected_element_id:
		return
	_selected_element_id = element_id
	_cancel_rename()
	_rebuild_list()


## Выбор узла по позиции в видимом списке (дев-харнес вёрстки).
func select_index(index: int) -> void:
	var visible_nodes := _visible_nodes()
	if index < 0 or index >= visible_nodes.size():
		return
	select_element(int((visible_nodes[index] as Dictionary).get("element_id", 0)))


func _selected_node() -> Dictionary:
	for node_variant: Variant in _nodes:
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		if int(node.get("element_id", -1)) == _selected_element_id:
			return node
	return {}


func _node_name(node: Dictionary) -> String:
	var custom := str(node.get("custom_name", ""))
	if not custom.is_empty():
		return custom
	var label := HudTokens.archetype_label(str(node.get("archetype_id", "")))
	return "%s %02d" % [label.capitalize(), int(node.get("ordinal", 1))]


func _node_tag(node: Dictionary) -> String:
	return "%s%d" % [
		HudTokens.tool_code(str(node.get("archetype_id", ""))),
		int(node.get("ordinal", 1)),
	]


## Значение колонки: явный текст (mock) → форматирование по value_kind → статус.
func _node_value_text(node: Dictionary) -> String:
	var explicit := str(node.get("value_text", ""))
	if not explicit.is_empty():
		return explicit
	var value := float(node.get("value", 0.0))
	match str(node.get("value_kind", "none")):
		"length_m":
			return "%.2f м" % value
		"angle_rad":
			return "%.0f °" % rad_to_deg(value)
		"fraction":
			return "%.0f %%" % (value * 100.0)
	return HudTokens.status_label(StringName(node.get("status", &"ok"))).to_lower()


func _severity_color(severity: String) -> Color:
	match severity:
		"fault":
			return RED
		"warn":
			return AMBER
	return TXT


func _severity_mark(severity: String) -> String:
	match severity:
		"fault":
			return "■"
		"warn":
			return "▲"
	return "●"


func _eq_row(node: Dictionary, idx: int, selected: bool) -> Control:
	var severity := str(node.get("severity", "ok"))
	var mark := _severity_mark(severity)
	var name := _node_name(node)
	var tag := _node_tag(node)
	var val := _node_value_text(node)
	var vcol := _severity_color(severity)
	var bg := SEL if selected else (CELL if idx % 2 == 0 else CELLALT)
	var wrap := _panel(bg, (2 if selected else 0), 0, 0, 1, TXT2)
	wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	wrap.gui_input.connect(
		_on_row_input.bind(int(node.get("element_id", 0)))
	)
	# Наведение — не только курсор меняется, ряд обязан подсветиться: это
	# кликабельная таблица, а не статичный текст.
	if not selected:
		var hover_sbox := _sbox(_hover_bg(bg), 0, 0, 0, 1, TXT2)
		var normal_sbox := _sbox(bg, 0, 0, 0, 1, TXT2)
		wrap.mouse_entered.connect(
			func(): wrap.add_theme_stylebox_override("panel", hover_sbox)
		)
		wrap.mouse_exited.connect(
			func(): wrap.add_theme_stylebox_override("panel", normal_sbox)
		)
	var h := _hbox(0)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	m.add_child(h)

	var mk_col := AMBER if mark == "▲" else (RED if mark == "■" else (TXT2 if mark == "●" else FAINT))
	var mk := _lbl(mark, mk_col, 9)
	mk.custom_minimum_size = Vector2(20, 0)
	h.add_child(mk)

	var nm := _lbl(name, TXT, 13)
	h.add_child(nm)
	var tg := _lbl("  " + tag, FAINT, 11)
	h.add_child(tg)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)

	h.add_child(_lbl(val, vcol, 12, HORIZONTAL_ALIGNMENT_RIGHT))
	wrap.add_child(m)
	return wrap


# ---------- center: faceplate ----------

func _build_faceplate() -> Control:
	_fp_box = _vbox(0)
	_fill_faceplate()
	return _fp_box


## Перестройка фейсплейта под выбранный узел: шапка, показания, параметры (по
## ParameterCatalog для вида узла), команды. Для колеса параметры начинаются с
## булевых тумблеров (поворотность и направление привода).
func _fill_faceplate() -> void:
	if _fp_box == null:
		return
	# Пока переименовывают — фейсплейт не трогаем: перестройка 10 Гц иначе
	# забирает фокус и стирает набранное.
	if _rename_edit != null:
		return
	for child: Node in _fp_box.get_children():
		_fp_box.remove_child(child)
		child.queue_free()
	_slider_rows.clear()

	var node := _selected_node()
	if node.is_empty():
		var empty := _panel(PANEL)
		empty.add_child(_pad(_lbl("Узел не выбран", FAINT, 12), 14, 16, 14, 16))
		_fp_box.add_child(empty)
		return

	var kind := str(node.get("kind", "other"))
	var detail: Dictionary = node.get("detail", {})
	_fp_box.add_child(_fp_head(node))
	_fp_box.add_child(_fp_section("ПОКАЗАНИЯ", _fp_readings(node, kind, detail)))

	var setpoints := _fp_setpoints(kind, detail)
	if setpoints != null:
		_fp_box.add_child(_fp_section(
			"ПАРАМЕТРЫ · ПЕРЕТАЩИ СТРОКУ НА КЛАВИШУ (УСТАНОВИТЬ / ±ШАГ)",
			setpoints
		))

	var commands := _fp_commands(kind)
	if commands != null:
		_fp_box.add_child(_fp_section(
			"КОМАНДЫ · ПЕРЕТАЩИ НА КЛАВИШУ ПУЛЬТА ↓",
			commands
		))


func _fp_head(node: Dictionary) -> Control:
	var severity := str(node.get("severity", "ok"))
	var head := _panel(PANEL, 0, 0, 0, 1)
	var hh := _hbox(9)
	if _renaming:
		hh.add_child(_build_rename_edit(node))
	else:
		hh.add_child(_lbl(_node_name(node), TXT, 15))
		hh.add_child(_rename_button())
	hh.add_child(_lbl(_node_tag(node), DIM, 11))
	var stmk := Panel.new()
	stmk.add_theme_stylebox_override("panel", _sbox(
		NOM if severity == "ok" else _severity_color(severity)
	))
	stmk.custom_minimum_size = Vector2(8, 8)
	stmk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hh.add_child(_pad(stmk, 6, 0, 0, 0))
	hh.add_child(_lbl(
		HudTokens.status_label(StringName(node.get("status", &"ok"))).capitalize(),
		TXT2,
		12
	))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(sp)
	hh.add_child(_lbl("Режим", DIM, 11))
	hh.add_child(_mode_toggle())
	head.add_child(_pad(hh, 14, 10, 14, 10))
	return head


## Переименование узла оператором. Имя — per-instance override в снапшоте
## (SetElementNameCommand); пустая строка возвращает авто-подпись архетипа.
func _rename_button() -> Control:
	var b := _panel(Color(0, 0, 0, 0))
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.tooltip_text = "Переименовать узел"
	b.gui_input.connect(_on_click.bind(_begin_rename))
	b.add_child(_icon("pencil", FAINT, 13))
	return b


func _build_rename_edit(node: Dictionary) -> Control:
	_rename_edit = LineEdit.new()
	_rename_edit.text = str(node.get("custom_name", ""))
	_rename_edit.placeholder_text = _node_name(node)
	_rename_edit.max_length = SetElementNameCommand.MAX_LENGTH
	_rename_edit.custom_minimum_size = Vector2(240, 0)
	_style_edit(_rename_edit)
	_rename_edit.add_theme_font_size_override("font_size", 15)
	_rename_edit.text_submitted.connect(_on_rename_submitted)
	_rename_edit.grab_focus.call_deferred()
	return _rename_edit


func _begin_rename() -> void:
	if _renaming or _selected_node().is_empty():
		return
	_renaming = true
	_fill_faceplate()


func _cancel_rename() -> void:
	if not _renaming:
		return
	_renaming = false
	_rename_edit = null
	_fill_faceplate()


func _on_rename_submitted(text: String) -> void:
	var element_id := int(_selected_node().get("element_id", 0))
	_renaming = false
	_rename_edit = null
	if element_id > 0:
		_submit("set_element_name", element_id, {
			"element_id": element_id,
			"element_name": text,
		})
	_fill_faceplate()


func _fp_readings(node: Dictionary, kind: String, detail: Dictionary) -> Control:
	var v := _vbox(0)
	if kind == "wheel":
		# Поворотность/направление уже показаны тумблерами в «Уставках» ниже —
		# дублировать те же два бита здесь нечем, тут только то, чего там нет:
		# живая телеметрия контакта с грунтом.
		v.add_child(_pv_row(
			"Питание", "есть" if bool(detail.get("powered", false)) else "нет", ""
		))
		v.add_child(_pv_row(
			"Опора", "на грунте" if bool(detail.get("grounded", false)) else "в воздухе", ""
		))
		v.add_child(_pv_row(
			"Пробуксовка",
			"%.2f" % float(detail.get("slip_speed_mps", 0.0)),
			"м/с"
		))
		return v
	if kind == "suspension":
		# «Ход» тут был бы тем же числом, что «Ход подвески» в параметрах ниже —
		# живой телеметрии сжатия у подвески нет, дублировать нечего.
		v.add_child(_pv_row(
			"Допустимый ход",
			"%.2f…%.2f" % [
				float(detail.get("min_travel_m", 0.0)),
				float(detail.get("max_travel_m", 0.0)),
			],
			"м"
		))
		return v
	if kind in ["piston", "rotor", "hinge"]:
		var angular := kind != "piston"
		v.add_child(_pv_row(
			"Скорость",
			"%.2f" % float(detail.get("observed_velocity", 0.0)),
			"рад/с" if angular else "м/с"
		))
		v.add_child(_pv_row(
			"Цель",
			"%.2f" % float(detail.get("target_position_m", 0.0)),
			"рад" if angular else "м"
		))
		v.add_child(_pv_row(
			"Питание", "%.0f" % float(detail.get("power_draw_w", 0.0)), "Вт"
		))
		v.add_child(_pv_row(
			"Мотор",
			"вкл" if bool(detail.get("enabled", true)) else "выкл",
			""
		))
		var trow := _hbox(10)
		trow.custom_minimum_size = Vector2(0, 30)
		var k := _lbl("Угол" if angular else "Ход", DIM, 13)
		k.custom_minimum_size = Vector2(96, 0)
		trow.add_child(k)
		trow.add_child(_sparkline())
		trow.add_child(_lbl(_node_value_text(node), TXT, 15))
		v.add_child(trow)
		return v
	v.add_child(_pv_row("Значение", _node_value_text(node), ""))
	return v


func _fp_setpoints(kind: String, detail: Dictionary) -> Control:
	var ids: Array = SETPOINTS.get(kind, [])
	if kind != "wheel" and ids.is_empty():
		return null
	var v := _vbox(9)
	if kind == "wheel":
		v.add_child(_sw_row(
			"Поворотное",
			bool(detail.get("steerable", false)),
			"Да",
			"Нет",
			"wheel.steerable_toggle"
		))
		v.add_child(_sw_row(
			"Направление",
			bool(detail.get("drive_inverted", false)),
			"Назад",
			"Вперёд",
			"wheel.invert_drive_toggle"
		))
	for param_variant: Variant in ids:
		var row := _sp_row_from(str(param_variant), detail)
		if row != null:
			v.add_child(row)
	return v


## Строка параметра из ParameterCatalog: живое значение из detail, шаг/подпись/
## единица/точность — из баланса, положение ползунка — по soft-диапазону.
func _sp_row_from(param_id: String, detail: Dictionary) -> Control:
	var entry := GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return null
	var field := str(entry.get("field", ""))
	var raw := float(detail.get(field, 0.0))
	var scale := float(entry.get("display_scale", 1.0))
	var bounds := _effective_bounds(param_id, detail, entry)
	var lo := bounds.x
	var hi := bounds.y
	var ratio := 0.0
	if hi - lo > 0.000001:
		ratio = clampf((raw - lo) / (hi - lo), 0.0, 1.0)
	var precision := int(entry.get("precision", 2))
	var label := str(entry.get("label", param_id))
	var unit := str(entry.get("unit", ""))
	var step := float(entry.get("step", 0.0))
	var node := _selected_node()
	var shown := String.num(raw * scale, precision)

	var base := {
		"kind": "control_param",
		"param_id": param_id,
		"node_kind": str(node.get("kind", "other")),
		"element_id": int(node.get("element_id", 0)),
		"joint_id": int(node.get("joint_id", 0)),
		"node_name": _node_name(node),
		"node_tag": _node_tag(node),
	}
	var payload_set := base.duplicate()
	payload_set["action_id"] = "param.set"
	payload_set["value"] = raw
	payload_set["glyph"] = "equal"
	payload_set["label"] = "%s %s %s" % [label, shown, unit]
	var payload_inc := base.duplicate()
	payload_inc["action_id"] = "param.increase"
	payload_inc["delta"] = step
	payload_inc["glyph"] = "plus"
	payload_inc["label"] = "%s +%s" % [label, String.num(step * scale, precision)]
	var payload_dec := base.duplicate()
	payload_dec["action_id"] = "param.decrease"
	payload_dec["delta"] = step
	payload_dec["glyph"] = "minus"
	payload_dec["label"] = "%s −%s" % [label, String.num(step * scale, precision)]

	return _sp_row(label, ratio, shown, unit, false, {
		"set": payload_set,
		"inc": payload_inc,
		"dec": payload_dec,
	}, param_id)


## Булев параметр (поворотность, направление): двухсегментный тумблер вместо
## ползунка — это не число, шаг к нему неприменим.
func _sw_row(
	label: String,
	is_on: bool,
	on_text: String,
	off_text: String,
	action_id: String = ""
) -> Control:
	var node := _selected_node()
	var h := _hbox(9)
	var grip := _drag_panel(Color(0, 0, 0, 0), 0, 0, 0, 0, LINE2, {} if action_id.is_empty() else {
		"kind": "control_action",
		"action_id": action_id,
		"glyph": "sliders" if action_id.ends_with("steerable_toggle") else "reverse",
		"label": label,
		"node_kind": str(node.get("kind", "other")),
		"element_id": int(node.get("element_id", 0)),
		"joint_id": int(node.get("joint_id", 0)),
		"node_name": _node_name(node),
		"node_tag": _node_tag(node),
	})
	grip.add_child(_icon("grip", FAINT, 13))
	h.add_child(grip)
	var kl := _lbl(label, DIM, 13)
	kl.custom_minimum_size = Vector2(90, 0)
	h.add_child(kl)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	var box := _panel(Color(0, 0, 0, 0), 1, 1, 1, 1, LINE2)
	var seg := _hbox(0)
	var off_seg := _panel(
		Color(0, 0, 0, 0) if is_on else DARKCHIP, 0, 0, 1, 0, LINE2
	)
	off_seg.add_child(_pad(_lbl(
		off_text, DIM if is_on else Color(0.929, 0.937, 0.945), 11
	), 10, 3, 10, 3))
	seg.add_child(off_seg)
	var on_seg := _panel(DARKCHIP if is_on else Color(0, 0, 0, 0))
	on_seg.add_child(_pad(_lbl(
		on_text, Color(0.929, 0.937, 0.945) if is_on else DIM, 11
	), 10, 3, 10, 3))
	seg.add_child(on_seg)
	box.add_child(seg)
	if not action_id.is_empty():
		box.mouse_filter = Control.MOUSE_FILTER_STOP
		box.gui_input.connect(_on_click.bind(_run_action.bind({
			"action_id": action_id,
			"element_id": int(node.get("element_id", 0)),
			"joint_id": int(node.get("joint_id", 0)),
			"node_kind": str(node.get("kind", "other")),
		}, true)))
	h.add_child(box)
	return h


func _fp_commands(kind: String) -> Control:
	var rows: Array = COMMANDS.get(kind, [])
	if rows.is_empty():
		return null
	var node := _selected_node()
	var h := HFlowContainer.new()
	h.add_theme_constant_override("h_separation", 7)
	h.add_theme_constant_override("v_separation", 7)
	for row_variant: Variant in rows:
		var row: Array = row_variant
		h.add_child(_cmd(str(row[1]), str(row[2]), str(row[3]), {
			"kind": "control_action",
			"action_id": str(row[0]),
			"glyph": str(row[1]),
			"label": str(row[2]),
			"input_kind": str(row[3]),
			"node_kind": kind,
			"element_id": int(node.get("element_id", 0)),
			"joint_id": int(node.get("joint_id", 0)),
			"node_name": _node_name(node),
			"node_tag": _node_tag(node),
		}))
	return h


## Пока автоматической половины Binding нет (Control Graph), «Авто» — не
## переключатель, а честно погашенная позиция: врать активной кнопкой нельзя.
func _mode_toggle() -> Control:
	var box := _panel(Color(0, 0, 0, 0), 1, 1, 1, 1, LINE2)
	box.tooltip_text = "Автоматика появится вместе со схемой управления"
	var h := _hbox(0)
	var a := _panel(Color(0, 0, 0, 0), 0, 0, 1, 0, LINE2)
	a.add_child(_pad(_lbl("Авто", FAINT, 11), 10, 3, 10, 3))
	h.add_child(a)
	var m := _panel(DARKCHIP)
	m.add_child(_pad(_lbl("Ручн", Color(0.929, 0.937, 0.945), 11), 10, 3, 10, 3))
	h.add_child(m)
	box.add_child(h)
	return box


func _fp_section(title: String, content: Control) -> Control:
	var wrap := _panel(PANEL, 0, 0, 0, 1)
	var v := _vbox(9)
	v.add_child(_lbl(title, TXT2, 11))
	v.add_child(content)
	wrap.add_child(_pad(v, 14, 11, 14, 11))
	return wrap


func _pv_row(k: String, val: String, unit: String) -> Control:
	var wrap := _panel(PANEL, 0, 0, 0, 1)
	var h := _hbox(0)
	var kl := _lbl(k, DIM, 13)
	kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(kl)
	h.add_child(_lbl(val, TXT, 13, HORIZONTAL_ALIGNMENT_RIGHT))
	var ul := _lbl("  " + unit, DIM, 11)
	ul.custom_minimum_size = Vector2(40, 0)
	h.add_child(ul)
	wrap.add_child(_pad(h, 0, 4, 0, 4))
	return wrap


func _sparkline() -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(150, 26)
	var line := Line2D.new()
	line.width = 1.2
	line.default_color = Color(0.337, 0.376, 0.412)
	line.points = PackedVector2Array([
		Vector2(0, 22), Vector2(18, 21), Vector2(34, 18), Vector2(52, 17),
		Vector2(70, 13), Vector2(88, 12), Vector2(104, 9), Vector2(120, 8),
		Vector2(136, 6), Vector2(150, 6),
	])
	box.add_child(line)
	var base := Line2D.new()
	base.width = 1.0
	base.default_color = LINE
	base.points = PackedVector2Array([Vector2(0, 25), Vector2(150, 25)])
	box.add_child(base)
	return box


func _sp_row(
	k: String,
	ratio: float,
	val: String,
	unit: String,
	focus: bool,
	payloads: Dictionary = {},
	param_id: String = ""
) -> Control:
	var h := _hbox(9)
	h.add_child(_icon("grip", FAINT, 13))
	var kl := _lbl(k, DIM, 13)
	kl.custom_minimum_size = Vector2(90, 0)
	h.add_child(kl)
	h.add_child(_slider(ratio, param_id))
	h.add_child(_edit_field(val, unit, focus, payloads, param_id))
	return h


## Живой трек: клик/протяг по нему пишет абсолютное значение через
## `_apply_slider_ratio` (см. класс SliderTrack). Дочерние Panel — только
## отрисовка, поэтому все — MOUSE_FILTER_IGNORE, иначе они бы сами глотали
## клик поверх трека и он бы никогда не доходил до `_gui_input`.
func _slider(ratio: float, param_id: String = "") -> Control:
	var box := SliderTrack.new()
	box.terminal = self
	box.param_id = param_id
	box.custom_minimum_size = Vector2(0, 16)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	if not param_id.is_empty():
		box.mouse_default_cursor_shape = Control.CURSOR_HSPLIT

	var track := Panel.new()
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_theme_stylebox_override("panel", _sbox(LINE))
	track.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	track.anchor_right = 1.0
	track.offset_left = 0
	track.offset_right = 0
	track.offset_top = -1
	track.offset_bottom = 2
	box.add_child(track)

	var fill := Panel.new()
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.add_theme_stylebox_override("panel", _sbox(TXT2))
	fill.anchor_left = 0.0
	fill.anchor_right = ratio
	fill.anchor_top = 0.5
	fill.anchor_bottom = 0.5
	fill.offset_top = -1
	fill.offset_bottom = 2
	box.add_child(fill)

	var knob := Panel.new()
	knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	knob.add_theme_stylebox_override("panel", _sbox(TXT))
	knob.anchor_left = ratio
	knob.anchor_right = ratio
	knob.anchor_top = 0.5
	knob.anchor_bottom = 0.5
	knob.offset_left = -4
	knob.offset_right = 5
	knob.offset_top = -4
	knob.offset_bottom = 5
	box.add_child(knob)

	if not param_id.is_empty():
		_slider_rows[param_id] = {"fill": fill, "knob": knob}
	return box


## Ратио → значение → команда, вызывается на каждое движение SliderTrack (не
## только на отпускание) — шкала обязана ехать вместе с курсором, как у
## настоящего прибора. Значение и подпись поля обновляются тут же, без
## ожидания следующего тика снапшота (тот всё равно подавлен, см. _refresh).
func _apply_slider_ratio(param_id: String, ratio: float) -> void:
	_slider_drag_active = true
	var entry := GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return
	var node := _selected_node()
	var detail: Dictionary = node.get("detail", {})
	var bounds := _effective_bounds(param_id, detail, entry)
	var value := lerpf(bounds.x, bounds.y, ratio)
	_submit_param(
		param_id, value, int(node.get("element_id", 0)), int(node.get("joint_id", 0))
	)
	var row: Dictionary = _slider_rows.get(param_id, {})
	if row.is_empty():
		return
	var fill: Panel = row.get("fill")
	if fill != null:
		fill.anchor_right = ratio
	var knob: Panel = row.get("knob")
	if knob != null:
		knob.anchor_left = ratio
		knob.anchor_right = ratio
	var value_label: Label = row.get("value")
	if value_label != null:
		value_label.text = String.num(
			value * float(entry.get("display_scale", 1.0)),
			int(entry.get("precision", 2))
		)


func _end_slider_drag() -> void:
	_slider_drag_active = false


## Более тёплый оттенок в сторону цвета выделения — единственный сигнал
## «сюда можно бросить» теперь, когда клик по этим панелям больше не стреляет
## командой напрямую (см. _on_click).
func _hover_bg(base: Color) -> Color:
	return base.lerp(SEL, 0.6)


## PanelContainer, который можно утащить на клавишу пульта.
func _drag_panel(
	bg: Color,
	bl: int,
	bt: int,
	br: int,
	bb: int,
	bc: Color,
	payload: Dictionary
) -> DragSource:
	var p := DragSource.new()
	p.payload = payload
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_hover_style(
		_sbox(bg, bl, bt, br, bb, bc),
		_sbox(_hover_bg(bg), bl, bt, br, bb, bc)
	)
	return p


## Поле параметра — три независимых drag-источника: «−шаг», «установить текущее»,
## «+шаг». Так игрок тащит на клавишу ровно тот вариант, который хочет, без
## всплывающего выбора после броска.
func _edit_field(
	val: String,
	unit: String,
	focus: bool,
	payloads: Dictionary = {},
	param_id: String = ""
) -> Control:
	var box := _panel(Color(0, 0, 0, 0), 1, 1, 1, 1, TXT2 if focus else LINE2)
	var h := _hbox(0)
	var minus := _drag_panel(FLD, 0, 0, 1, 0, LINE2, payloads.get("dec", {}))
	minus.add_child(_pad(_lbl("−", DIM, 14), 6, 1, 6, 1))
	if not param_id.is_empty():
		minus.gui_input.connect(
			_on_click.bind(_apply_param_step.bind(param_id, -1))
		)
	h.add_child(minus)
	var fld := _drag_panel(FLD, 0, 0, 0, 0, LINE2, payloads.get("set", {}))
	fld.custom_minimum_size = Vector2(62, 0)
	var fh := _hbox(4)
	var vl := _lbl(val, TXT, 12, HORIZONTAL_ALIGNMENT_RIGHT)
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fh.add_child(vl)
	fh.add_child(_lbl(unit, FAINT, 10))
	fld.add_child(_pad(fh, 8, 2, 8, 2))
	h.add_child(fld)
	var plus := _drag_panel(FLD, 1, 0, 0, 0, LINE2, payloads.get("inc", {}))
	plus.add_child(_pad(_lbl("+", DIM, 14), 6, 1, 6, 1))
	if not param_id.is_empty():
		plus.gui_input.connect(
			_on_click.bind(_apply_param_step.bind(param_id, 1))
		)
	h.add_child(plus)
	box.add_child(h)
	if not param_id.is_empty():
		if not _slider_rows.has(param_id):
			_slider_rows[param_id] = {}
		_slider_rows[param_id]["value"] = vl
	return box


## Чистый drag-источник — эта кнопка НЕ исполняется кликом (глагол пробуется
## только через слот пульта, куда её перетащили). Клик-и-старт-жеста иначе
## конфликтует с началом перетаскивания: нажатие уходило бы в исполнение
## раньше, чем Godot успеет понять, что это drag. Подсветка при наведении —
## единственный сигнал «это можно перетащить».
func _cmd(glyph: String, text: String, kind: String, payload: Dictionary = {}) -> Control:
	var normal := StyleBoxFlat.new()
	normal.anti_aliasing = false
	normal.bg_color = CELL
	normal.border_color = LINE2
	normal.set_border_width_all(1)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = _hover_bg(CELL)
	var box := DragSource.new()
	box.payload = payload
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.custom_minimum_size = Vector2(0, 34)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.set_hover_style(normal, hover)
	var h := _hbox(7)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(_icon(glyph, TXT2, 15))
	h.add_child(_lbl(text, TXT, 13))
	var tag := _panel(Color(0, 0, 0, 0), 1, 1, 1, 1, LINE2)
	tag.add_child(_pad(_lbl(kind, DIM, 9), 3, 1, 3, 1))
	h.add_child(tag)
	box.add_child(h)
	return box


# ---------- right: alarms ----------

func _build_alarms() -> Control:
	var v := _vbox(0)

	var head := _panel(HEAD, 0, 0, 0, 1)
	var hh := _hbox(0)
	var title := _lbl("АВАРИИ", TXT2, 11)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(title)
	_alarms_count = _lbl("—", DIM, 11)
	hh.add_child(_alarms_count)
	head.add_child(_pad(hh, 12, 7, 12, 7))
	v.add_child(head)

	_alarm_box = _vbox(0)
	_alarm_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_scroll(_alarm_box))
	_fill_alarms(_mock_alarms())

	v.add_child(_sechead("ГРУППЫ", ""))
	var e := _panel(PANEL)
	e.add_child(_pad(_lbl("Группа из выделенных — скоро", FAINT, 11), 12, 14, 12, 14))
	v.add_child(e)
	return v


static func _mock_alarms() -> Array:
	var alarms: Array = []
	for node_variant: Variant in _mock_nodes():
		var node: Dictionary = node_variant
		if str(node.get("severity", "ok")) != "ok":
			alarms.append(node)
	return alarms


## Заполнение ленты аварий. Порядок задаёт билдер (отказы вперёд).
func _fill_alarms(alarms: Array) -> void:
	if _alarm_box == null:
		return
	for child: Node in _alarm_box.get_children():
		_alarm_box.remove_child(child)
		child.queue_free()
	var count := 0
	for alarm_variant: Variant in alarms:
		if not alarm_variant is Dictionary:
			continue
		var alarm: Dictionary = alarm_variant
		var severity := str(alarm.get("severity", "warn"))
		_alarm_box.add_child(_alarm_row(
			_node_name(alarm),
			_node_tag(alarm),
			HudTokens.status_label(StringName(alarm.get("status", &"ok"))).to_lower(),
			"",
			_severity_color(severity),
			int(alarm.get("element_id", 0))
		))
		count += 1
	if _alarms_count != null:
		_alarms_count.text = "%d актив." % count
	if _alarms_head != null:
		_alarms_head.text = str(count)
		_alarms_head.add_theme_color_override(
			"font_color",
			AMBER if count > 0 else DIM
		)


func _sechead(title: String, right: String) -> Control:
	var wrap := _panel(HEAD, 0, 0, 0, 1)
	var h := _hbox(0)
	var t := _lbl(title, TXT2, 11)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	if right != "":
		h.add_child(_lbl(right, DIM, 11))
	wrap.add_child(_pad(h, 12, 7, 12, 7))
	return wrap


## Строка аварии — кратчайший путь к отказавшему узлу: клик открывает его
## фейсплейт, не заставляя искать его же в списке слева.
func _alarm_row(
	name: String,
	tag: String,
	desc: String,
	time: String,
	col: Color,
	element_id := 0
) -> Control:
	var wrap := _panel(PANEL, 0, 0, 0, 1)
	if element_id > 0:
		wrap.mouse_filter = Control.MOUSE_FILTER_STOP
		wrap.gui_input.connect(_on_click.bind(select_element.bind(element_id)))
	var h := _hbox(8)
	var mk := Panel.new()
	mk.add_theme_stylebox_override("panel", _sbox(col))
	mk.custom_minimum_size = Vector2(8, 8)
	mk.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(mk)
	var col_v := _vbox(2)
	var top := _hbox(6)
	top.add_child(_lbl(name, col, 12))
	top.add_child(_lbl(tag, DIM, 10))
	col_v.add_child(top)
	col_v.add_child(_lbl(desc, TXT2, 11))
	if not time.is_empty():
		col_v.add_child(_lbl(time, DIM, 10))
	h.add_child(col_v)
	wrap.add_child(_pad(h, 10, 7, 10, 7))
	return wrap


# ---------- bottom: soft keys ----------

func _build_softbar() -> Control:
	var wrap := _panel(HEAD, 0, 1, 0, 0, LINE2)
	var v := _vbox(0)

	var sh := _hbox(12)
	sh.add_child(_lbl("ПУЛЬТ ДЕЙСТВИЙ", TXT2, 11))
	_page_row = _hbox(4)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.add_child(sp)
	sh.add_child(_page_row)
	var shwrap := _panel(HEAD, 0, 0, 0, 1)
	shwrap.add_child(_pad(sh, 12, 6, 12, 6))
	v.add_child(shwrap)
	_fill_pages()

	_strip = _hbox(0)
	_fill_slots()
	v.add_child(_strip)
	wrap.add_child(v)
	return wrap


func _fill_pages() -> void:
	if _page_row == null:
		return
	for child: Node in _page_row.get_children():
		_page_row.remove_child(child)
		child.queue_free()
	for i in range(PAGE_COUNT):
		_page_row.add_child(_page_btn(i))


func _page_btn(index: int) -> Control:
	var on := index == _page
	var b := _panel(DARKCHIP if on else Color(0, 0, 0, 0), 1, 1, 1, 1, LINE2)
	b.custom_minimum_size = Vector2(20, 18)
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.gui_input.connect(_on_click.bind(_set_page.bind(index)))
	# Занятая страница читается тёмным номером: иначе понять, где что лежит,
	# можно только пролистав все девять.
	var c := Color(0.929, 0.937, 0.945) if on else (
		TXT2 if _page_has_bindings(index) else DIM
	)
	b.add_child(_lbl(str(index + 1), c, 11, HORIZONTAL_ALIGNMENT_CENTER))
	return b


## Листание страниц по кругу — как в строительном тулбаре.
func _set_page(index: int) -> void:
	var next := wrapi(index, 0, PAGE_COUNT)
	if next == _page:
		return
	_release_holds()
	_page = next
	if _open:
		_fill_pages()
		_fill_slots()


func _page_slots(page := -1) -> Array:
	var page_index := _page if page < 0 else wrapi(page, 0, PAGE_COUNT)
	if page_index >= 0 and page_index < _bar_pages.size():
		return _bar_pages[page_index]
	return [{}, {}, {}, {}, {}, {}, {}, {}, {}]


func _page_has_bindings(page: int) -> bool:
	for slot_variant: Variant in _page_slots(page):
		if not (slot_variant as Dictionary).is_empty():
			return true
	return false


## Перерисовка полосы пульта из модели слотов.
func _fill_slots() -> void:
	if _strip == null:
		return
	for child: Node in _strip.get_children():
		_strip.remove_child(child)
		child.queue_free()
	var slots := _page_slots()
	for i in range(slots.size()):
		var key := _soft_key(i, slots[i])
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_strip.add_child(key)
		if i < slots.size() - 1:
			_strip.add_child(_vrule())


## Привязка брошенной команды/параметра к клавише — идёт командой в
## симуляцию (`configure_action_slot`), не мутирует бар напрямую: бар —
## авторитетное состояние хоста, не локальный UI-стейт (CONTROL-ACTIONS-V0
## «Persistence и кооп»). Слот на экране обновится из следующего снапшота
## (до ~100 мс), тот же принцип, что и у остальных команд пульта.
func bind_slot(index: int, payload: Dictionary) -> void:
	if index < 0 or index >= SLOTS_PER_PAGE or payload.is_empty():
		return
	_submit_action_slot(index, payload)


func clear_slot(index: int) -> void:
	if index < 0 or index >= SLOTS_PER_PAGE:
		return
	_submit_action_slot(index, {})


## Пустой payload = снять клавишу (тот же приём, что пустое имя в
## SetElementNameCommand сбрасывает custom_name).
func _submit_action_slot(index: int, payload: Dictionary) -> void:
	if _gateway == null or not _gateway.has_method("submit"):
		# Изолированная сцена вёрстки (scenes/ui/test_control_terminal.tscn) —
		# гейтвея нет, но бар обязан оставаться кликабельным для проверки
		# вёрстки. _page_slots() без гейтвея возвращает новый пустой Array на
		# каждый вызов (_bar_pages никогда не заполняется), поэтому мутировать
		# нужно ЕГО ЖЕ элемент _bar_pages напрямую, а не то, что вернул
		# _page_slots() — иначе правка тут же теряется.
		_ensure_local_bar_pages()
		var page_index := wrapi(_page, 0, PAGE_COUNT)
		if index >= 0 and index < SLOTS_PER_PAGE and page_index < _bar_pages.size():
			_bar_pages[page_index][index] = payload.duplicate(true)
			_fill_slots()
			_fill_pages()
		return
	if _host_element_id <= 0:
		return
	var command_id: int = _gateway.call("submit", {
		"kind": &"configure_action_slot",
		# Источник — игрок, не панель: гейтвей сверяет его с текущим occupant
		# хоста (единственная команда пульта, для которой это важно).
		"source": _player,
		"target": {
			"valid": true,
			"target_kind": &"element",
			"metadata": {"element_id": _host_element_id},
		},
		"parameters": {
			"host_element_id": _host_element_id,
			"page": _page,
			"index": index,
			"payload": payload,
		},
	})
	# Без этого отказ (occupant не тот / хост неполный) молчал бы — статус-бар
	# получает reason только для команд, зарегистрированных здесь.
	_pending_commands[command_id] = true


## Только для фолбэка без гейтвея (см. _submit_action_slot) — держит
## _bar_pages настоящим 9×9-массивом, чтобы мутация клавиши не терялась.
func _ensure_local_bar_pages() -> void:
	if _bar_pages.size() != PAGE_COUNT:
		_bar_pages = _empty_bar_pages()


## Клавиша пульта → глагол. Пустой слот молчит. `source` различает удержание
## хоткея и удержание мышью: снимаются они по разным признакам.
func _fire_slot(index: int, pressed: bool, source := "") -> void:
	if index < 0 or index >= SLOTS_PER_PAGE:
		return
	var slot: Dictionary = _page_slots()[index]
	if slot.is_empty():
		return
	var hold_source := source if not source.is_empty() else "slot:%d" % index
	if pressed:
		_begin_hold(hold_source, slot)
	else:
		_held.erase(hold_source)
	_run_action(slot, pressed)


func _soft_key(index: int, slot: Dictionary) -> Control:
	var empty := slot.is_empty()
	var box := DropKey.new()
	box.terminal = self
	box.slot_index = index
	box.add_theme_stylebox_override("panel", _sbox(
		PANEL,
		0, 0, 0, 0,
		LINE
	))
	box.custom_minimum_size = Vector2(0, 56)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.tooltip_text = (
		"Перетащи сюда команду или параметр"
		if empty
		else "%s · %s\nЛКМ или клавиша %d — выполнить, ПКМ — снять" % [
			str(slot.get("label", "")), str(slot.get("node_name", "")), index + 1
		]
	)
	box.gui_input.connect(_on_slot_input.bind(index))

	var v := _vbox(0)
	var top := _hbox(0)
	top.add_child(_lbl(str(index + 1), DIM, 11))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	if not empty:
		top.add_child(_icon(str(slot.get("glyph", "")), DIM, 14))
	v.add_child(top)
	var sp2 := Control.new()
	sp2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sp2)
	v.add_child(_lbl(
		"—" if empty else str(slot.get("label", "")),
		FAINT if empty else TXT,
		12
	))
	v.add_child(_lbl(
		"свободно" if empty else str(slot.get("node_tag", "")),
		FAINT if empty else DIM,
		10
	))
	box.add_child(_pad(v, 10, 8, 10, 8))
	return box


func _on_slot_input(event: InputEvent, index: int) -> void:
	if not event is InputEventMouseButton:
		return
	var mouse := event as InputEventMouseButton
	if mouse.button_index == MOUSE_BUTTON_RIGHT and mouse.pressed:
		clear_slot(index)
		return
	if mouse.button_index == MOUSE_BUTTON_LEFT:
		_fire_slot(index, mouse.pressed, "mouse")


# ---------- bottom: status bar ----------

func _build_statusbar() -> Control:
	var wrap := _panel(HEAD, 0, 1, 0, 0, LINE2)
	var h := _hbox(0)
	h.add_child(_status_cell("Оператор", "", true))
	h.add_child(_status_cell("Режим: ", "Ручн", true))
	h.add_child(_status_cell("Связь: ", "ОК", true))
	var fault_wrap := _panel(Color(0, 0, 0, 0), 0, 0, 1, 0)
	_fault_cell = _lbl("", RED, 11)
	_fault_cell.visible = false
	fault_wrap.add_child(_pad(_fault_cell, 12, 5, 12, 5))
	h.add_child(fault_wrap)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	h.add_child(_status_cell("ЛКМ выбрать · ПКМ снять клавишу", "", true))
	h.add_child(_status_cell("перетащи команду на клавишу", "", true))
	h.add_child(_status_cell("1–9 клавиша · [ ] стр.", "", true))
	h.add_child(_status_cell("K / Esc закрыть", "", false))
	wrap.add_child(h)
	return wrap


func _status_cell(text: String, strong: String, border: bool) -> Control:
	var wrap := _panel(Color(0, 0, 0, 0), 0, 0, (1 if border else 0), 0)
	var h := _hbox(0)
	h.add_child(_lbl(text, DIM, 11))
	if strong != "":
		h.add_child(_lbl(strong, TXT2, 11))
	wrap.add_child(_pad(h, 12, 5, 12, 5))
	return wrap
