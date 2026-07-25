class_name TerminalFaceplateBuilder
extends RefCounted

## Карточка выбранной машины K-пульта: показания, уставки, тумблеры режимов,
## переименование, шаг/слайдер/ручной ввод параметров.

# ---------- center: faceplate ----------

static func build_faceplate(terminal) -> Control:
	terminal._fp_box = terminal._vbox(0)
	TerminalFaceplateBuilder.fill_faceplate(terminal)
	return terminal._fp_box


## Перестройка фейсплейта под выбранный узел: шапка, показания, параметры (по
## ParameterCatalog для вида узла), команды. Для колеса параметры начинаются с
## булевых тумблеров (поворотность и направление привода).

## Перестройка фейсплейта под выбранный узел: шапка, показания, параметры (по
## ParameterCatalog для вида узла), команды. Для колеса параметры начинаются с
## булевых тумблеров (поворотность и направление привода).
static func fill_faceplate(terminal) -> void:
	if terminal._fp_box == null:
		return
	# Пока переименовывают — фейсплейт не трогаем: перестройка 10 Гц иначе
	# забирает фокус и стирает набранное.
	if terminal._rename_edit != null:
		return
	# Дубль-гард: прямые вызовы static тоже уважают жест ввода.
	if (
		terminal._faceplate_press_active
		or terminal._slider_drag_active
		or terminal.get_viewport().gui_is_dragging()
	):
		return
	for child: Node in terminal._fp_box.get_children():
		terminal._fp_box.remove_child(child)
		child.queue_free()
	terminal._slider_rows.clear()

	var node: Dictionary = terminal._selected_node()
	if node.is_empty():
		var empty: Control = terminal._panel(terminal.PANEL)
		empty.add_child(terminal._pad(terminal._lbl("Узел не выбран", terminal.FAINT, 12), 14, 16, 14, 16))
		terminal._fp_box.add_child(empty)
		return

	var kind: String = str(node.get("kind", "other"))
	var detail: Dictionary = node.get("detail", {})
	terminal._fp_box.add_child(TerminalFaceplateBuilder.fp_head(terminal, node))
	terminal._fp_box.add_child(TerminalFaceplateBuilder.fp_section(terminal, "ПОКАЗАНИЯ", TerminalFaceplateBuilder.fp_readings(terminal, node, kind, detail)))

	var setpoints: Control = TerminalFaceplateBuilder.fp_setpoints(terminal, kind, detail)
	if setpoints != null:
		terminal._fp_box.add_child(TerminalFaceplateBuilder.fp_section(terminal, 
			"ПАРАМЕТРЫ · ПЕРЕТАЩИ СТРОКУ НА КЛАВИШУ (УСТАНОВИТЬ / ±ШАГ)",
			setpoints
		))

	var commands: Control = TerminalFaceplateBuilder.fp_commands(terminal, kind)
	if commands != null:
		terminal._fp_box.add_child(TerminalFaceplateBuilder.fp_section(terminal, 
			"КОМАНДЫ · ПЕРЕТАЩИ НА КЛАВИШУ ПУЛЬТА ↓",
			commands
		))

static func fp_head(terminal, node: Dictionary) -> Control:
	var severity: String = str(node.get("severity", "ok"))
	var head: Control = terminal._panel(terminal.PANEL, 0, 0, 0, 1)
	var hh: HBoxContainer = terminal._hbox(9)
	if terminal._renaming:
		hh.add_child(TerminalFaceplateBuilder.build_rename_edit(terminal, node))
	else:
		hh.add_child(terminal._lbl(terminal._node_name(node), terminal.TXT, 15))
		hh.add_child(TerminalFaceplateBuilder.rename_button(terminal))
	hh.add_child(terminal._lbl(terminal._node_tag(node), terminal.DIM, 11))
	var stmk: Panel = Panel.new()
	stmk.add_theme_stylebox_override("panel", terminal._sbox(
		terminal.NOM if severity == "ok" else terminal._severity_color(severity)
	))
	stmk.custom_minimum_size = Vector2(8, 8)
	stmk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hh.add_child(terminal._pad(stmk, 6, 0, 0, 0))
	hh.add_child(terminal._lbl(
		HudTokens.status_label(StringName(node.get("status", &"ok"))).capitalize(),
		terminal.TXT2,
		12
	))
	var sp: Control = Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(sp)
	hh.add_child(terminal._lbl("Режим", terminal.DIM, 11))
	hh.add_child(TerminalFaceplateBuilder.mode_toggle(terminal))
	head.add_child(terminal._pad(hh, 14, 10, 14, 10))
	return head


