class_name TerminalEquipmentList
extends RefCounted

## Список оборудования K-пульта: фильтры, поиск, перестроение строк,
## выделение и прокрутка к выбранному элементу.

# ---------- left: equipment ----------

static func build_equipment(terminal) -> Control:
	var v: VBoxContainer = terminal._vbox(0)

	terminal._seg_row = terminal._hbox(0)
	var seg_wrap: Control = terminal._panel(terminal.PANEL, 0, 0, 0, 1)
	seg_wrap.add_child(terminal._seg_row)
	v.add_child(seg_wrap)
	TerminalEquipmentList.fill_filters(terminal)

	v.add_child(TerminalEquipmentList.build_search(terminal))

	# header row
	v.add_child(TerminalEquipmentList.eq_head(terminal))

	terminal._list_box = terminal._vbox(0)
	terminal._list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	terminal._list_scroll = terminal._scroll(terminal._list_box)
	v.add_child(terminal._list_scroll)
	TerminalEquipmentList.fill_nodes(terminal, TerminalEquipmentList.mock_nodes(terminal))
	return v

static func fill_filters(terminal) -> void:
	if terminal._seg_row == null:
		return
	for child: Node in terminal._seg_row.get_children():
		terminal._seg_row.remove_child(child)
		child.queue_free()
	for entry_variant: Variant in terminal.FILTERS:
		var entry: Array = entry_variant
		var id: String = str(entry[0])
		terminal._seg_row.add_child(TerminalEquipmentList.seg_btn(terminal, str(entry[1]), id, id == "alarm"))

static func set_filter(terminal, id: String) -> void:
	if terminal._filter == id:
		return
	terminal._filter = id
	TerminalEquipmentList.fill_filters(terminal)
	TerminalEquipmentList.rebuild_list(terminal)


## Поиск по имени и тегу узла. Строка живёт вне перестройки списка, иначе
## обновление 10 Гц забирало бы фокус на каждом кадре.

## Поиск по имени и тегу узла. Строка живёт вне перестройки списка, иначе
## обновление 10 Гц забирало бы фокус на каждом кадре.
static func build_search(terminal) -> Control:
	var wrap: Control = terminal._panel(terminal.PANEL, 0, 0, 0, 1)
	wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	var h: HBoxContainer = terminal._hbox(6)
	h.add_child(terminal._icon("search", terminal.DIM, 13))
	terminal._search_edit = LineEdit.new()
	terminal._search_edit.placeholder_text = "поиск узла…"
	terminal._search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	terminal._style_edit(terminal._search_edit)
	# Сигналы — только через методы узла: bind на static(terminal, …) ломает
	# порядок аргументов (Callable.bind дописывает хвост после signal-args).
	terminal._search_edit.text_changed.connect(terminal._on_search_changed)
	h.add_child(terminal._search_edit)
	wrap.add_child(terminal._pad(h, 12, 4, 12, 4))
	return wrap


## Поле ввода в приборной палитре: рамки нет, фон плоский — строка должна
## читаться как ячейка таблицы, а не как виджет игрового HUD.

static func on_search_changed(terminal, text: String) -> void:
	terminal._search = text.strip_edges().to_lower()
	TerminalEquipmentList.rebuild_list(terminal)


## Срез списка под фильтр и поиск. Полный `terminal._nodes` при этом не режем: живые
## значения слотов и фейсплейта читаются из него независимо от того, что видно.

## Срез списка под фильтр и поиск. Полный `terminal._nodes` при этом не режем: живые
## значения слотов и фейсплейта читаются из него независимо от того, что видно.
static func visible_nodes(terminal) -> Array:
	var rows: Array = []
	for node_variant: Variant in terminal._nodes:
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		match terminal._filter:
			"alarm":
				if str(node.get("severity", "ok")) == "ok":
					continue
			"all":
				pass
			_:
				if str(node.get("category", "other")) != terminal._filter:
					continue
		if not terminal._search.is_empty():
			var haystack: String = "%s %s" % [TerminalEquipmentList.node_name(terminal, node), TerminalEquipmentList.node_tag(terminal, node)]
			if not haystack.to_lower().contains(terminal._search):
				continue
		rows.append(node)
	return rows


## Вертикальная прокрутка для длинных списков (сборка легко даёт сотню узлов).

