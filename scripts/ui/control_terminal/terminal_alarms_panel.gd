class_name TerminalAlarmsPanel
extends RefCounted

## Панель аварий K-пульта: заполнение списка и стили по severity.

# ---------- right: alarms ----------

static func build_alarms(terminal) -> Control:
	var v: VBoxContainer = terminal._vbox(0)

	var head: Control = terminal._panel(terminal.HEAD, 0, 0, 0, 1)
	var hh: HBoxContainer = terminal._hbox(0)
	var title: Label = terminal._lbl("АВАРИИ", terminal.TXT2, 11)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(title)
	terminal._alarms_count = terminal._lbl("—", terminal.DIM, 11)
	hh.add_child(terminal._alarms_count)
	head.add_child(terminal._pad(hh, 12, 7, 12, 7))
	v.add_child(head)

	terminal._alarm_box = terminal._vbox(0)
	terminal._alarm_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(terminal._scroll(terminal._alarm_box))
	TerminalAlarmsPanel.fill_alarms(terminal, TerminalAlarmsPanel.mock_alarms(terminal))

	v.add_child(terminal._sechead("ГРУППЫ", ""))
	var e: Control = terminal._panel(terminal.PANEL)
	e.add_child(terminal._pad(terminal._lbl("Группа из выделенных — скоро", terminal.FAINT, 11), 12, 14, 12, 14))
	v.add_child(e)
	return v

static func mock_alarms(terminal) -> Array:
	var alarms: Array = []
	for node_variant: Variant in terminal._mock_nodes():
		var node: Dictionary = node_variant
		if str(node.get("severity", "ok")) != "ok":
			alarms.append(node)
	return alarms


## Заполнение ленты аварий. Порядок задаёт билдер (отказы вперёд).

## Заполнение ленты аварий. Порядок задаёт билдер (отказы вперёд).
static func fill_alarms(terminal, alarms: Array) -> void:
	if terminal._alarm_box == null:
		return
	for child: Node in terminal._alarm_box.get_children():
		terminal._alarm_box.remove_child(child)
		child.queue_free()
	var count: int = 0
	for alarm_variant: Variant in alarms:
		if not alarm_variant is Dictionary:
			continue
		var alarm: Dictionary = alarm_variant
		var severity: String = str(alarm.get("severity", "warn"))
		terminal._alarm_box.add_child(TerminalAlarmsPanel.alarm_row(terminal, 
			terminal._node_name(alarm),
			terminal._node_tag(alarm),
			HudTokens.status_label(StringName(alarm.get("status", &"ok"))).to_lower(),
			"",
			terminal._severity_color(severity),
			int(alarm.get("element_id", 0))
		))
		count += 1
	if terminal._alarms_count != null:
		terminal._alarms_count.text = "%d актив." % count
	if terminal._alarms_head != null:
		terminal._alarms_head.text = str(count)
		terminal._alarms_head.add_theme_color_override(
			"font_color",
			terminal.AMBER if count > 0 else terminal.DIM
		)

## Строка аварии — кратчайший путь к отказавшему узлу: клик открывает его
## фейсплейт, не заставляя искать его же в списке слева.
static func alarm_row(terminal, 
	name: String,
	tag: String,
	desc: String,
	time: String,
	col: Color,
	element_id: int = 0
) -> Control:
	var wrap: Control = terminal._panel(terminal.PANEL, 0, 0, 0, 1)
	if element_id > 0:
		wrap.mouse_filter = Control.MOUSE_FILTER_STOP
		wrap.gui_input.connect(terminal._on_click.bind(terminal.select_element.bind(element_id)))
	var h: HBoxContainer = terminal._hbox(8)
	var mk: Panel = Panel.new()
	mk.add_theme_stylebox_override("panel", terminal._sbox(col))
	mk.custom_minimum_size = Vector2(8, 8)
	mk.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(mk)
	var col_v: VBoxContainer = terminal._vbox(2)
	var top: HBoxContainer = terminal._hbox(6)
	top.add_child(terminal._lbl(name, col, 12))
	top.add_child(terminal._lbl(tag, terminal.DIM, 10))
	col_v.add_child(top)
	col_v.add_child(terminal._lbl(desc, terminal.TXT2, 11))
	if not time.is_empty():
		col_v.add_child(terminal._lbl(time, terminal.DIM, 10))
	h.add_child(col_v)
	wrap.add_child(terminal._pad(h, 10, 7, 10, 7))
	return wrap


# ---------- bottom: soft keys ----------