## Переименование узла оператором. Имя — per-instance override в снапшоте
## (SetElementNameCommand); пустая строка возвращает авто-подпись архетипа.

## Переименование узла оператором. Имя — per-instance override в снапшоте
## (SetElementNameCommand); пустая строка возвращает авто-подпись архетипа.
static func rename_button(terminal) -> Control:
	var b: Control = terminal._panel(Color(0, 0, 0, 0))
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.tooltip_text = "Переименовать узел"
	b.gui_input.connect(terminal._on_click.bind(terminal._begin_rename))
	b.add_child(terminal._icon("pencil", terminal.FAINT, 13))
	return b

static func build_rename_edit(terminal, node: Dictionary) -> Control:
	terminal._rename_edit = LineEdit.new()
	terminal._rename_edit.text = str(node.get("custom_name", ""))
	terminal._rename_edit.placeholder_text = terminal._node_name(node)
	terminal._rename_edit.max_length = SetElementNameCommand.MAX_LENGTH
	terminal._rename_edit.custom_minimum_size = Vector2(240, 0)
	terminal._style_edit(terminal._rename_edit)
	terminal._rename_edit.add_theme_font_size_override("font_size", 15)
	terminal._rename_edit.text_submitted.connect(terminal._on_rename_submitted)
	terminal._rename_edit.grab_focus.call_deferred()
	return terminal._rename_edit

static func begin_rename(terminal) -> void:
	if terminal._renaming or terminal._selected_node().is_empty():
		return
	terminal._renaming = true
	terminal._fill_faceplate()

static func cancel_rename(terminal) -> void:
	if not terminal._renaming:
		return
	terminal._renaming = false
	terminal._rename_edit = null
	terminal._fill_faceplate()

static func on_rename_submitted(terminal, text: String) -> void:
	var element_id: int = int(terminal._selected_node().get("element_id", 0))
	terminal._renaming = false
	terminal._rename_edit = null
	if element_id > 0:
		terminal._submit("set_element_name", element_id, {
			"element_id": element_id,
			"element_name": text,
		})
	terminal._fill_faceplate()

