extends Control
## Bottom toolbar bound to ToolController. Presentation only: visualises the
## current page's slots (latin tool/archetype codes), the selected slot (cyan
## underline), the build orientation (24 orientations) and the construction
## component counter. Input stays in ToolController; this never mutates it.
##
## Slots double as drag-drop targets for the BlockPalette (Phase 4) and for
## player-owned tool instances from the terminal grid. Block drops call
## ToolController.assign_slot_archetype; tool drops bind an instance through the
## authoritative player inventory registry.


## A toolbar slot that accepts a compatible block archetype or tool instance.
class DropSlot:
	extends Panel

	var tools: ToolController
	var page := 0
	var slot_index := 0
	var highlight: ColorRect

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		var is_block := (
			data is Dictionary
			and String(data.get("kind", "")) == "hud_block"
			and tools != null
			and tools.toolbar_slot_accepts_block(page, slot_index)
		)
		var is_tool_instance := (
			data is Dictionary
			and String(data.get("kind", "")) == HudInventoryTransferUtil.PAYLOAD_KIND
			and str(data.get("source_store_id", ""))
				== PlayerIdentity.local_store_id()
			and not str(data.get("instance_id", "")).is_empty()
			and tools != null
			and tools.toolbar_slot_accepts_tool_instance(
				page,
				slot_index,
				str(data.get("instance_id", ""))
			)
		)
		var accepts := (
			is_block
			or is_tool_instance
		)
		if highlight != null:
			highlight.visible = accepts
		return accepts

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if highlight != null:
			highlight.visible = false
		if tools != null and data is Dictionary:
			if String(data.get("kind", "")) == "hud_block":
				tools.assign_slot_archetype(
					page,
					slot_index,
					String(data.get("archetype_id", ""))
				)
			elif String(data.get("kind", "")) == HudInventoryTransferUtil.PAYLOAD_KIND:
				tools.assign_slot_tool_instance(
					page,
					slot_index,
					str(data.get("instance_id", ""))
				)

	func _notification(what: int) -> void:
		if (
			what == NOTIFICATION_MOUSE_EXIT
			or what == NOTIFICATION_DRAG_END
		) and highlight != null:
			highlight.visible = false


var _tools: ToolController
var _gateway: WorldCommandGateway
var _preview: ConstructionPreview

var _slots_root: Control
var _slots: Array = []            # [{panel, glyph, underline}]
var _info: HBoxContainer
var _lbl_page: Label
var _lbl_selection: Label
var _lbl_orientation: Label
var _lbl_components: Label
var _lbl_snap: Label

var _slots_signature := ""
var _highlight_signature := -1


func setup(ctx: Dictionary) -> void:
	_tools = ctx.get("tools")
	_gateway = ctx.get("gateway")
	_preview = ctx.get("preview")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_slots_root = Control.new()
	_slots_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_slots_root)

	_info = HBoxContainer.new()
	_info.add_theme_constant_override("separation", 8)
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_info)
	_lbl_page = _add_info_label(HudTokens.COL_DIM)
	_add_info_sep()
	_lbl_selection = _add_info_label(HudTokens.COL_VALID, &"HudValue")
	_add_info_sep()
	_lbl_orientation = _add_info_label(HudTokens.COL_DIM)
	_add_info_sep()
	_lbl_components = _add_info_label(HudTokens.COL_OK, &"HudValue")
	_lbl_snap = _add_info_label(HudTokens.COL_DIM)


func _add_info_label(color: Color, variation: StringName = &"HudSmall") -> Label:
	var lbl := Label.new()
	lbl.theme_type_variation = variation
	lbl.add_theme_color_override("font_color", color)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_child(lbl)
	return lbl


func _add_info_sep() -> void:
	var lbl := Label.new()
	lbl.theme_type_variation = &"HudSmall"
	lbl.add_theme_color_override("font_color", HudTokens.COL_DIM)
	lbl.text = "·"
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_child(lbl)


func _process(_delta: float) -> void:
	if _tools == null:
		return
	var page := _tools.toolbar_page
	var signature := "%d|%d|%s" % [
		page,
		_tools.toolbar_layout_revision,
		str(get_viewport_rect().size),
	]
	if signature != _slots_signature:
		_rebuild_slots(page)
		_slots_signature = signature
		_highlight_signature = -1
	if _tools.toolbar_slot != _highlight_signature:
		_apply_highlight(_tools.toolbar_slot)
		_highlight_signature = _tools.toolbar_slot
	_update_info()


