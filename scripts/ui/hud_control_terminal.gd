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

	## Хост-пульт: нужен, чтобы на press выставить `_faceplate_press_active`.
	var terminal: Node = null
	## Если задан — короткий клик (DnD не стартовал) вызывает его на отпускании.
	## ± уставок: они же DragSource на клавишу. Чипы «КОМАНДЫ» не ставят.
	var click_action: Callable = Callable()
	var _drag_emitted: bool = false

	func _gui_input(event: InputEvent) -> void:
		if not event is InputEventMouseButton:
			return
		var mouse: InputEventMouseButton = event
		if mouse.button_index != MOUSE_BUTTON_LEFT:
			return
		if mouse.pressed:
			_drag_emitted = false
			if click_action.is_valid() and terminal != null:
				terminal.set("_faceplate_press_active", true)
		elif click_action.is_valid() and not _drag_emitted:
			# DnD не стартовал → это клик (порог DnD у viewport выше).
			if terminal != null:
				terminal.set("_faceplate_press_active", false)
			click_action.call()

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if payload.is_empty():
			return null
		# Уже ушли в DnD — клик на отпускании не стреляем; снимаем press-guard.
		_drag_emitted = true
		if terminal != null:
			terminal.set("_faceplate_press_active", false)
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
## Pin explicit ControlSeat host while the terminal is open — look-away must
## not resolve host to 0 or silently switch seats (no lowest-seat fallback).
var _pinned_host_element_id := 0
var _page := 0
var _strip: HBoxContainer
var _page_row: HBoxContainer
var _gateway: Node
var _query: Node
var _player: Node
var _open := false

