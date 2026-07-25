class_name TerminalWidgetKit
extends RefCounted

## Низкоуровневые строители контролов K-пульта: метки, панели, иконки,
## layout-хелперы, drag-кнопки команд. Состояние остаётся на терминале-view.

static func load_icon_font(terminal) -> void:
	if not FileAccess.file_exists(terminal.ICON_TTF):
		return
	terminal._icon_font = FontFile.new()
	terminal._icon_font.data = FileAccess.get_file_as_bytes(terminal.ICON_TTF)

static func icon(terminal, key: String, col: Color, size: int = 15) -> Control:
	var l: Label = Label.new()
	if terminal._icon_font != null and terminal.GLYPHS.has(key):
		l.text = String.chr(int(terminal.GLYPHS[key]))
		l.add_theme_font_override("font", terminal._icon_font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# ---------- style helpers ----------

# ---------- style helpers ----------

static func sbox(terminal, bg: Color, bl: int = 0, bt: int = 0, br: int = 0, bb: int = 0, bc: Color = Color(0.745, 0.769, 0.796)) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
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

static func panel(terminal, bg: Color, bl: int = 0, bt: int = 0, br: int = 0, bb: int = 0, bc: Color = Color(0.745, 0.769, 0.796)) -> PanelContainer:
	var p: PanelContainer = PanelContainer.new()
	p.add_theme_stylebox_override("panel", TerminalWidgetKit.sbox(terminal, bg, bl, bt, br, bb, bc))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

static func lbl(terminal, text: String, col: Color, size: int = 13, halign: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	l.horizontal_alignment = halign
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

static func vbox(terminal, sep: int = 0) -> VBoxContainer:
	var v: VBoxContainer = VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v

static func hbox(terminal, sep: int = 0) -> HBoxContainer:
	var h: HBoxContainer = HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h

static func vrule(terminal) -> Panel:
	var p: Panel = Panel.new()
	p.add_theme_stylebox_override("panel", TerminalWidgetKit.sbox(terminal, terminal.LINE))
	p.custom_minimum_size = Vector2(1, 0)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

static func hrule(terminal) -> Panel:
	var p: Panel = Panel.new()
	p.add_theme_stylebox_override("panel", TerminalWidgetKit.sbox(terminal, terminal.LINE))
	p.custom_minimum_size = Vector2(0, 1)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

static func pad(terminal, node: Control, l: int = 0, t: int = 0, r: int = 0, b: int = 0) -> MarginContainer:
	var m: MarginContainer = MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_bottom", b)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(node)
	return m


# ---------- build ----------

static func pad_col(terminal, node: Control, l: int, t: int, r: int, b: int, _x: int, br_w: int) -> Control:
	var wrap: Control = TerminalWidgetKit.panel(terminal, Color(0, 0, 0, 0), 0, 0, br_w, 0)
	wrap.add_child(TerminalWidgetKit.pad(terminal, node, l, t, r, b))
	return wrap

static func kv(terminal, k: String, v: String, vcol: Color) -> Control:
	var wrap: Control = TerminalWidgetKit.panel(terminal, Color(0, 0, 0, 0), 1, 0, 0, 0)
	var col: VBoxContainer = TerminalWidgetKit.vbox(terminal, 1)
	col.custom_minimum_size = Vector2(100, 0)
	col.add_child(TerminalWidgetKit.lbl(terminal, k, terminal.DIM, 10))
	terminal._last_kv_value = TerminalWidgetKit.lbl(terminal, v, vcol, 13)
	col.add_child(terminal._last_kv_value)
	wrap.add_child(TerminalWidgetKit.pad(terminal, col, 14, 8, 14, 8))
	return wrap

## Вертикальная прокрутка для длинных списков (сборка легко даёт сотню узлов).
static func scroll(terminal, content: Control) -> ScrollContainer:
	var sc: ScrollContainer = ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(content)
	return sc


## Fallback-данные, пока нет живого снапшота (изолированная сцена вёрстки).

## Поле ввода в приборной палитре: рамки нет, фон плоский — строка должна
## читаться как ячейка таблицы, а не как виджет игрового HUD.
static func style_edit(terminal, edit: LineEdit) -> void:
	edit.add_theme_stylebox_override("normal", TerminalWidgetKit.sbox(terminal, Color(0, 0, 0, 0)))
	edit.add_theme_stylebox_override("focus", TerminalWidgetKit.sbox(terminal, terminal.FLD, 0, 0, 0, 1, terminal.TXT2))
	edit.add_theme_color_override("font_color", terminal.TXT)
	edit.add_theme_color_override("font_placeholder_color", terminal.DIM)
	edit.add_theme_color_override("caret_color", terminal.TXT)
	edit.add_theme_color_override("font_selected_color", terminal.TXT)
	edit.add_theme_color_override("selection_color", terminal.SEL)
	edit.add_theme_font_size_override("font_size", 12)

## Более тёплый оттенок в сторону цвета выделения — единственный сигнал
## «сюда можно бросить» теперь, когда клик по этим панелям больше не стреляет
## командой напрямую (см. terminal._on_click).
static func hover_bg(terminal, base: Color) -> Color:
	return base.lerp(terminal.SEL, 0.6)


## PanelContainer, который можно утащить на клавишу пульта.

## PanelContainer, который можно утащить на клавишу пульта.
static func drag_panel(terminal, 
	bg: Color,
	bl: int,
	bt: int,
	br: int,
	bb: int,
	bc: Color,
	payload: Dictionary
) -> PanelContainer:
	var p: Variant = terminal._new_drag_source()
	p.terminal = terminal
	p.payload = payload
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_hover_style(
		TerminalWidgetKit.sbox(terminal, bg, bl, bt, br, bb, bc),
		TerminalWidgetKit.sbox(terminal, TerminalWidgetKit.hover_bg(terminal, bg), bl, bt, br, bb, bc)
	)
	return p


## Чистый drag-источник — эта кнопка НЕ исполняется кликом (глагол пробуется
## только через слот пульта, куда её перетащили). Клик-и-старт-жеста иначе
## конфликтует с началом перетаскивания: нажатие уходило бы в исполнение
## раньше, чем Godot успеет понять, что это drag. Подсветка при наведении —
## единственный сигнал «это можно перетащить».
static func cmd(terminal, glyph: String, text: String, kind: String, payload: Dictionary = {}) -> Control:
	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.anti_aliasing = false
	normal.bg_color = terminal.CELL
	normal.border_color = terminal.LINE2
	normal.set_border_width_all(1)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6
	var hover: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	hover.bg_color = TerminalWidgetKit.hover_bg(terminal, terminal.CELL)
	var box: Variant = terminal._new_drag_source()
	box.payload = payload
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.custom_minimum_size = Vector2(0, 34)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.set_hover_style(normal, hover)
	var h: HBoxContainer = TerminalWidgetKit.hbox(terminal, 7)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(TerminalWidgetKit.icon(terminal, glyph, terminal.TXT2, 15))
	h.add_child(TerminalWidgetKit.lbl(terminal, text, terminal.TXT, 13))
	var tag: Control = TerminalWidgetKit.panel(terminal, Color(0, 0, 0, 0), 1, 1, 1, 1, terminal.LINE2)
	tag.add_child(TerminalWidgetKit.pad(terminal, TerminalWidgetKit.lbl(terminal, kind, terminal.DIM, 9), 3, 1, 3, 1))
	h.add_child(tag)
	box.add_child(h)
	return box


# ---------- right: alarms ----------

static func sechead(terminal, title: String, right: String) -> Control:
	var wrap: Control = TerminalWidgetKit.panel(terminal, terminal.HEAD, 0, 0, 0, 1)
	var h: HBoxContainer = TerminalWidgetKit.hbox(terminal, 0)
	var t: Label = TerminalWidgetKit.lbl(terminal, title, terminal.TXT2, 11)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	if right != "":
		h.add_child(TerminalWidgetKit.lbl(terminal, right, terminal.DIM, 11))
	wrap.add_child(TerminalWidgetKit.pad(terminal, h, 12, 7, 12, 7))
	return wrap


## Строка аварии — кратчайший путь к отказавшему узлу: клик открывает его
## фейсплейт, не заставляя искать его же в списке слева.