func _rebuild_slots(page: int) -> void:
	for child_node: Node in _slots_root.get_children():
		child_node.queue_free()
	_slots.clear()

	var count := ToolController.TOOLBAR_SLOTS_PER_PAGE
	var slot_size := HudTokens.SLOT_SIZE
	var gap := HudTokens.SLOT_GAP
	var total_w := count * int(slot_size.x) + (count - 1) * gap
	var vp := get_viewport_rect().size
	var origin := Vector2(
		(vp.x - total_w) * 0.5,
		vp.y - slot_size.y - HudTokens.TOOLBAR_BOTTOM
	)

	# Info row centred just above the slots.
	_info.position = Vector2(origin.x, origin.y - 26.0)
	_info.size = Vector2(total_w, 20)

	for i: int in count:
		var slot := DropSlot.new()
		slot.tools = _tools
		slot.page = page
		slot.slot_index = i
		slot.size = slot_size
		slot.position = origin + Vector2(i * (slot_size.x + gap), 0)
		# STOP so the slot can receive drag-drop; only the bottom strip is
		# pickable, the captured-cursor centre never overlaps it.
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		_slots_root.add_child(slot)

		# Cyan drop highlight (frozen state.valid), shown while a valid block
		# drag hovers the slot.
		var drop_highlight := ColorRect.new()
		drop_highlight.color = Color(
			HudTokens.COL_VALID.r,
			HudTokens.COL_VALID.g,
			HudTokens.COL_VALID.b,
			0.18
		)
		drop_highlight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		drop_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
		drop_highlight.visible = false
		slot.add_child(drop_highlight)
		slot.highlight = drop_highlight

		var underline := ColorRect.new()
		underline.color = HudTokens.COL_VALID
		underline.size = Vector2(slot_size.x - 12, 2)
		underline.position = Vector2(6, slot_size.y - 5)
		underline.mouse_filter = Control.MOUSE_FILTER_IGNORE
		underline.visible = false
		slot.add_child(underline)

		var glyph := Label.new()
		glyph.text = HudTokens.tool_code(_slot_archetype_id(page, i))
		glyph.theme_type_variation = &"HudSmall"
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(glyph)

		var num := Label.new()
		num.text = str(i + 1)
		num.theme_type_variation = &"HudSmall"
		num.position = Vector2(6, 2)
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(num)

		_slots.append({"panel": slot, "glyph": glyph, "underline": underline})


func _apply_highlight(selected: int) -> void:
	for i: int in _slots.size():
		var entry: Dictionary = _slots[i]
		var is_selected := i == selected
		var panel := entry["panel"] as Panel
		panel.theme_type_variation = (
			&"HudSlotSelected" if is_selected else &"HudSlot"
		)
		entry["underline"].visible = is_selected
		var glyph := entry["glyph"] as Label
		glyph.add_theme_color_override(
			"font_color",
			HudTokens.COL_VALID if is_selected else HudTokens.COL_DIM
		)


func _slot_archetype_id(page: int, slot: int) -> String:
	# Read the live runtime layout so remapped slots render immediately.
	return _tools.toolbar_slot_archetype_id(page, slot)


func _update_info() -> void:
	_lbl_page.text = "СТР %d/%d" % [
		_tools.toolbar_page + 1,
		_tools.toolbar_page_count(),
	]
	_lbl_selection.text = _selection_label()
	var is_build := _tools.active_tool == &"build"
	_lbl_orientation.text = (
		"ОРИЕНТ %s" % OrientationUtil.orientation_label(
			_tools.selected_orientation_index
		)
		if is_build else ""
	)
	if is_build:
		var hint := HudTokens.rover_orientation_hint(
			_tools.selected_archetype_id
		)
		if not hint.is_empty():
			_lbl_orientation.text += " · %s" % hint
	_lbl_orientation.visible = is_build
	_lbl_components.text = "%d КОМП" % int(round(
		_gateway.construction_resource_amount()
	))
	var snap := ""
	if (
		is_build
		and _preview != null
		and _preview.resolved_candidate_count > 1
	):
		snap = "· СНАП %d/%d" % [
			_preview.resolved_candidate_index + 1,
			_preview.resolved_candidate_count,
		]
	_lbl_snap.text = snap
	_lbl_snap.visible = not snap.is_empty()


func _selection_label() -> String:
	match _tools.active_tool:
		&"drill":
			return "БУР"
		&"weld":
			return "СВАРКА"
		&"grinder":
			return "БОЛГАРКА"
		&"connect":
			return "СОЕДИНЕНИЕ"
		&"build":
			return _gateway.archetype_display_name(
				_tools.selected_archetype_id
			).to_upper()
		_:
			return "—"
