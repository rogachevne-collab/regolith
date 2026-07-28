class_name TerminalActionBar
extends RefCounted

## Softkey 9×9 action bar for the K-пульт: pages, bind/fire, snapshot apply.


static func build_softbar(terminal) -> Control:
	var wrap: Control = terminal._panel(terminal.HEAD, 0, 1, 0, 0, terminal.LINE2)
	var v: VBoxContainer = terminal._vbox(0)

	var sh: HBoxContainer = terminal._hbox(12)
	sh.add_child(terminal._lbl("ПУЛЬТ ДЕЙСТВИЙ", terminal.TXT2, 11))
	terminal._page_row = terminal._hbox(4)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.add_child(sp)
	sh.add_child(terminal._page_row)
	var shwrap: Control = terminal._panel(terminal.HEAD, 0, 0, 0, 1)
	shwrap.add_child(terminal._pad(sh, 12, 6, 12, 6))
	v.add_child(shwrap)
	TerminalActionBar.fill_pages(terminal)

	terminal._strip = terminal._hbox(0)
	TerminalActionBar.fill_slots(terminal)
	v.add_child(terminal._strip)
	wrap.add_child(v)
	return wrap


static func fill_pages(terminal) -> void:
	if terminal._page_row == null:
		return
	for child: Node in terminal._page_row.get_children():
		terminal._page_row.remove_child(child)
		child.queue_free()
	for i in range(terminal.PAGE_COUNT):
		terminal._page_row.add_child(TerminalActionBar.page_btn(terminal, i))


static func page_btn(terminal, index: int) -> Control:
	var on: bool = index == terminal._page
	var b: Control = terminal._panel(
		terminal.DARKCHIP if on else Color(0, 0, 0, 0), 1, 1, 1, 1, terminal.LINE2
	)
	b.custom_minimum_size = Vector2(20, 18)
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.gui_input.connect(terminal._on_click.bind(terminal._set_page.bind(index)))
	# Занятая страница читается тёмным номером: иначе понять, где что лежит,
	# можно только пролистав все девять.
	var c: Color = Color(0.929, 0.937, 0.945) if on else (
		terminal.TXT2 if TerminalActionBar.page_has_bindings(terminal, index) else terminal.DIM
	)
	b.add_child(terminal._lbl(str(index + 1), c, 11, HORIZONTAL_ALIGNMENT_CENTER))
	return b


## Листание страниц по кругу — как в строительном тулбаре.
static func set_page(terminal, index: int) -> void:
	var next: int = wrapi(index, 0, terminal.PAGE_COUNT)
	if next == terminal._page:
		return
	terminal._release_holds()
	terminal._page = next
	if terminal._open:
		TerminalActionBar.fill_pages(terminal)
		TerminalActionBar.fill_slots(terminal)


static func page_slots(terminal, page := -1) -> Array:
	var page_index: int = terminal._page if page < 0 else wrapi(page, 0, terminal.PAGE_COUNT)
	if page_index >= 0 and page_index < terminal._bar_pages.size():
		return terminal._bar_pages[page_index]
	return [{}, {}, {}, {}, {}, {}, {}, {}, {}]


static func page_has_bindings(terminal, page: int) -> bool:
	for slot_variant: Variant in TerminalActionBar.page_slots(terminal, page):
		if not (slot_variant as Dictionary).is_empty():
			return true
	return false


## Перерисовка полосы пульта из модели слотов.
static func fill_slots(terminal) -> void:
	if terminal._strip == null:
		return
	for child: Node in terminal._strip.get_children():
		terminal._strip.remove_child(child)
		child.queue_free()
	var slots: Array = TerminalActionBar.page_slots(terminal)
	for i in range(slots.size()):
		var key: Control = TerminalActionBar.soft_key(terminal, i, slots[i])
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		terminal._strip.add_child(key)
		if i < slots.size() - 1:
			terminal._strip.add_child(terminal._vrule())


## Привязка брошенной команды/параметра к клавише — идёт командой в
## симуляцию (`configure_action_slot`), не мутирует бар напрямую: бар —
## авторитетное состояние хоста, не локальный UI-стейт (CONTROL-ACTIONS-V0
## «Persistence и кооп»). Слот на экране обновится из следующего снапшота
## (до ~100 мс), тот же принцип, что и у остальных команд пульта.
static func bind_slot(terminal, index: int, payload: Dictionary) -> void:
	if index < 0 or index >= terminal.SLOTS_PER_PAGE or payload.is_empty():
		return
	TerminalActionBar.submit_action_slot(terminal, index, payload)


static func clear_slot(terminal, index: int) -> void:
	if index < 0 or index >= terminal.SLOTS_PER_PAGE:
		return
	TerminalActionBar.submit_action_slot(terminal, index, {})