static func fp_readings(terminal, node: Dictionary, kind: String, detail: Dictionary) -> Control:
	var v: VBoxContainer = terminal._vbox(0)
	if kind == "wheel":
		# Поворотность/направление уже показаны тумблерами в «Уставках» ниже —
		# дублировать те же два бита здесь нечем, тут только то, чего там нет:
		# живая телеметрия контакта с грунтом.
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Питание", "есть" if bool(detail.get("powered", false)) else "нет", ""
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Опора", "на грунте" if bool(detail.get("grounded", false)) else "в воздухе", ""
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Пробуксовка",
			"%.2f" % float(detail.get("slip_speed_mps", 0.0)),
			"м/с"
		))
		return v
	if kind == "control_seat":
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Колёса",
			"вкл" if bool(detail.get("control_wheels", true)) else "выкл",
			""
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Тяга",
			"вкл" if bool(detail.get("control_thrusters", false)) else "выкл",
			""
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Гирои",
			"вкл" if bool(detail.get("control_gyros", true)) else "выкл",
			""
		))
		return v
	if kind == "suspension":
		# «Ход» тут был бы тем же числом, что «Ход подвески» в параметрах ниже —
		# живой телеметрии сжатия у подвески нет, дублировать нечего.
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Допустимый ход",
			"%.2f…%.2f" % [
				float(detail.get("min_travel_m", 0.0)),
				float(detail.get("max_travel_m", 0.0)),
			],
			"м"
		))
		return v
	if kind == "oxygen_module":
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"O₂",
			"%.1f / %.1f" % [
				float(detail.get("oxygen_current_l", 0.0)),
				float(detail.get("oxygen_capacity_l", 0.0)),
			],
			"л"
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Питание",
			"есть" if bool(detail.get("powered", false)) else "нет",
			""
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Машина",
			"вкл" if bool(detail.get("machine_enabled", true)) else "выкл",
			""
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Нагрузка",
			"%.0f" % float(detail.get("demand_w", 0.0)),
			"Вт"
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Простой / актив",
			"%.0f / %.0f" % [
				float(detail.get("idle_w", 0.0)),
				float(detail.get("active_w", 0.0)),
			],
			"Вт"
		))
		return v
	if kind in ["piston", "rotor", "hinge"]:
		var angular: bool = kind != "piston"
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Скорость",
			"%.2f" % float(detail.get("observed_velocity", 0.0)),
			"рад/с" if angular else "м/с"
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Цель",
			"%.2f" % float(detail.get("target_position_m", 0.0)),
			"рад" if angular else "м"
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Питание", "%.0f" % float(detail.get("power_draw_w", 0.0)), "Вт"
		))
		v.add_child(TerminalFaceplateBuilder.pv_row(terminal, 
			"Мотор",
			"вкл" if bool(detail.get("enabled", true)) else "выкл",
			""
		))
		var trow: HBoxContainer = terminal._hbox(10)
		trow.custom_minimum_size = Vector2(0, 30)
		var k: Label = terminal._lbl("Угол" if angular else "Ход", terminal.DIM, 13)
		k.custom_minimum_size = Vector2(96, 0)
		trow.add_child(k)
		trow.add_child(TerminalFaceplateBuilder.sparkline(terminal))
		trow.add_child(terminal._lbl(terminal._node_value_text(node), terminal.TXT, 15))
		v.add_child(trow)
		return v
	v.add_child(TerminalFaceplateBuilder.pv_row(terminal, "Значение", terminal._node_value_text(node), ""))
	return v

static func fp_setpoints(terminal, kind: String, detail: Dictionary) -> Control:
	var ids: Array = terminal.SETPOINTS.get(kind, [])
	if (
		kind != "wheel"
		and kind != "control_seat"
		and kind != "oxygen_module"
		and ids.is_empty()
	):
		return null
	var v: VBoxContainer = terminal._vbox(9)
	if kind == "wheel":
		v.add_child(TerminalFaceplateBuilder.sw_row(terminal, 
			"Поворотное",
			bool(detail.get("steerable", false)),
			"Да",
			"Нет",
			"wheel.steerable_toggle"
		))
		v.add_child(TerminalFaceplateBuilder.sw_row(terminal, 
			"Направление",
			bool(detail.get("drive_inverted", false)),
			"Назад",
			"Вперёд",
			"wheel.invert_drive_toggle"
		))
	elif kind == "oxygen_module":
		v.add_child(TerminalFaceplateBuilder.sw_row(terminal, 
			"Питание модуля",
			bool(detail.get("machine_enabled", true)),
			"Вкл",
			"Выкл",
			"machine.toggle"
		))
	elif kind == "control_seat":
		v.add_child(TerminalFaceplateBuilder.sw_row(terminal, 
			"Control Wheels",
			bool(detail.get("control_wheels", true)),
			"Вкл",
			"Выкл",
			"seat.control_wheels_toggle"
		))
		v.add_child(TerminalFaceplateBuilder.sw_row(terminal, 
			"Control Thrusters",
			bool(detail.get("control_thrusters", false)),
			"Вкл",
			"Выкл",
			"seat.control_thrusters_toggle"
		))
		v.add_child(TerminalFaceplateBuilder.sw_row(terminal, 
			"Control Gyros",
			bool(detail.get("control_gyros", true)),
			"Вкл",
			"Выкл",
			"seat.control_gyros_toggle"
		))
	for param_variant: Variant in ids:
		var row: Control = TerminalFaceplateBuilder.sp_row_from(terminal, str(param_variant), detail)
		if row != null:
			v.add_child(row)
	return v


## Строка параметра из ParameterCatalog: живое значение из detail, шаг/подпись/
## единица/точность — из баланса, положение ползунка — по soft-диапазону.

