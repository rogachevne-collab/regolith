extends Node
## Headless PoC gate for the ToolController runtime slot-remap API
## (docs/specs/HUD-UI-01.md Phase 4 — BlockPalette drag-drop backend). Exercises
## the remap logic directly (no input gesture, which MCP Lite cannot drive):
## assigning archetypes to slots, refusing drill/weld and unknown archetypes,
## leaving the const TOOLBAR_PAGES untouched, the change signal firing, and
## selecting a remapped slot driving selected_archetype_id through the SAME
## path used by keyboard slot selection.

var _layout_changes: Array = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _test_assign_changes_slot():
		return
	if not _test_const_layout_untouched():
		return
	if not _test_tool_slots_intact():
		return
	if not _test_unknown_archetype_rejected():
		return
	if not _test_layout_changed_signal():
		return
	if not _test_selection_path():
		return
	print("CONSTRUCTION-REMAP: PASS")
	get_tree().quit(0)


func _make_tools() -> ToolController:
	# Not added to the tree: _ready (which needs sibling nodes) never runs, so
	# this exercises the remap API against the lazily-built runtime layout.
	return ToolController.new()


func _test_assign_changes_slot() -> bool:
	var tools := _make_tools()
	# Page 0 slot 3 starts as "frame".
	if tools.toolbar_slot_archetype_id(0, 3) != "frame":
		return _fail("slot (0,3) expected initial 'frame', got '%s'" % tools.toolbar_slot_archetype_id(0, 3))
	if not tools.assign_slot_archetype(0, 3, "power_source"):
		return _fail("assign of a valid archetype to a block slot should succeed")
	if tools.toolbar_slot_archetype_id(0, 3) != "power_source":
		return _fail("slot (0,3) expected 'power_source' after remap, got '%s'" % tools.toolbar_slot_archetype_id(0, 3))
	if tools.toolbar_layout_revision != 1:
		return _fail("layout revision expected 1 after one remap, got %d" % tools.toolbar_layout_revision)
	# Empty slots (0,7)/(0,8) accept a remap too.
	if not tools.toolbar_slot_accepts_block(0, 7):
		return _fail("empty slot (0,7) should accept a block")
	if not tools.assign_slot_archetype(0, 7, "cargo_store"):
		return _fail("assign to empty slot (0,7) should succeed")
	if tools.toolbar_slot_archetype_id(0, 7) != "cargo_store":
		return _fail("slot (0,7) expected 'cargo_store', got '%s'" % tools.toolbar_slot_archetype_id(0, 7))
	tools.free()
	return true


func _test_const_layout_untouched() -> bool:
	var tools := _make_tools()
	tools.assign_slot_archetype(0, 3, "fabricator")
	# The const template must never be mutated by a runtime remap.
	var const_entry: Dictionary = ToolController.TOOLBAR_PAGES[0][3]
	if String(const_entry.get("archetype_id", "")) != "frame":
		return _fail("const TOOLBAR_PAGES[0][3] mutated to '%s'" % String(const_entry.get("archetype_id", "")))
	tools.free()
	return true


func _test_tool_slots_intact() -> bool:
	var tools := _make_tools()
	# Slot 0 = drill, slot 1 = weld, slot 2 = grinder — remaps must be refused.
	if tools.toolbar_slot_accepts_block(0, 0):
		return _fail("drill slot (0,0) should not accept a block")
	if tools.assign_slot_archetype(0, 0, "frame"):
		return _fail("remapping the drill slot should fail")
	if tools.toolbar_slot_archetype_id(0, 0) != "drill":
		return _fail("drill slot (0,0) changed to '%s'" % tools.toolbar_slot_archetype_id(0, 0))
	if tools.assign_slot_archetype(0, 1, "frame"):
		return _fail("remapping the weld slot should fail")
	if tools.toolbar_slot_archetype_id(0, 1) != "weld":
		return _fail("weld slot (0,1) changed to '%s'" % tools.toolbar_slot_archetype_id(0, 1))
	if tools.toolbar_slot_accepts_block(0, 2):
		return _fail("grinder slot (0,2) should not accept a block")
	if tools.assign_slot_archetype(0, 2, "frame"):
		return _fail("remapping the grinder slot should fail")
	if tools.toolbar_slot_archetype_id(0, 2) != "grinder":
		return _fail("grinder slot (0,2) changed to '%s'" % tools.toolbar_slot_archetype_id(0, 2))
	if tools.toolbar_layout_revision != 0:
		return _fail("refused remaps must not bump revision, got %d" % tools.toolbar_layout_revision)
	tools.free()
	return true


func _test_unknown_archetype_rejected() -> bool:
	var tools := _make_tools()
	if tools.assign_slot_archetype(0, 4, "banana"):
		return _fail("assigning an unknown archetype should fail")
	if tools.toolbar_slot_archetype_id(0, 4) != "frame_beam":
		return _fail("slot (0,4) changed after a rejected remap, got '%s'" % tools.toolbar_slot_archetype_id(0, 4))
	# Out-of-range page/slot are rejected gracefully.
	if tools.assign_slot_archetype(9, 0, "frame"):
		return _fail("assigning to an out-of-range page should fail")
	tools.free()
	return true


func _test_layout_changed_signal() -> bool:
	var tools := _make_tools()
	_layout_changes.clear()
	tools.toolbar_layout_changed.connect(_on_layout_changed)
	tools.assign_slot_archetype(0, 5, "processor")
	if _layout_changes.size() != 1:
		return _fail("toolbar_layout_changed should fire once, got %d" % _layout_changes.size())
	var change: Array = _layout_changes[0]
	if change[0] != 0 or change[1] != 5 or String(change[2]) != "processor":
		return _fail("signal args expected (0,5,processor), got %s" % str(change))
	# A refused remap must stay quiet.
	tools.assign_slot_archetype(0, 0, "frame")
	if _layout_changes.size() != 1:
		return _fail("refused remap should not emit, got %d" % _layout_changes.size())
	tools.toolbar_layout_changed.disconnect(_on_layout_changed)
	tools.free()
	return true


func _test_selection_path() -> bool:
	var tools := _make_tools()
	# Remap page 0 slot 6 (stationary_drill) to fabricator, then select it via
	# the same private path keyboard selection uses. selected_archetype_id must
	# follow the remapped archetype — no bespoke selection route.
	tools.assign_slot_archetype(0, 6, "fabricator")
	tools._apply_toolbar_slot(0, 6, true)
	if tools.active_tool != &"build":
		return _fail("selecting a block slot should set active_tool 'build', got '%s'" % tools.active_tool)
	if tools.selected_archetype_id != "fabricator":
		return _fail("selected_archetype_id expected 'fabricator', got '%s'" % tools.selected_archetype_id)

	# Remapping the currently selected slot re-drives selection automatically.
	tools.assign_slot_archetype(0, 6, "cargo_store")
	if tools.selected_archetype_id != "cargo_store":
		return _fail("remapping the selected slot should update selected_archetype_id, got '%s'" % tools.selected_archetype_id)
	tools.free()
	return true


func _on_layout_changed(page: int, slot: int, archetype_id: String) -> void:
	_layout_changes.append([page, slot, archetype_id])


func _fail(msg: String) -> bool:
	push_error("CONSTRUCTION-REMAP: FAIL - %s" % msg)
	print("CONSTRUCTION-REMAP: FAIL - %s" % msg)
	get_tree().quit(1)
	return false