## Fallback-данные, пока нет живого снапшота (изолированная сцена вёрстки).
static func mock_nodes(terminal) -> Array:
	var piston_detail: Dictionary = {
		"observed": 0.82, "observed_velocity": 0.30, "target_position_m": 1.20,
		"power_draw_w": 120.0, "extend_velocity_mps": 0.50,
		"retract_velocity_mps": 0.50, "force_limit_n": 8000.0,
		"lower_limit_m": 0.0, "upper_limit_m": 1.20,
	}
	var rotor_detail: Dictionary = {
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
				"max_steering_angle_rad": 0.4887,
				"authored_max_steering_angle_rad": 0.4887,
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

static func seg_btn(terminal, text: String, id: String, alarm: bool) -> Control:
	var on: bool = terminal._filter == id
	var col: Color = terminal.AMBER if alarm else (terminal.TXT if on else terminal.DIM)
	var bg: Color = terminal.SEL if on else Color(0, 0, 0, 0)
	var b: Control = terminal._panel(bg, 0, 0, 1, 0)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.gui_input.connect(terminal._on_click.bind(terminal._set_filter.bind(id)))
	b.add_child(terminal._pad(terminal._lbl(text, col, 11, HORIZONTAL_ALIGNMENT_CENTER), 4, 6, 4, 6))
	return b

static func eq_head(terminal) -> Control:
	var wrap: Control = terminal._panel(terminal.CELLALT, 0, 0, 0, 1)
	var h: HBoxContainer = terminal._hbox(0)
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 5)
	m.add_theme_constant_override("margin_bottom", 5)
	m.add_child(h)
	var st: Label = terminal._lbl("", terminal.DIM, 10)
	st.custom_minimum_size = Vector2(20, 0)
	h.add_child(st)
	var nm: Label = terminal._lbl("УЗЕЛ", terminal.DIM, 10)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(nm)
	h.add_child(terminal._lbl("ЗНАЧЕНИЕ", terminal.DIM, 10, HORIZONTAL_ALIGNMENT_RIGHT))
	wrap.add_child(m)
	return wrap


## Заполнение списка узлов из снапшота (или mock).

## Заполнение списка узлов из снапшота (или mock).
static func fill_nodes(terminal, nodes: Array) -> void:
	terminal._nodes = nodes
	if terminal._nodes_count != null:
		terminal._nodes_count.text = str(nodes.size())
	TerminalEquipmentList.rebuild_list(terminal)


## Перестройка строк из уже полученных данных: её же зовут фильтр и поиск.

## Перестройка строк из уже полученных данных: её же зовут фильтр и поиск.
static func rebuild_list(terminal) -> void:
	if terminal._list_box == null:
		return
	for child: Node in terminal._list_box.get_children():
		terminal._list_box.remove_child(child)
		child.queue_free()
	var visible_nodes: Array = TerminalEquipmentList.visible_nodes(terminal)
	# Узел мог уехать из снапшота (разобрали, сменили цель) — тогда садимся на
	# первый видимый, а не показываем пустой фейсплейт.
	if TerminalEquipmentList.selected_node(terminal).is_empty() and not visible_nodes.is_empty():
		terminal._selected_element_id = int(
			(visible_nodes[0] as Dictionary).get("element_id", 0)
		)
	# Перестройка сбрасывает прокрутку — возвращаем её, иначе длинный список
	# при обновлении 10 Гц просто невозможно листать.
	var keep_scroll: int = 0
	if terminal._list_scroll != null:
		keep_scroll = terminal._list_scroll.scroll_vertical
	var idx: int = 0
	for node_variant: Variant in visible_nodes:
		var node: Dictionary = node_variant
		var element_id: int = int(node.get("element_id", 0))
		terminal._list_box.add_child(
			TerminalEquipmentList.eq_row(terminal, node, idx, element_id == terminal._selected_element_id)
		)
		idx += 1
	if idx == 0:
		var empty: Control = terminal._panel(terminal.PANEL)
		empty.add_child(terminal._pad(
			terminal._lbl(TerminalEquipmentList.empty_list_text(terminal), terminal.FAINT, 12),
			12, 14, 12, 14
		))
		terminal._list_box.add_child(empty)
	if terminal._list_scroll != null and keep_scroll > 0:
		terminal._restore_scroll.call_deferred(keep_scroll)
	terminal._fill_faceplate()

static func empty_list_text(terminal) -> String:
	if terminal._nodes.is_empty():
		return "Нет цели — наведись на технику и открой пульт"
	if not terminal._search.is_empty():
		return "Ничего не найдено"
	return "В этом срезе узлов нет"

static func restore_scroll(terminal, value: int) -> void:
	if terminal._list_scroll != null:
		terminal._list_scroll.scroll_vertical = value

static func on_row_input(terminal, event: InputEvent, element_id: int) -> void:
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
		and element_id != terminal._selected_element_id
	):
		terminal.select_element(element_id)


## Выбор узла (клик по строке списка либо по строке аварии).

## Выбор узла (клик по строке списка либо по строке аварии).
static func select_element(terminal, element_id: int) -> void:
	if element_id == terminal._selected_element_id:
		return
	terminal._selected_element_id = element_id
	terminal._last_live_sig = ""
	terminal._cancel_rename()
	TerminalEquipmentList.rebuild_list(terminal)