## Строка параметра из ParameterCatalog: живое значение из detail, шаг/подпись/
## единица/точность — из баланса, положение ползунка — по soft-диапазону.
static func sp_row_from(terminal, param_id: String, detail: Dictionary) -> Control:
	var entry: Dictionary = GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return null
	var field: String = str(entry.get("field", ""))
	var raw: float = float(detail.get(field, 0.0))
	var scale: float = float(entry.get("display_scale", 1.0))
	var bounds: Vector2 = terminal._effective_bounds(param_id, detail, entry)
	var lo: float = bounds.x
	var hi: float = bounds.y
	var ratio: float = 0.0
	if hi - lo > 0.000001:
		ratio = clampf((raw - lo) / (hi - lo), 0.0, 1.0)
	var precision: int = int(entry.get("precision", 2))
	var label: String = str(entry.get("label", param_id))
	var unit: String = str(entry.get("unit", ""))
	var step: float = float(entry.get("step", 0.0))
	var node: Dictionary = terminal._selected_node()
	var shown: String = String.num(raw * scale, precision)

	var base: Dictionary = {
		"kind": "control_param",
		"param_id": param_id,
		"node_kind": str(node.get("kind", "other")),
		"element_id": int(node.get("element_id", 0)),
		"joint_id": int(node.get("joint_id", 0)),
		"node_name": terminal._node_name(node),
		"node_tag": terminal._node_tag(node),
	}
	var payload_set: Dictionary = base.duplicate()
	payload_set["action_id"] = "param.set"
	payload_set["value"] = raw
	payload_set["glyph"] = "equal"
	payload_set["label"] = "%s %s %s" % [label, shown, unit]
	var payload_inc: Dictionary = base.duplicate()
	payload_inc["action_id"] = "param.increase"
	payload_inc["delta"] = step
	payload_inc["glyph"] = "plus"
	payload_inc["label"] = "%s +%s" % [label, String.num(step * scale, precision)]
	var payload_dec: Dictionary = base.duplicate()
	payload_dec["action_id"] = "param.decrease"
	payload_dec["delta"] = step
	payload_dec["glyph"] = "minus"
	payload_dec["label"] = "%s −%s" % [label, String.num(step * scale, precision)]

	return TerminalFaceplateBuilder.sp_row(terminal, label, ratio, shown, unit, false, {
		"set": payload_set,
		"inc": payload_inc,
		"dec": payload_dec,
	}, param_id)


## Булев параметр (поворотность, направление): двухсегментный тумблер вместо
## ползунка — это не число, шаг к нему неприменим.

## Булев параметр (поворотность, направление): двухсегментный тумблер вместо
## ползунка — это не число, шаг к нему неприменим.
static func sw_row(terminal, 
	label: String,
	is_on: bool,
	on_text: String,
	off_text: String,
	action_id: String = ""
) -> Control:
	var node: Dictionary = terminal._selected_node()
	var h: HBoxContainer = terminal._hbox(9)
	var grip: Control = terminal._drag_panel(Color(0, 0, 0, 0), 0, 0, 0, 0, terminal.LINE2, {} if action_id.is_empty() else {
		"kind": "control_action",
		"action_id": action_id,
		"glyph": "sliders" if action_id.ends_with("steerable_toggle") else "reverse",
		"label": label,
		"node_kind": str(node.get("kind", "other")),
		"element_id": int(node.get("element_id", 0)),
		"joint_id": int(node.get("joint_id", 0)),
		"node_name": terminal._node_name(node),
		"node_tag": terminal._node_tag(node),
	})
	grip.add_child(terminal._icon("grip", terminal.FAINT, 13))
	h.add_child(grip)
	var kl: Label = terminal._lbl(label, terminal.DIM, 13)
	kl.custom_minimum_size = Vector2(90, 0)
	h.add_child(kl)
	var sp: Control = Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	var box: Control = terminal._panel(Color(0, 0, 0, 0), 1, 1, 1, 1, terminal.LINE2)
	var seg: HBoxContainer = terminal._hbox(0)
	var off_seg: Control = terminal._panel(
		Color(0, 0, 0, 0) if is_on else terminal.DARKCHIP, 0, 0, 1, 0, terminal.LINE2
	)
	off_seg.add_child(terminal._pad(terminal._lbl(
		off_text, terminal.DIM if is_on else Color(0.929, 0.937, 0.945), 11
	), 10, 3, 10, 3))
	seg.add_child(off_seg)
	var on_seg: Control = terminal._panel(terminal.DARKCHIP if is_on else Color(0, 0, 0, 0))
	on_seg.add_child(terminal._pad(terminal._lbl(
		on_text, Color(0.929, 0.937, 0.945) if is_on else terminal.DIM, 11
	), 10, 3, 10, 3))
	seg.add_child(on_seg)
	box.add_child(seg)
	if not action_id.is_empty():
		box.mouse_filter = Control.MOUSE_FILTER_STOP
		box.gui_input.connect(terminal._on_click.bind(terminal._run_action.bind({
			"action_id": action_id,
			"element_id": int(node.get("element_id", 0)),
			"joint_id": int(node.get("joint_id", 0)),
			"node_kind": str(node.get("kind", "other")),
		}, true)))
	h.add_child(box)
	return h

