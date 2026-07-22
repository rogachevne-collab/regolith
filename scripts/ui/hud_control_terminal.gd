extends Control
## Инженерный SCADA/HMI терминал управления сборкой (CONTROL-ACTIONS-V0).
## Светлая приборная палитра — намеренно отдельная от HudTokens (тёмный игровой
## HUD). Первая вёрстка: строит layout по одобренному мокапу на mock-данных;
## реальные данные (InteractionQuery/SensorChannel/WorldCommandGateway) —
## следующим шагом. Иконки-плейсхолдеры (юникод) до подключения Lucide-шрифта.

const FRAME_W := 1200.0
const FRAME_H := 720.0
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
}

var _frame: PanelContainer
var _icon_font: FontFile
var _gateway: Node
var _query: Node
var _player: Node
var _open := false


func setup(ctx: Dictionary) -> void:
	_gateway = ctx.get("gateway")
	_query = ctx.get("query")
	_player = ctx.get("player")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_icon_font()
	_build()
	_apply_open_state()


func is_open() -> bool:
	return _open


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	if _open:
		return
	_open = true
	_apply_open_state()


func close() -> void:
	if not _open:
		return
	_open = false
	_apply_open_state()


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


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F9:
			toggle()
			get_viewport().set_input_as_handled()
		elif _open and event.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()


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
	return p