## Выбор узла по позиции в видимом списке (дев-харнес вёрстки).

## Выбор узла по позиции в видимом списке (дев-харнес вёрстки).
static func select_index(terminal, index: int) -> void:
	var visible_nodes: Array = TerminalEquipmentList.visible_nodes(terminal)
	if index < 0 or index >= visible_nodes.size():
		return
	terminal.select_element(int((visible_nodes[index] as Dictionary).get("element_id", 0)))

static func selected_node(terminal) -> Dictionary:
	for node_variant: Variant in terminal._nodes:
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		if int(node.get("element_id", -1)) == terminal._selected_element_id:
			return node
	return {}

static func node_name(terminal, node: Dictionary) -> String:
	var custom: String = str(node.get("custom_name", ""))
	if not custom.is_empty():
		return custom
	var label: String = HudTokens.archetype_label(str(node.get("archetype_id", "")))
	return "%s %02d" % [label.capitalize(), int(node.get("ordinal", 1))]

static func node_tag(terminal, node: Dictionary) -> String:
	return "%s%d" % [
		HudTokens.tool_code(str(node.get("archetype_id", ""))),
		int(node.get("ordinal", 1)),
	]


## Значение колонки: явный текст (mock) → форматирование по value_kind → статус.

## Значение колонки: явный текст (mock) → форматирование по value_kind → статус.
static func node_value_text(terminal, node: Dictionary) -> String:
	var explicit: String = str(node.get("value_text", ""))
	if not explicit.is_empty():
		return explicit
	var value: float = float(node.get("value", 0.0))
	match str(node.get("value_kind", "none")):
		"length_m":
			return "%.2f м" % value
		"angle_rad":
			return "%.0f °" % rad_to_deg(value)
		"fraction":
			return "%.0f %%" % (value * 100.0)
	return HudTokens.status_label(StringName(node.get("status", &"ok"))).to_lower()

static func severity_color(terminal, severity: String) -> Color:
	match severity:
		"fault":
			return terminal.RED
		"warn":
			return terminal.AMBER
	return terminal.TXT

static func severity_mark(terminal, severity: String) -> String:
	match severity:
		"fault":
			return "■"
		"warn":
			return "▲"
	return "●"

static func eq_row(terminal, node: Dictionary, idx: int, selected: bool) -> Control:
	var severity: String = str(node.get("severity", "ok"))
	var mark: String = TerminalEquipmentList.severity_mark(terminal, severity)
	var name: String = TerminalEquipmentList.node_name(terminal, node)
	var tag: String = TerminalEquipmentList.node_tag(terminal, node)
	var val: String = TerminalEquipmentList.node_value_text(terminal, node)
	var vcol: Color = TerminalEquipmentList.severity_color(terminal, severity)
	var bg: Color = terminal.SEL if selected else (terminal.CELL if idx % 2 == 0 else terminal.CELLALT)
	var wrap: Control = terminal._panel(bg, (2 if selected else 0), 0, 0, 1, terminal.TXT2)
	wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	wrap.gui_input.connect(
		terminal._on_row_input.bind(int(node.get("element_id", 0)))
	)
	# Наведение — не только курсор меняется, ряд обязан подсветиться: это
	# кликабельная таблица, а не статичный текст.
	if not selected:
		var hover_sbox: StyleBoxFlat = terminal._sbox(terminal._hover_bg(bg), 0, 0, 0, 1, terminal.TXT2)
		var normal_sbox: StyleBoxFlat = terminal._sbox(bg, 0, 0, 0, 1, terminal.TXT2)
		wrap.mouse_entered.connect(
			func(): wrap.add_theme_stylebox_override("panel", hover_sbox)
		)
		wrap.mouse_exited.connect(
			func(): wrap.add_theme_stylebox_override("panel", normal_sbox)
		)
	var h: HBoxContainer = terminal._hbox(0)
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 6)
	m.add_child(h)

	var mk_col: Color = terminal.AMBER if mark == "▲" else (terminal.RED if mark == "■" else (terminal.TXT2 if mark == "●" else terminal.FAINT))
	var mk: Label = terminal._lbl(mark, mk_col, 9)
	mk.custom_minimum_size = Vector2(20, 0)
	h.add_child(mk)

	var nm: Label = terminal._lbl(name, terminal.TXT, 13)
	h.add_child(nm)
	var tg: Label = terminal._lbl("  " + tag, terminal.FAINT, 11)
	h.add_child(tg)

	var sp: Control = Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)

	h.add_child(terminal._lbl(val, vcol, 12, HORIZONTAL_ALIGNMENT_RIGHT))
	wrap.add_child(m)
	return wrap


# ---------- center: faceplate ----------