static func fp_commands(terminal, kind: String) -> Control:
	var rows: Array = terminal.COMMANDS.get(kind, [])
	if rows.is_empty():
		return null
	var node: Dictionary = terminal._selected_node()
	var h: HFlowContainer = HFlowContainer.new()
	h.add_theme_constant_override("h_separation", 7)
	h.add_theme_constant_override("v_separation", 7)
	for row_variant: Variant in rows:
		var row: Array = row_variant
		h.add_child(terminal._cmd(str(row[1]), str(row[2]), str(row[3]), {
			"kind": "control_action",
			"action_id": str(row[0]),
			"glyph": str(row[1]),
			"label": str(row[2]),
			"input_kind": str(row[3]),
			"node_kind": kind,
			"element_id": int(node.get("element_id", 0)),
			"joint_id": int(node.get("joint_id", 0)),
			"node_name": terminal._node_name(node),
			"node_tag": terminal._node_tag(node),
		}))
	return h


## Пока автоматической половины Binding нет (Control Graph), «Авто» — не
## переключатель, а честно погашенная позиция: врать активной кнопкой нельзя.

## Пока автоматической половины Binding нет (Control Graph), «Авто» — не
## переключатель, а честно погашенная позиция: врать активной кнопкой нельзя.
static func mode_toggle(terminal) -> Control:
	var box: Control = terminal._panel(Color(0, 0, 0, 0), 1, 1, 1, 1, terminal.LINE2)
	box.tooltip_text = "Автоматика появится вместе со схемой управления"
	var h: HBoxContainer = terminal._hbox(0)
	var a: Control = terminal._panel(Color(0, 0, 0, 0), 0, 0, 1, 0, terminal.LINE2)
	a.add_child(terminal._pad(terminal._lbl("Авто", terminal.FAINT, 11), 10, 3, 10, 3))
	h.add_child(a)
	var m: Control = terminal._panel(terminal.DARKCHIP)
	m.add_child(terminal._pad(terminal._lbl("Ручн", Color(0.929, 0.937, 0.945), 11), 10, 3, 10, 3))
	h.add_child(m)
	box.add_child(h)
	return box

static func fp_section(terminal, title: String, content: Control) -> Control:
	var wrap: Control = terminal._panel(terminal.PANEL, 0, 0, 0, 1)
	var v: VBoxContainer = terminal._vbox(9)
	v.add_child(terminal._lbl(title, terminal.TXT2, 11))
	v.add_child(content)
	wrap.add_child(terminal._pad(v, 14, 11, 14, 11))
	return wrap

static func pv_row(terminal, k: String, val: String, unit: String) -> Control:
	var wrap: Control = terminal._panel(terminal.PANEL, 0, 0, 0, 1)
	var h: HBoxContainer = terminal._hbox(0)
	var kl: Label = terminal._lbl(k, terminal.DIM, 13)
	kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(kl)
	h.add_child(terminal._lbl(val, terminal.TXT, 13, HORIZONTAL_ALIGNMENT_RIGHT))
	var ul: Label = terminal._lbl("  " + unit, terminal.DIM, 11)
	ul.custom_minimum_size = Vector2(40, 0)
	h.add_child(ul)
	wrap.add_child(terminal._pad(h, 0, 4, 0, 4))
	return wrap