## Таймеры/частота refresh — TerminalSnapshotController (REFRESH_S / FULL_AUDIT_S).
var _refresh_left := 0.0
var _full_audit_left := 0.0
## Dirty-signature: не пересобирать список/аварии и не гонять полный snap зря.
var _last_structure_key := ""
var _last_structure_sig := ""
var _last_live_sig := ""
var _last_bar_sig := ""
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
## Пока ЛКМ зажата на кликабельном контроле фейсплейта/фильтров (`_on_click`),
## live-пересборка фейсплейта паузится — иначе 10 Гц `_fill_faceplate` убивает
## нажатый узел до отпускания, и «огонь на release» никогда не срабатывает.
var _faceplate_press_active := false
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
	"wheel": [
		"wheel.drive_torque",
		"wheel.brake_torque",
		"wheel.grip",
		"wheel.steering_angle",
	],
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
	"control_seat": [
		["seat.control_wheels_toggle", "sliders", "Колёса", "тумб"],
		["seat.control_thrusters_toggle", "power", "Тяга", "тумб"],
		["seat.control_gyros_toggle", "rotate_cw", "Гиро", "тумб"],
	],
	"oxygen_module": [
		["machine.toggle", "power", "Питание", "тумб"],
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
	elif controls_permitted():
		open()


## Точка входа из ToolController (`E` в interaction-range архетипа
## `control_terminal`) — тот же контракт `try_open_on_target`, что у
## actuator/wheel/industry-панелей. Архетип несёт роль `ControlSeat`, поэтому
## перехватывается ДО того, как интеракт успеет собраться в `toggle_control_seat`
## и попытаться посадить игрока в стационарную консоль (CONTROL-ACTIONS-V0
## «Хосты бара»).
const INTERACT_RANGE_M := 4.0


## K-пульт / компактная лента: пешком и водитель — да; пассажирское кресло —
## жёсткий запрет (co-pilot permissions позже). Читает gateway seat id /
## `is_local_seat_driver()`, без своего состояния посадки.
func controls_permitted() -> bool:
	if _gateway == null or not _gateway.has_method("get_local_seat_element_id"):
		return true
	if int(_gateway.call("get_local_seat_element_id")) <= 0:
		return true
	return (
		_gateway.has_method("is_local_seat_driver")
		and bool(_gateway.call("is_local_seat_driver"))
	)


func try_open_on_target(hit: InteractionHit) -> bool:
	if (
		hit == null
		or not hit.valid
		or hit.distance > INTERACT_RANGE_M
		or not controls_permitted()
		or str(hit.card_keys(_gateway.get_world()).get("archetype_id", "")) != "control_terminal"
	):
		return false
	# Pin the aimed ControlSeat before open so refresh can't lose it.
	_pinned_host_element_id = hit.element_id
	open()
	return true


func open() -> void:
	if _open:
		return
	if not controls_permitted():
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
	_full_audit_left = 0.0
	_last_structure_key = ""
	_last_structure_sig = ""
	_last_live_sig = ""
	_apply_open_state()
	_refresh()


func close() -> void:
	if not _open:
		return
	_open = false
	_pinned_host_element_id = 0
	_release_holds()
	_last_structure_key = ""
	_last_structure_sig = ""
	_last_live_sig = ""
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
	if _open and not controls_permitted():
		close()
		return
	# Бар обновляется, пока водитель сидит, даже если окно закрыто — компактная
	# лента (hud_compact_action_bar.gd) переиспользует именно этот бар и эту
	# же _fire_slot, а не дублирует резолв цели и исполнение глаголов.
	# Пассажир — без ленты и без фонового резолва. Список узлов/фейсплейт/
	# аварии — тяжелее и нужны только открытому окну.
	var seated_driver := (
		_player != null
		and _player.has_method("is_in_vehicle")
		and bool(_player.call("is_in_vehicle"))
		and controls_permitted()
	)
	if not _open and not seated_driver:
		return
	if _open and _fault_left > 0.0:
		_fault_left = maxf(_fault_left - delta, 0.0)
		if _fault_left <= 0.0:
			_fault_text = ""
			_update_fault_cell()
	TerminalSnapshotController.advance_and_refresh(self, delta)


## Живые данные: сидя — своя сборка, иначе — сборка наведённого элемента.
## Без гейтвея (изолированная сцена вёрстки) остаются mock-данные.
func _refresh() -> void:
	TerminalSnapshotController.refresh(self)

func _snapshot_host_hint() -> int:
	return TerminalSnapshotController.snapshot_host_hint(self)

func _refresh_bar_closed() -> void:
	TerminalSnapshotController.refresh_bar_closed(self)

func _refresh_open() -> void:
	TerminalSnapshotController.refresh_open(self)

func _refresh_open_live_only(world: SimulationWorld, assembly_id: int) -> void:
	TerminalSnapshotController.refresh_open_live_only(self, world, assembly_id)

func _open_structure_key(world: SimulationWorld, assembly_id: int) -> String:
	return TerminalSnapshotController.open_structure_key(self, world, assembly_id)

func _assembly_id_from_aim() -> int:
	return TerminalSnapshotController.assembly_id_from_aim(self)

func _structure_sig_from_lists(nodes: Array, alarms: Array) -> String:
	return TerminalSnapshotController.structure_sig_from_lists(nodes, alarms)

func _live_sig_from_snap(snap: Dictionary, nodes: Array) -> String:
	return TerminalSnapshotController.live_sig_from_snap(self, snap, nodes)

func _live_sig_from_node(node: Dictionary, power: Dictionary) -> String:
	return TerminalSnapshotController.live_sig_from_node(self, node, power)

func _patch_selected_node_live(world: SimulationWorld) -> bool:
	return TerminalSnapshotController.patch_selected_node_live(self, world)

func active_page_slots() -> Array:
	return _page_slots()


func active_page_number() -> int:
	return _page


func fire_slot(index: int, pressed: bool, source := "") -> void:
	if not controls_permitted():
		return
	_fire_slot(index, pressed, source)


func set_active_page(index: int) -> void:
	if not controls_permitted():
		return
	_set_page(index)


func _apply_bar_snapshot(host_element_id: int, pages: Array) -> void:
	TerminalActionBar.apply_bar_snapshot(self, host_element_id, pages)


func _empty_bar_pages() -> Array:
	return TerminalActionBar.empty_bar_pages(self)


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
	_last_structure_key = ""
	_last_structure_sig = ""
	_last_live_sig = ""
	_full_audit_left = 0.0
	_fill_pages()
	_fill_slots()


func _aimed_element_id() -> int:
	if _query == null:
		return 0
	var hit: InteractionHit = _query.current_hit
	if hit == null or not hit.valid:
		return 0
	return hit.element_id


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
##
## Нажатие ставит `_faceplate_press_active`: live-refresh не должен
## `queue_free` нажатый контрол до отпускания (см. TerminalSnapshotController.refresh).
func _on_click(event: InputEvent, action: Callable) -> void:
	if not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		_faceplate_press_active = true
		return
	_faceplate_press_active = false
	action.call()


## Единственная точка отправки параметра в симуляцию: её используют и клик по ±,
## и слот `param.*`, и будущий ввод числа с клавиатуры.
func _submit(command_kind: String, element_id: int, params: Dictionary) -> void:
	TerminalCommandExecutor.submit(self, command_kind, element_id, params)


func _on_command_completed(command_id: int, result: Dictionary) -> void:
	TerminalCommandExecutor.on_command_completed(self, command_id, result)


func _update_fault_cell() -> void:
	TerminalCommandExecutor.update_fault_cell(self)


func _submit_param(
	param_id: String,
	value: float,
	element_id: int,
	joint_id: int
) -> void:
	TerminalCommandExecutor.submit_param(self, param_id, value, element_id, joint_id)


func _effective_bounds(param_id: String, detail: Dictionary, entry: Dictionary) -> Vector2:
	return TerminalCommandExecutor.effective_bounds(param_id, detail, entry)


func _apply_param_step(param_id: String, direction: int) -> void:
	TerminalCommandExecutor.apply_param_step(self, param_id, direction)


func _live_detail(element_id: int, joint_id: int) -> Dictionary:
	return TerminalCommandExecutor.live_detail(self, element_id, joint_id)


func _seat_route_flag(element_id: int, key: String) -> bool:
	return TerminalCommandExecutor.seat_route_flag(self, element_id, key)


func _is_momentary(action_id: String) -> bool:
	return TerminalCommandExecutor.is_momentary(self, action_id)


func _spec_kind(spec: Dictionary) -> String:
	return TerminalCommandExecutor.spec_kind(spec)


func _run_action(spec: Dictionary, pressed: bool) -> void:
	TerminalCommandExecutor.run_action(self, spec, pressed)


func _run_param_action(spec: Dictionary, element_id: int, joint_id: int) -> void:
	TerminalCommandExecutor.run_param_action(self, spec, element_id, joint_id)


func _drive_params(
	spec: Dictionary,
	element_id: int,
	joint_id: int,
	forward: bool
) -> Dictionary:
	return TerminalCommandExecutor.drive_params(self, spec, element_id, joint_id, forward)


func _reverse_params(
	spec: Dictionary,
	element_id: int,
	joint_id: int
) -> Dictionary:
	return TerminalCommandExecutor.reverse_params(self, spec, element_id, joint_id)


func _begin_hold(source: String, spec: Dictionary) -> void:
	TerminalCommandExecutor.begin_hold(self, source, spec)


func _release_stale_holds() -> void:
	TerminalCommandExecutor.release_stale_holds(self)


func _release_holds() -> void:
	TerminalCommandExecutor.release_holds(self)



func _new_drag_source() -> DragSource:
	return DragSource.new()

func _new_slider_track() -> SliderTrack:
	return SliderTrack.new()

func _new_drop_key() -> DropKey:
	return DropKey.new()

func _load_icon_font() -> void:
	TerminalWidgetKit.load_icon_font(self)

func _icon(key: String, col: Color, size := 15) -> Control:
	return TerminalWidgetKit.icon(self, key, col, size)

func _sbox(bg: Color, bl := 0, bt := 0, br := 0, bb := 0, bc := LINE) -> StyleBoxFlat:
	return TerminalWidgetKit.sbox(self, bg, bl, bt, br, bb, bc)

func _panel(bg: Color, bl := 0, bt := 0, br := 0, bb := 0, bc := LINE) -> PanelContainer:
	return TerminalWidgetKit.panel(self, bg, bl, bt, br, bb, bc)

func _lbl(text: String, col: Color, size := 13, halign := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	return TerminalWidgetKit.lbl(self, text, col, size, halign)

func _vbox(sep := 0) -> VBoxContainer:
	return TerminalWidgetKit.vbox(self, sep)

func _hbox(sep := 0) -> HBoxContainer:
	return TerminalWidgetKit.hbox(self, sep)

func _vrule() -> Panel:
	return TerminalWidgetKit.vrule(self)

func _hrule() -> Panel:
	return TerminalWidgetKit.hrule(self)

func _pad(node: Control, l := 0, t := 0, r := 0, b := 0) -> MarginContainer:
	return TerminalWidgetKit.pad(self, node, l, t, r, b)

func _build() -> void:
	TerminalShellBuilder.build(self)


func _build_topbar() -> Control:
	return TerminalShellBuilder.build_topbar(self)


func _fill_unit(snap: Dictionary) -> void:
	TerminalShellBuilder.fill_unit(self, snap)


func _pad_col(node: Control, l: int, t: int, r: int, b: int, _x: int, br_w: int) -> Control:
	return TerminalWidgetKit.pad_col(self, node, l, t, r, b, _x, br_w)

func _kv(k: String, v: String, vcol: Color) -> Control:
	return TerminalWidgetKit.kv(self, k, v, vcol)

func _build_body() -> Control:
	return TerminalShellBuilder.build_body(self)


# ---------- left: equipment ----------

func _build_equipment() -> Control:
	return TerminalEquipmentList.build_equipment(self)

func _fill_filters() -> void:
	TerminalEquipmentList.fill_filters(self)

func _set_filter(id: String) -> void:
	TerminalEquipmentList.set_filter(self, id)

func _build_search() -> Control:
	return TerminalEquipmentList.build_search(self)

func _style_edit(edit: LineEdit) -> void:
	TerminalWidgetKit.style_edit(self, edit)

func _on_search_changed(text: String) -> void:
	TerminalEquipmentList.on_search_changed(self, text)

func _visible_nodes() -> Array:
	return TerminalEquipmentList.visible_nodes(self)

func _scroll(content: Control) -> ScrollContainer:
	return TerminalWidgetKit.scroll(self, content)

func _mock_nodes() -> Array:
	return TerminalEquipmentList.mock_nodes(self)

func _seg_btn(text: String, id: String, alarm: bool) -> Control:
	return TerminalEquipmentList.seg_btn(self, text, id, alarm)

func _eq_head() -> Control:
	return TerminalEquipmentList.eq_head(self)

func _fill_nodes(nodes: Array) -> void:
	TerminalEquipmentList.fill_nodes(self, nodes)

func _rebuild_list() -> void:
	TerminalEquipmentList.rebuild_list(self)

func _empty_list_text() -> String:
	return TerminalEquipmentList.empty_list_text(self)

func _restore_scroll(value: int) -> void:
	TerminalEquipmentList.restore_scroll(self, value)

func _on_row_input(event: InputEvent, element_id: int) -> void:
	TerminalEquipmentList.on_row_input(self, event, element_id)

func select_element(element_id: int) -> void:
	TerminalEquipmentList.select_element(self, element_id)

func select_index(index: int) -> void:
	TerminalEquipmentList.select_index(self, index)

func _selected_node() -> Dictionary:
	return TerminalEquipmentList.selected_node(self)

func _node_name(node: Dictionary) -> String:
	return TerminalEquipmentList.node_name(self, node)

func _node_tag(node: Dictionary) -> String:
	return TerminalEquipmentList.node_tag(self, node)

func _node_value_text(node: Dictionary) -> String:
	return TerminalEquipmentList.node_value_text(self, node)

func _severity_color(severity: String) -> Color:
	return TerminalEquipmentList.severity_color(self, severity)

func _severity_mark(severity: String) -> String:
	return TerminalEquipmentList.severity_mark(self, severity)

func _eq_row(node: Dictionary, idx: int, selected: bool) -> Control:
	return TerminalEquipmentList.eq_row(self, node, idx, selected)

func _build_faceplate() -> Control:
	return TerminalFaceplateBuilder.build_faceplate(self)

func _fill_faceplate() -> void:
	# Единая точка: жест ввода блокирует любую пересборку (refresh, rebuild_list, rename).
	if (
		_faceplate_press_active
		or _slider_drag_active
		or get_viewport().gui_is_dragging()
	):
		return
	TerminalFaceplateBuilder.fill_faceplate(self)


## Оптимистично пишет поля в detail выбранного узла и пересобирает фейсплейт.
## Нужно потому, что live-patch не тащил steerable/уставки колеса — клик
## доходил до submit, а тумблер/± на экране оставались со старым detail.
func _patch_selected_detail(fields: Dictionary) -> void:
	if fields.is_empty() or _selected_element_id <= 0:
		return
	for i: int in range(_nodes.size()):
		if not _nodes[i] is Dictionary:
			continue
		var node: Dictionary = _nodes[i]
		if int(node.get("element_id", -1)) != _selected_element_id:
			continue
		var detail: Dictionary = node.get("detail", {})
		if not detail is Dictionary:
			detail = {}
		for key: Variant in fields.keys():
			detail[str(key)] = fields[key]
		node["detail"] = detail
		_nodes[i] = node
		break
	_last_live_sig = ""
	_fill_faceplate()

func _fp_head(node: Dictionary) -> Control:
	return TerminalFaceplateBuilder.fp_head(self, node)

func _rename_button() -> Control:
	return TerminalFaceplateBuilder.rename_button(self)

func _build_rename_edit(node: Dictionary) -> Control:
	return TerminalFaceplateBuilder.build_rename_edit(self, node)

func _begin_rename() -> void:
	TerminalFaceplateBuilder.begin_rename(self)

func _cancel_rename() -> void:
	TerminalFaceplateBuilder.cancel_rename(self)

func _on_rename_submitted(text: String) -> void:
	TerminalFaceplateBuilder.on_rename_submitted(self, text)

func _fp_readings(node: Dictionary, kind: String, detail: Dictionary) -> Control:
	return TerminalFaceplateBuilder.fp_readings(self, node, kind, detail)

func _fp_setpoints(kind: String, detail: Dictionary) -> Control:
	return TerminalFaceplateBuilder.fp_setpoints(self, kind, detail)

func _sp_row_from(param_id: String, detail: Dictionary) -> Control:
	return TerminalFaceplateBuilder.sp_row_from(self, param_id, detail)

func _sw_row(
	label: String,
	is_on: bool,
	on_text: String,
	off_text: String,
	action_id: String = ""
) -> Control:
	return TerminalFaceplateBuilder.sw_row(self, label, is_on, on_text, off_text, action_id)

func _fp_commands(kind: String) -> Control:
	return TerminalFaceplateBuilder.fp_commands(self, kind)

func _mode_toggle() -> Control:
	return TerminalFaceplateBuilder.mode_toggle(self)

func _fp_section(title: String, content: Control) -> Control:
	return TerminalFaceplateBuilder.fp_section(self, title, content)

func _pv_row(k: String, val: String, unit: String) -> Control:
	return TerminalFaceplateBuilder.pv_row(self, k, val, unit)

func _sparkline() -> Control:
	return TerminalFaceplateBuilder.sparkline(self)

func _sp_row(
	k: String,
	ratio: float,
	val: String,
	unit: String,
	focus: bool,
	payloads: Dictionary = {},
	param_id: String = ""
) -> Control:
	return TerminalFaceplateBuilder.sp_row(self, k, ratio, val, unit, focus, payloads, param_id)

func _slider(ratio: float, param_id: String = "") -> Control:
	return TerminalFaceplateBuilder.slider(self, ratio, param_id)

func _apply_slider_ratio(param_id: String, ratio: float) -> void:
	TerminalFaceplateBuilder.apply_slider_ratio(self, param_id, ratio)

func _end_slider_drag() -> void:
	TerminalFaceplateBuilder.end_slider_drag(self)

func _hover_bg(base: Color) -> Color:
	return TerminalWidgetKit.hover_bg(self, base)

func _drag_panel(
	bg: Color,
	bl: int,
	bt: int,
	br: int,
	bb: int,
	bc: Color,
	payload: Dictionary
) -> DragSource:
	return TerminalWidgetKit.drag_panel(self, bg, bl, bt, br, bb, bc, payload) as DragSource

func _edit_field(
	val: String,
	unit: String,
	focus: bool,
	payloads: Dictionary = {},
	param_id: String = ""
) -> Control:
	return TerminalFaceplateBuilder.edit_field(self, val, unit, focus, payloads, param_id)

func _cmd(glyph: String, text: String, kind: String, payload: Dictionary = {}) -> Control:
	return TerminalWidgetKit.cmd(self, glyph, text, kind, payload)

func _build_alarms() -> Control:
	return TerminalAlarmsPanel.build_alarms(self)

func _mock_alarms() -> Array:
	return TerminalAlarmsPanel.mock_alarms(self)

func _fill_alarms(alarms: Array) -> void:
	TerminalAlarmsPanel.fill_alarms(self, alarms)

func _sechead(title: String, right: String) -> Control:
	return TerminalWidgetKit.sechead(self, title, right)

func _alarm_row(
	name: String,
	tag: String,
	desc: String,
	time: String,
	col: Color,
	element_id := 0
) -> Control:
	return TerminalAlarmsPanel.alarm_row(self, name, tag, desc, time, col, element_id)

func _build_softbar() -> Control:
	return TerminalActionBar.build_softbar(self)


func _fill_pages() -> void:
	TerminalActionBar.fill_pages(self)


func _page_btn(index: int) -> Control:
	return TerminalActionBar.page_btn(self, index)


func _set_page(index: int) -> void:
	TerminalActionBar.set_page(self, index)


func _page_slots(page := -1) -> Array:
	return TerminalActionBar.page_slots(self, page)


func _page_has_bindings(page: int) -> bool:
	return TerminalActionBar.page_has_bindings(self, page)


func _fill_slots() -> void:
	TerminalActionBar.fill_slots(self)


func bind_slot(index: int, payload: Dictionary) -> void:
	TerminalActionBar.bind_slot(self, index, payload)


func clear_slot(index: int) -> void:
	TerminalActionBar.clear_slot(self, index)


func _submit_action_slot(index: int, payload: Dictionary) -> void:
	TerminalActionBar.submit_action_slot(self, index, payload)


func _ensure_local_bar_pages() -> void:
	TerminalActionBar.ensure_local_bar_pages(self)


func _fire_slot(index: int, pressed: bool, source := "") -> void:
	TerminalActionBar.fire_slot(self, index, pressed, source)


func _soft_key(index: int, slot: Dictionary) -> Control:
	return TerminalActionBar.soft_key(self, index, slot)


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
	return TerminalShellBuilder.build_statusbar(self)


func _status_cell(text: String, strong: String, border: bool) -> Control:
	return TerminalShellBuilder.status_cell(self, text, strong, border)
