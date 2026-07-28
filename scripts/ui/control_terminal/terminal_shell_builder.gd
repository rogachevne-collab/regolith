class_name TerminalShellBuilder
extends RefCounted

## One-time chrome for the K-пульт: frame, topbar, body scaffold, statusbar.


static func build(terminal) -> void:
	# Пульт занимает весь экран: это рабочий терминал, а не всплывающее окошко.
	# Фиксированный размер резал контент на широких экранах и оставлял поля.
	terminal._frame = terminal._panel(terminal.PANEL, 1, 1, 1, 1, terminal.LINE2)
	terminal._frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	terminal._frame.mouse_filter = Control.MOUSE_FILTER_STOP
	terminal.add_child(terminal._frame)

	var root: VBoxContainer = terminal._vbox(0)
	terminal._frame.add_child(root)

	root.add_child(TerminalShellBuilder.build_topbar(terminal))
	root.add_child(terminal._hrule())

	var body: Control = TerminalShellBuilder.build_body(terminal)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	root.add_child(terminal._build_softbar())
	root.add_child(TerminalShellBuilder.build_statusbar(terminal))


static func build_topbar(terminal) -> Control:
	var bar: Control = terminal._panel(terminal.HEAD)
	var h: HBoxContainer = terminal._hbox(0)
	bar.add_child(h)

	var unit: VBoxContainer = terminal._vbox(1)
	terminal._unit_name = terminal._lbl("Нет цели", terminal.TXT, 14)
	unit.add_child(terminal._unit_name)
	terminal._unit_tag = terminal._lbl("наведись на технику", terminal.DIM, 11)
	unit.add_child(terminal._unit_tag)
	h.add_child(terminal._pad_col(unit, 14, 8, 14, 8, 0, 1))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(spacer)

	h.add_child(terminal._kv("Питание", "—", terminal.TXT))
	terminal._power_value = terminal._last_kv_value
	h.add_child(terminal._kv("Узлов", "0", terminal.TXT))
	terminal._nodes_count = terminal._last_kv_value
	h.add_child(terminal._kv("Аварии", "0", terminal.DIM))
	terminal._alarms_head = terminal._last_kv_value
	return bar


## Шапка из живого снапшота: тег сборки, потребление против выработки, счётчики.
## Красный «нет питания» — единственный цвет, который здесь допустим.
static func fill_unit(terminal, snap: Dictionary) -> void:
	var valid: bool = bool(snap.get("valid", false))
	var assembly_id: int = int(snap.get("assembly_id", 0))
	if terminal._unit_name != null:
		terminal._unit_name.text = "Сборка %02d" % assembly_id if valid else "Нет цели"
	if terminal._unit_tag != null:
		terminal._unit_tag.text = (
			"ASM‑%02d · %d элем." % [assembly_id, int(snap.get("element_count", 0))]
			if valid
			else "наведись на технику и открой пульт"
		)
	if terminal._power_value == null:
		return
	var power: Dictionary = snap.get("power", {})
	if not valid or not bool(power.get("valid", false)):
		terminal._power_value.text = "—"
		terminal._power_value.add_theme_color_override("font_color", terminal.DIM)
		return
	# Генераторов на сборке может не быть вовсе — тогда «0.0 кВт выработки» не
	# отказ, а норма: питание идёт из АКБ. Показываем расход и заряд.
	terminal._power_value.text = "%.2f кВт · АКБ %.0f %%" % [
		float(power.get("demand_w", 0.0)) * 0.001,
		float(power.get("battery_fraction", 0.0)) * 100.0,
	]
	terminal._power_value.add_theme_color_override(
		"font_color",
		terminal.TXT if bool(power.get("powered", false)) else terminal.RED
	)


static func build_body(terminal) -> Control:
	var h: HBoxContainer = terminal._hbox(0)

	var left: Control = terminal._build_equipment()
	left.custom_minimum_size = Vector2(terminal.COL_L, 0)
	h.add_child(left)
	h.add_child(terminal._vrule())

	var center: Control = terminal._build_faceplate()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(center)
	h.add_child(terminal._vrule())

	var right: Control = terminal._build_alarms()
	right.custom_minimum_size = Vector2(terminal.COL_R, 0)
	h.add_child(right)
	return h


# ---------- bottom: status bar ----------

static func build_statusbar(terminal) -> Control:
	var wrap: Control = terminal._panel(terminal.HEAD, 0, 1, 0, 0, terminal.LINE2)
	var h: HBoxContainer = terminal._hbox(0)
	h.add_child(TerminalShellBuilder.status_cell(terminal, "Оператор", "", true))
	h.add_child(TerminalShellBuilder.status_cell(terminal, "Режим: ", "Ручн", true))
	h.add_child(TerminalShellBuilder.status_cell(terminal, "Связь: ", "ОК", true))
	var fault_wrap: Control = terminal._panel(Color(0, 0, 0, 0), 0, 0, 1, 0)
	terminal._fault_cell = terminal._lbl("", terminal.RED, 11)
	terminal._fault_cell.visible = false
	fault_wrap.add_child(terminal._pad(terminal._fault_cell, 12, 5, 12, 5))
	h.add_child(fault_wrap)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	h.add_child(TerminalShellBuilder.status_cell(
		terminal, "ЛКМ выбрать · ПКМ снять клавишу", "", true
	))
	h.add_child(TerminalShellBuilder.status_cell(
		terminal, "перетащи команду на клавишу", "", true
	))
	h.add_child(TerminalShellBuilder.status_cell(
		terminal, "1–9 клавиша · [ ] стр.", "", true
	))
	h.add_child(TerminalShellBuilder.status_cell(
		terminal, "K / Esc закрыть", "", false
	))
	wrap.add_child(h)
	return wrap


static func status_cell(terminal, text: String, strong: String, border: bool) -> Control:
	var wrap: Control = terminal._panel(Color(0, 0, 0, 0), 0, 0, (1 if border else 0), 0)
	var h: HBoxContainer = terminal._hbox(0)
	h.add_child(terminal._lbl(text, terminal.DIM, 11))
	if strong != "":
		h.add_child(terminal._lbl(strong, terminal.TXT2, 11))
	wrap.add_child(terminal._pad(h, 12, 5, 12, 5))
	return wrap