static func sparkline(terminal) -> Control:
	var box: Control = Control.new()
	box.custom_minimum_size = Vector2(150, 26)
	var line: Line2D = Line2D.new()
	line.width = 1.2
	line.default_color = Color(0.337, 0.376, 0.412)
	line.points = PackedVector2Array([
		Vector2(0, 22), Vector2(18, 21), Vector2(34, 18), Vector2(52, 17),
		Vector2(70, 13), Vector2(88, 12), Vector2(104, 9), Vector2(120, 8),
		Vector2(136, 6), Vector2(150, 6),
	])
	box.add_child(line)
	var base: Line2D = Line2D.new()
	base.width = 1.0
	base.default_color = terminal.LINE
	base.points = PackedVector2Array([Vector2(0, 25), Vector2(150, 25)])
	box.add_child(base)
	return box

static func sp_row(terminal, 
	k: String,
	ratio: float,
	val: String,
	unit: String,
	focus: bool,
	payloads: Dictionary = {},
	param_id: String = ""
) -> Control:
	var h: HBoxContainer = terminal._hbox(9)
	h.add_child(terminal._icon("grip", terminal.FAINT, 13))
	var kl: Label = terminal._lbl(k, terminal.DIM, 13)
	kl.custom_minimum_size = Vector2(90, 0)
	h.add_child(kl)
	h.add_child(TerminalFaceplateBuilder.slider(terminal, ratio, param_id))
	h.add_child(TerminalFaceplateBuilder.edit_field(terminal, val, unit, focus, payloads, param_id))
	return h


## Живой трек: клик/протяг по нему пишет абсолютное значение через
## `_apply_slider_ratio` (см. класс SliderTrack). Дочерние Panel — только
## отрисовка, поэтому все — MOUSE_FILTER_IGNORE, иначе они бы сами глотали
## клик поверх трека и он бы никогда не доходил до `_gui_input`.

## Живой трек: клик/протяг по нему пишет абсолютное значение через
## `_apply_slider_ratio` (см. класс SliderTrack). Дочерние Panel — только
## отрисовка, поэтому все — MOUSE_FILTER_IGNORE, иначе они бы сами глотали
## клик поверх трека и он бы никогда не доходил до `_gui_input`.
static func slider(terminal, ratio: float, param_id: String = "") -> Control:
	var box: Variant = terminal._new_slider_track()
	box.terminal = terminal
	box.param_id = param_id
	box.custom_minimum_size = Vector2(0, 16)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	if not param_id.is_empty():
		box.mouse_default_cursor_shape = Control.CURSOR_HSPLIT

	var track: Panel = Panel.new()
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_theme_stylebox_override("panel", terminal._sbox(terminal.LINE))
	track.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	track.anchor_right = 1.0
	track.offset_left = 0
	track.offset_right = 0
	track.offset_top = -1
	track.offset_bottom = 2
	box.add_child(track)

	var fill: Panel = Panel.new()
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.add_theme_stylebox_override("panel", terminal._sbox(terminal.TXT2))
	fill.anchor_left = 0.0
	fill.anchor_right = ratio
	fill.anchor_top = 0.5
	fill.anchor_bottom = 0.5
	fill.offset_top = -1
	fill.offset_bottom = 2
	box.add_child(fill)

	var knob: Panel = Panel.new()
	knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	knob.add_theme_stylebox_override("panel", terminal._sbox(terminal.TXT))
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
		terminal._slider_rows[param_id] = {"fill": fill, "knob": knob}
	return box


## Ратио → значение → команда, вызывается на каждое движение SliderTrack (не
## только на отпускание) — шкала обязана ехать вместе с курсором, как у
## настоящего прибора. Значение и подпись поля обновляются тут же, без
## ожидания следующего тика снапшота (тот всё равно подавлен, см. _refresh).

