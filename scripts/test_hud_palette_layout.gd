extends Node
## Headless layout gate for the BlockPalette overlay (docs/specs/HUD-UI-01.md
## Phase 4). Asserts clipped scroll layout, readable Cyrillic labels, and drag
## payload contract without driving the drag gesture itself.

const TEST_VIEWPORT := Vector2i(1280, 720)
const SMALL_VIEWPORT := Vector2i(640, 480)


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _test_labels():
		return
	if not await _test_layout_at_default_viewport():
		return
	if not await _test_layout_at_small_viewport():
		return
	if not await _test_drag_payload():
		return
	print("HUD-PALETTE-LAYOUT: PASS")
	get_tree().quit(0)


func _test_labels() -> bool:
	for archetype_id: String in ToolController.CONSTRUCTION_ARCHETYPES:
		var label := HudTokens.archetype_label(archetype_id)
		if label.contains("_"):
			return _fail("label for %s must not expose raw id: '%s'" % [archetype_id, label])
		if label.is_empty() or label == "—":
			return _fail("label for %s must not be empty" % archetype_id)
	return true


func _test_layout_at_default_viewport() -> bool:
	var palette := await _spawn_palette(TEST_VIEWPORT)
	var panel := _find_first_panel(palette)
	var scroll := _find_first_scroll(palette)
	var grid := _find_first_grid(palette)
	if panel == null or scroll == null or grid == null:
		palette.queue_free()
		return _fail("palette must contain panel, scroll, and grid")
	if not panel.clip_contents:
		palette.queue_free()
		return _fail("panel must clip overflowing content")
	if grid.get_child_count() != ToolController.CONSTRUCTION_ARCHETYPES.size():
		palette.queue_free()
		return _fail(
			"grid expected %d entries, got %d"
			% [ToolController.CONSTRUCTION_ARCHETYPES.size(), grid.get_child_count()]
		)
	await get_tree().process_frame
	await get_tree().process_frame
	var panel_rect := panel.get_global_rect()
	for child_node in grid.get_children():
		if child_node is Control:
			var entry_rect := (child_node as Control).get_global_rect()
			if entry_rect.position.y > panel_rect.end.y + 1.0:
				continue
			if not panel_rect.encloses(entry_rect):
				palette.queue_free()
				return _fail("visible entry %s escapes panel bounds" % child_node.name)
	palette.queue_free()
	return true


func _test_layout_at_small_viewport() -> bool:
	var palette := await _spawn_palette(SMALL_VIEWPORT)
	var panel := _find_first_panel(palette)
	var scroll := _find_first_scroll(palette)
	var grid := _find_first_grid(palette)
	if panel == null or scroll == null or grid == null:
		palette.queue_free()
		return _fail("small viewport palette missing required nodes")
	await get_tree().process_frame
	await get_tree().process_frame
	var panel_h := panel.get_global_rect().size.y
	var max_h := float(SMALL_VIEWPORT.y) * 0.68 + 1.0
	if panel_h > max_h:
		palette.queue_free()
		return _fail("panel height %.1f exceeds small-viewport cap %.1f" % [panel_h, max_h])
	var grid_h := grid.get_combined_minimum_size().y
	var scroll_h := scroll.get_global_rect().size.y
	if grid_h > scroll_h + 1.0 and scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED:
		palette.queue_free()
		return _fail("grid taller than scroll but vertical scrolling is disabled")
	palette.queue_free()
	return true


func _test_drag_payload() -> bool:
	var palette := await _spawn_palette(TEST_VIEWPORT)
	var grid := _find_first_grid(palette)
	if grid == null or grid.get_child_count() == 0:
		palette.queue_free()
		return _fail("palette grid missing drag entries")
	var entry: Object = grid.get_child(0)
	if not entry.has_method("drag_payload"):
		palette.queue_free()
		return _fail("palette entry missing drag payload")
	var payload: Variant = entry.call("drag_payload")
	if not payload is Dictionary:
		palette.queue_free()
		return _fail("drag payload must be a dictionary")
	if String(payload.get("kind", "")) != "hud_block":
		palette.queue_free()
		return _fail("drag payload kind expected hud_block, got '%s'" % String(payload.get("kind", "")))
	if String(payload.get("archetype_id", "")).is_empty():
		palette.queue_free()
		return _fail("drag payload archetype_id must not be empty")
	palette.queue_free()
	return true


func _spawn_palette(viewport_size: Vector2i) -> Control:
	var host := Control.new()
	host.custom_minimum_size = viewport_size
	host.size = viewport_size
	add_child(host)
	var palette: Control = load("res://scripts/ui/hud_palette.gd").new()
	palette.theme = HudTokens.load_theme()
	host.add_child(palette)
	palette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await get_tree().process_frame
	return palette


func _find_first_panel(root: Node) -> Panel:
	return _find_first_of(root, Panel) as Panel


func _find_first_scroll(root: Node) -> ScrollContainer:
	return _find_first_of(root, ScrollContainer) as ScrollContainer


func _find_first_grid(root: Node) -> GridContainer:
	return _find_first_of(root, GridContainer) as GridContainer


func _find_first_of(root: Node, type_variant: Variant) -> Node:
	if is_instance_of(root, type_variant):
		return root
	for child_node in root.get_children():
		var found := _find_first_of(child_node, type_variant)
		if found != null:
			return found
	return null


func _fail(msg: String) -> bool:
	push_error("HUD-PALETTE-LAYOUT: FAIL - %s" % msg)
	print("HUD-PALETTE-LAYOUT: FAIL - %s" % msg)
	get_tree().quit(1)
	return false