func _lbl(text: String, col: Color, size := 13, halign := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	l.horizontal_alignment = halign
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _vbox(sep := 0) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


func _hbox(sep := 0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


func _vrule() -> Panel:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", _sbox(LINE))
	p.custom_minimum_size = Vector2(1, 0)
	return p


func _hrule() -> Panel:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", _sbox(LINE))
	p.custom_minimum_size = Vector2(0, 1)
	return p


func _pad(node: Control, l := 0, t := 0, r := 0, b := 0) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_bottom", b)
	m.add_child(node)
	return m


# ---------- build ----------

func _build() -> void:
	_frame = _panel(PANEL, 1, 1, 1, 1, LINE2)
	_frame.anchor_left = 0.5
	_frame.anchor_top = 0.5
	_frame.anchor_right = 0.5
	_frame.anchor_bottom = 0.5
	_frame.offset_left = -FRAME_W * 0.5
	_frame.offset_right = FRAME_W * 0.5
	_frame.offset_top = -FRAME_H * 0.5
	_frame.offset_bottom = FRAME_H * 0.5
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
	unit.add_child(_lbl("Манипулятор‑01", TXT, 14))
	unit.add_child(_lbl("MNP‑01 · сборка", DIM, 11))
	h.add_child(_pad_col(unit, 14, 8, 14, 8, 0, 1))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(spacer)

	h.add_child(_kv("Питание", "4.2 / 6.0 кВт", TXT))
	h.add_child(_kv("Узлов", "12", TXT))
	h.add_child(_kv("Аварии", "2", AMBER))
	return bar


func _pad_col(node: Control, l: int, t: int, r: int, b: int, _x: int, br_w: int) -> Control:
	var wrap := _panel(Color(0, 0, 0, 0), 0, 0, br_w, 0)
	wrap.add_child(_pad(node, l, t, r, b))
	return wrap


func _kv(k: String, v: String, vcol: Color) -> Control:
	var wrap := _panel(Color(0, 0, 0, 0), 1, 0, 0, 0)
	var col := _vbox(1)
	col.custom_minimum_size = Vector2(100, 0)
	col.add_child(_lbl(k, DIM, 10))
	col.add_child(_lbl(v, vcol, 13))
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

	# segmented filter
	var seg := _hbox(0)
	seg.add_child(_seg_btn("Все", true, false))
	seg.add_child(_seg_btn("Приводы", false, false))
	seg.add_child(_seg_btn("Машины", false, false))
	seg.add_child(_seg_btn("Аварии", false, true))
	var seg_wrap := _panel(PANEL, 0, 0, 0, 1)
	seg_wrap.add_child(seg)
	v.add_child(seg_wrap)

	# search
	var srch := _panel(PANEL, 0, 0, 0, 1)
	srch.add_child(_pad(_lbl("⌕  поиск узла…", DIM, 12), 12, 6, 12, 6))
	v.add_child(srch)

	# header row
	v.add_child(_eq_head())

	# data rows
	var rows := [
		["●", "Поршень 01", "CY1", "0.82 м", TXT, true],
		["○", "Поршень 02", "CY2", "0.00 м", DIM, false],
		["●", "Ротор 01", "RT1", "12.0 °/с", TXT, false],
		["▲", "Шарнир 01", "HG1", "44 ° предел", AMBER, false],
		["▲", "Бур", "DR1", "нет пит.", AMBER, false],
		["●", "Процессор", "PR1", "62 %", TXT, false],
		["■", "Ротор 02", "RT2", "отказ", RED, false],
		["●", "Батарея", "BT1", "70 %", TXT, false],
		["●", "Склад", "ST1", "340/500", TXT, false],
	]
	var i := 0
	for r: Array in rows:
		v.add_child(_eq_row(r, i, r[5]))
		i += 1
	return v


func _seg_btn(text: String, on: bool, alarm: bool) -> Control:
	var col := AMBER if alarm else (TXT if on else DIM)
	var bg := SEL if on else Color(0, 0, 0, 0)
	var b := _panel(bg, 0, 0, 1, 0)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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


func _eq_row(r: Array, idx: int, selected: bool) -> Control:
	var mark: String = r[0]
	var name: String = r[1]
	var tag: String = r[2]
	var val: String = r[3]
	var vcol: Color = r[4]
	var bg := SEL if selected else (CELL if idx % 2 == 0 else CELLALT)
	var wrap := _panel(bg, (2 if selected else 0), 0, 0, 1, TXT2)
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
	var v := _vbox(0)

	# head: имя + tag · статус-читалка ... режим (control)
	var head := _panel(PANEL, 0, 0, 0, 1)
	var hh := _hbox(9)
	hh.add_child(_lbl("Поршень 01", TXT, 15))
	hh.add_child(_lbl("MNP‑01‑CY1", DIM, 11))
	var stmk := Panel.new()
	stmk.add_theme_stylebox_override("panel", _sbox(NOM))
	stmk.custom_minimum_size = Vector2(8, 8)
	stmk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hh.add_child(_pad(stmk, 6, 0, 0, 0))
	hh.add_child(_lbl("Работа", TXT2, 12))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(sp)
	hh.add_child(_lbl("Режим", DIM, 11))
	hh.add_child(_mode_toggle())
	head.add_child(_pad(hh, 14, 10, 14, 10))
	v.add_child(head)

	# показания
	v.add_child(_fp_section("ПОКАЗАНИЯ", _build_readings()))
	# уставки
	v.add_child(_fp_section("УСТАВКИ", _build_setpoints()))
	# команды
	v.add_child(_fp_section("КОМАНДЫ · ПЕРЕТАЩИ НА КЛАВИШУ ПУЛЬТА ↓", _build_commands()))
	return v


func _mode_toggle() -> Control:
	var box := _panel(Color(0, 0, 0, 0), 1, 1, 1, 1, LINE2)
	var h := _hbox(0)
	var a := _panel(Color(0, 0, 0, 0), 0, 0, 1, 0, LINE2)
	a.add_child(_pad(_lbl("Авто", DIM, 11), 10, 3, 10, 3))
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


func _build_readings() -> Control:
	var v := _vbox(0)
	v.add_child(_pv_row("Скорость", "0.30", "м/с"))
	v.add_child(_pv_row("Цель", "1.20", "м"))
	v.add_child(_pv_row("Питание", "120", "Вт"))
	v.add_child(_pv_row("Мотор", "вкл", ""))
	# trend
	var trow := _hbox(10)
	trow.custom_minimum_size = Vector2(0, 30)
	var k := _lbl("Ход", DIM, 13)
	k.custom_minimum_size = Vector2(96, 0)
	trow.add_child(k)
	trow.add_child(_sparkline())
	trow.add_child(_lbl("0.82", TXT, 15))
	trow.add_child(_lbl(" / 1.20 м", DIM, 11))
	v.add_child(trow)
	return v


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


func _build_setpoints() -> Control:
	var v := _vbox(9)
	v.add_child(_sp_row("Скорость", 0.42, "0.50", "м/с", true))
	v.add_child(_sp_row("Усилие", 0.64, "8.0", "кН", false))
	v.add_child(_sp_row("Верх. предел", 0.80, "1.20", "м", false))
	v.add_child(_sp_row("Ниж. предел", 0.02, "0.00", "м", false))
	return v


func _sp_row(k: String, ratio: float, val: String, unit: String, focus: bool) -> Control:
	var h := _hbox(11)
	var kl := _lbl(k, DIM, 13)
	kl.custom_minimum_size = Vector2(96, 0)
	h.add_child(kl)
	h.add_child(_slider(ratio))
	h.add_child(_edit_field(val, unit, focus))
	return h


func _slider(ratio: float) -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(0, 12)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var track := Panel.new()
	track.add_theme_stylebox_override("panel", _sbox(LINE))
	track.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	track.anchor_right = 1.0
	track.offset_left = 0
	track.offset_right = 0
	track.offset_top = -1
	track.offset_bottom = 2
	box.add_child(track)

	var fill := Panel.new()
	fill.add_theme_stylebox_override("panel", _sbox(TXT2))
	fill.anchor_left = 0.0
	fill.anchor_right = ratio
	fill.anchor_top = 0.5
	fill.anchor_bottom = 0.5
	fill.offset_top = -1
	fill.offset_bottom = 2
	box.add_child(fill)

	var knob := Panel.new()
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
	return box


func _edit_field(val: String, unit: String, focus: bool) -> Control:
	var box := _panel(Color(0, 0, 0, 0), 1, 1, 1, 1, TXT2 if focus else LINE2)
	var h := _hbox(0)
	var minus := _panel(FLD, 0, 0, 1, 0, LINE2)
	minus.add_child(_pad(_lbl("−", DIM, 14), 6, 1, 6, 1))
	h.add_child(minus)
	var fld := _panel(FLD)
	fld.custom_minimum_size = Vector2(62, 0)
	var fh := _hbox(4)
	var vl := _lbl(val, TXT, 12, HORIZONTAL_ALIGNMENT_RIGHT)
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fh.add_child(vl)
	fh.add_child(_lbl(unit, FAINT, 10))
	fld.add_child(_pad(fh, 8, 2, 8, 2))
	h.add_child(fld)
	var plus := _panel(FLD, 1, 0, 0, 0, LINE2)
	plus.add_child(_pad(_lbl("+", DIM, 14), 6, 1, 6, 1))
	h.add_child(plus)
	box.add_child(h)
	return box


func _build_commands() -> Control:
	var h := _hbox(7)
	h.add_child(_cmd("extend", "Выдвинуть", "удерж"))
	h.add_child(_cmd("retract", "Втянуть", "удерж"))
	h.add_child(_cmd("stop", "Стоп", "раз"))
	h.add_child(_cmd("reverse", "Реверс", "раз"))
	h.add_child(_cmd("power", "Мотор", "тумб"))
	return h


func _cmd(glyph: String, text: String, kind: String) -> Control:
	var s := StyleBoxFlat.new()
	s.anti_aliasing = false
	s.bg_color = CELL
	s.border_color = LINE2
	s.set_border_width_all(1)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", s)
	box.custom_minimum_size = Vector2(0, 34)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
	v.add_child(_sechead("АВАРИИ", "2 актив."))
	v.add_child(_alarm_row("Ротор 02", "RT2", "отказ привода", "08:42:11", RED))
	v.add_child(_alarm_row("Бур", "DR1", "нет питания", "08:39:04", AMBER))
	v.add_child(_sechead("ГРУППЫ", ""))
	var e := _panel(PANEL)
	e.add_child(_pad(_lbl("Группа из выделенных — скоро", FAINT, 11), 12, 14, 12, 14))
	v.add_child(e)
	return v


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


func _alarm_row(name: String, tag: String, desc: String, time: String, col: Color) -> Control:
	var wrap := _panel(PANEL, 0, 0, 0, 1)
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
	var pages := _hbox(4)
	for i in range(1, 10):
		pages.add_child(_page_btn(str(i), i == 1))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.add_child(sp)
	sh.add_child(pages)
	var shwrap := _panel(HEAD, 0, 0, 0, 1)
	shwrap.add_child(_pad(sh, 12, 6, 12, 6))
	v.add_child(shwrap)

	var keys := _hbox(0)
	var data := [
		["extend", "Выдвинуть", "CY1 · 0.82 м", 0],
		["retract", "Втянуть", "CY1 · 0.82 м", 0],
		["reverse", "Реверс", "RT1 · 12 °/с", 0],
		["power", "Бур вкл/выкл", "DR1 · нет пит.", 1],
		["power", "Процессор", "PR1 · вкл 62%", 0],
		["", "—", "свободно", 2],
		["stop", "Шарнир стоп", "HG1 · готов", 0],
		["", "—", "свободно", 2],
		["", "—", "свободно", 2],
	]
	var i := 1
	for d: Array in data:
		var k := _soft_key(i, d[0], d[1], d[2], d[3])
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		keys.add_child(k)
		if i < 9:
			keys.add_child(_vrule())
		i += 1
	v.add_child(keys)
	wrap.add_child(v)
	return wrap


func _page_btn(text: String, on: bool) -> Control:
	var b := _panel(DARKCHIP if on else Color(0, 0, 0, 0), 1, 1, 1, 1, LINE2)
	b.custom_minimum_size = Vector2(20, 18)
	var c := Color(0.929, 0.937, 0.945) if on else DIM
	b.add_child(_lbl(text, c, 11, HORIZONTAL_ALIGNMENT_CENTER))
	return b


func _soft_key(num: int, glyph: String, label: String, state: String, kind: int) -> Control:
	# kind: 0 normal, 1 warn, 2 empty
	var bg := CELLALT if kind == 1 else PANEL
	var box := _panel(bg)
	box.custom_minimum_size = Vector2(0, 56)
	var v := _vbox(0)
	var top := _hbox(0)
	top.add_child(_lbl(str(num), DIM, 11))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	if glyph != "":
		top.add_child(_icon(glyph, DIM, 14))
	v.add_child(top)
	var sp2 := Control.new()
	sp2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sp2)
	var lcol := FAINT if kind == 2 else (TXT2 if kind == 1 else TXT)
	v.add_child(_lbl(label, lcol, 12))
	var scol := AMBER if kind == 1 else (FAINT if kind == 2 else DIM)
	v.add_child(_lbl(state, scol, 10))
	box.add_child(_pad(v, 10, 8, 10, 8))
	return box


# ---------- bottom: status bar ----------

func _build_statusbar() -> Control:
	var wrap := _panel(HEAD, 0, 1, 0, 0, LINE2)
	var h := _hbox(0)
	h.add_child(_status_cell("Оператор", "", true))
	h.add_child(_status_cell("Режим: ", "Ручн", true))
	h.add_child(_status_cell("Связь: ", "ОК", true))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	h.add_child(_status_cell("ЛКМ выбрать", "", true))
	h.add_child(_status_cell("перетащи команду на клавишу", "", true))
	h.add_child(_status_cell("1–9 клавиша · Q/E стр.", "", true))
	h.add_child(_status_cell("E закрыть", "", false))
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