## Ратио → значение → команда, вызывается на каждое движение SliderTrack (не
## только на отпускание) — шкала обязана ехать вместе с курсором, как у
## настоящего прибора. Значение и подпись поля обновляются тут же, без
## ожидания следующего тика снапшота (тот всё равно подавлен, см. _refresh).
static func apply_slider_ratio(terminal, param_id: String, ratio: float) -> void:
	terminal._slider_drag_active = true
	var entry: Dictionary = GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return
	var node: Dictionary = terminal._selected_node()
	var detail: Dictionary = node.get("detail", {})
	var bounds: Vector2 = terminal._effective_bounds(param_id, detail, entry)
	var value: float = lerpf(bounds.x, bounds.y, ratio)
	terminal._submit_param(
		param_id, value, int(node.get("element_id", 0)), int(node.get("joint_id", 0))
	)
	var row: Dictionary = terminal._slider_rows.get(param_id, {})
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

static func end_slider_drag(terminal) -> void:
	terminal._slider_drag_active = false


## Более тёплый оттенок в сторону цвета выделения — единственный сигнал
## «сюда можно бросить» теперь, когда клик по этим панелям больше не стреляет
## командой напрямую (см. terminal._on_click).

## Поле параметра — три независимых drag-источника: «−шаг», «установить текущее»,
## «+шаг». Так игрок тащит на клавишу ровно тот вариант, который хочет, без
## всплывающего выбора после броска.
static func edit_field(terminal, 
	val: String,
	unit: String,
	focus: bool,
	payloads: Dictionary = {},
	param_id: String = ""
) -> Control:
	var box: Control = terminal._panel(Color(0, 0, 0, 0), 1, 1, 1, 1, terminal.TXT2 if focus else terminal.LINE2)
	var h: HBoxContainer = terminal._hbox(0)
	var minus: Control = terminal._drag_panel(terminal.FLD, 0, 0, 1, 0, terminal.LINE2, payloads.get("dec", {}))
	minus.custom_minimum_size = Vector2(28, 26)
	minus.add_child(terminal._pad(terminal._lbl("−", terminal.DIM, 14), 6, 1, 6, 1))
	if not param_id.is_empty():
		# Клик через DragSource.click_action (не gui_input→_on_click): иначе
		# старт DnD съедает release и шаг не стреляет.
		minus.set("click_action", terminal._apply_param_step.bind(param_id, -1))
	h.add_child(minus)
	var fld: Control = terminal._drag_panel(terminal.FLD, 0, 0, 0, 0, terminal.LINE2, payloads.get("set", {}))
	fld.custom_minimum_size = Vector2(62, 0)
	var fh: HBoxContainer = terminal._hbox(4)
	var vl: Label = terminal._lbl(val, terminal.TXT, 12, HORIZONTAL_ALIGNMENT_RIGHT)
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fh.add_child(vl)
	fh.add_child(terminal._lbl(unit, terminal.FAINT, 10))
	fld.add_child(terminal._pad(fh, 8, 2, 8, 2))
	h.add_child(fld)
	var plus: Control = terminal._drag_panel(terminal.FLD, 1, 0, 0, 0, terminal.LINE2, payloads.get("inc", {}))
	plus.custom_minimum_size = Vector2(28, 26)
	plus.add_child(terminal._pad(terminal._lbl("+", terminal.DIM, 14), 6, 1, 6, 1))
	if not param_id.is_empty():
		plus.set("click_action", terminal._apply_param_step.bind(param_id, 1))
	h.add_child(plus)
	box.add_child(h)
	if not param_id.is_empty():
		if not terminal._slider_rows.has(param_id):
			terminal._slider_rows[param_id] = {}
		terminal._slider_rows[param_id]["value"] = vl
	return box


## Чистый drag-источник — эта кнопка НЕ исполняется кликом (глагол пробуется
## только через слот пульта, куда её перетащили). Клик-и-старт-жеста иначе
## конфликтует с началом перетаскивания: нажатие уходило бы в исполнение
## раньше, чем Godot успеет понять, что это drag. Подсветка при наведении —
## единственный сигнал «это можно перетащить».