## Пустой payload = снять клавишу (тот же приём, что пустое имя в
## SetElementNameCommand сбрасывает custom_name).
static func submit_action_slot(terminal, index: int, payload: Dictionary) -> void:
	if terminal._gateway == null or not terminal._gateway.has_method("submit"):
		# Изолированная сцена вёрстки (scenes/ui/test_control_terminal.tscn) —
		# гейтвея нет, но бар обязан оставаться кликабельным для проверки
		# вёрстки. _page_slots() без гейтвея возвращает новый пустой Array на
		# каждый вызов (_bar_pages никогда не заполняется), поэтому мутировать
		# нужно ЕГО ЖЕ элемент _bar_pages напрямую, а не то, что вернул
		# _page_slots() — иначе правка тут же теряется.
		TerminalActionBar.ensure_local_bar_pages(terminal)
		var page_index: int = wrapi(terminal._page, 0, terminal.PAGE_COUNT)
		if (
			index >= 0
			and index < terminal.SLOTS_PER_PAGE
			and page_index < terminal._bar_pages.size()
		):
			terminal._bar_pages[page_index][index] = payload.duplicate(true)
			TerminalActionBar.fill_slots(terminal)
			TerminalActionBar.fill_pages(terminal)
		return
	if terminal._host_element_id <= 0:
		return
	var command_id: int = terminal._gateway.call("submit", {
		"kind": &"configure_action_slot",
		# Источник — игрок, не панель: гейтвей сверяет его с текущим occupant
		# хоста (единственная команда пульта, для которой это важно).
		"source": terminal._player,
		"target": {
			"valid": true,
			"target_kind": InteractionHit.KIND_SIMULATION_ELEMENT,
			"element_id": terminal._host_element_id,
		},
		"parameters": {
			"host_element_id": terminal._host_element_id,
			"page": terminal._page,
			"index": index,
			"payload": payload,
		},
	})
	# Без этого отказ (occupant не тот / хост неполный) молчал бы — статус-бар
	# получает reason только для команд, зарегистрированных здесь.
	terminal._pending_commands[command_id] = true


## Только для фолбэка без гейтвея (см. _submit_action_slot) — держит
## _bar_pages настоящим 9×9-массивом, чтобы мутация клавиши не терялась.
static func ensure_local_bar_pages(terminal) -> void:
	if terminal._bar_pages.size() != terminal.PAGE_COUNT:
		terminal._bar_pages = TerminalActionBar.empty_bar_pages(terminal)


## Клавиша пульта → глагол. Пустой слот молчит. `source` различает удержание
## хоткея и удержание мышью: снимаются они по разным признакам.
static func fire_slot(terminal, index: int, pressed: bool, source := "") -> void:
	if index < 0 or index >= terminal.SLOTS_PER_PAGE:
		return
	var slot: Dictionary = TerminalActionBar.page_slots(terminal)[index]
	if slot.is_empty():
		return
	var hold_source: String = source if not source.is_empty() else "slot:%d" % index
	if pressed:
		terminal._begin_hold(hold_source, slot)
	else:
		terminal._held.erase(hold_source)
	terminal._run_action(slot, pressed)


static func soft_key(terminal, index: int, slot: Dictionary) -> Control:
	var empty: bool = slot.is_empty()
	# DropKey is an inner class on the terminal script — factory stays on node.
	var box = terminal._new_drop_key()
	box.terminal = terminal
	box.slot_index = index
	box.add_theme_stylebox_override("panel", terminal._sbox(
		terminal.PANEL,
		0, 0, 0, 0,
		terminal.LINE
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
	box.gui_input.connect(terminal._on_slot_input.bind(index))

	var v: VBoxContainer = terminal._vbox(0)
	var top: HBoxContainer = terminal._hbox(0)
	top.add_child(terminal._lbl(str(index + 1), terminal.DIM, 11))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	if not empty:
		top.add_child(terminal._icon(str(slot.get("glyph", "")), terminal.DIM, 14))
	v.add_child(top)
	var sp2 := Control.new()
	sp2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sp2)
	v.add_child(terminal._lbl(
		"—" if empty else str(slot.get("label", "")),
		terminal.FAINT if empty else terminal.TXT,
		12
	))
	v.add_child(terminal._lbl(
		"свободно" if empty else str(slot.get("node_tag", "")),
		terminal.FAINT if empty else terminal.DIM,
		10
	))
	box.add_child(terminal._pad(v, 10, 8, 10, 8))
	return box


## Бар приезжает целиком из снапшота — это хостовое авторитетное состояние,
## не то, что рисует сама панель. Смена хоста (в т.ч. на «нет хоста») сбрасывает
## текущую страницу: чужая страница №7 на новом хосте ничего не значит.
static func apply_bar_snapshot(terminal, host_element_id: int, pages: Array) -> void:
	var host_changed: bool = host_element_id != terminal._host_element_id
	terminal._host_element_id = host_element_id
	terminal._bar_pages = (
		pages if not pages.is_empty() else TerminalActionBar.empty_bar_pages(terminal)
	)
	if host_changed:
		terminal._page = 0
	# Полоса пульта — часть закрытого окна (_frame.visible=false), пока
	# не открыто перестраивать её незачем: данные (_bar_pages) для компактной
	# ленты уже свежие вне зависимости от этого.
	if terminal._open:
		TerminalActionBar.fill_pages(terminal)
		TerminalActionBar.fill_slots(terminal)


static func empty_bar_pages(terminal) -> Array:
	var pages: Array = []
	for _page_index in range(terminal.PAGE_COUNT):
		var slots: Array = []
		for _slot_index in range(terminal.SLOTS_PER_PAGE):
			slots.append({})
		pages.append(slots)
	return pages
