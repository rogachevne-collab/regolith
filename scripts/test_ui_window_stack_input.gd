extends Node

## Interactive gate for UIWindowStack: unlike other UI tests, this pushes real
## InputEvent objects through Input.parse_input_event() so it exercises the
## actual engine _unhandled_input propagation (autoload vs scene ordering),
## not just direct function calls. Catches exactly the class of bug that
## "call is_open() and check a bool" tests cannot: Escape reaching the wrong
## handler, or never reaching one at all.

const _HeadlessTestHarness := preload("res://scripts/testing/headless_test_harness.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "UI-WINDOW-STACK-INPUT")
	if not await _test_escape_closes_palette_opened_by_key():
		return
	if not await _test_settings_overlay_does_not_swallow_escape_for_other_windows():
		return
	print("UI-WINDOW-STACK-INPUT: PASS")
	get_tree().quit(0)


func _test_escape_closes_palette_opened_by_key() -> bool:
	var host := Control.new()
	host.custom_minimum_size = Vector2i(1280, 720)
	host.size = Vector2i(1280, 720)
	add_child(host)
	var palette: Control = load("res://scripts/ui/hud_palette.gd").new()
	palette.theme = HudTokens.load_theme()
	host.add_child(palette)
	palette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await get_tree().process_frame

	_press_physical_key(KEY_G)
	await get_tree().process_frame
	await get_tree().process_frame
	if not bool(palette.get("_open")):
		host.queue_free()
		return _fail("G did not open the palette")
	if not UIWindowStack.any_open():
		host.queue_free()
		return _fail("UIWindowStack did not register the opened palette")

	_press_physical_key(KEY_ESCAPE)
	await get_tree().process_frame
	await get_tree().process_frame
	if bool(palette.get("_open")):
		host.queue_free()
		return _fail("Escape did not close the palette")
	if UIWindowStack.any_open():
		host.queue_free()
		return _fail("UIWindowStack still reports a window open after Escape close")

	host.queue_free()
	return true


## Reproduces the reported bug: with the settings overlay (Escape-to-open)
## sitting as a sibling that ALSO listens for release_mouse, closing some
## other window (palette) with Escape must still work regardless of which
## node's _unhandled_input the engine happens to call first. The overlay
## must never eat the event on a failed/no-op open.
func _test_settings_overlay_does_not_swallow_escape_for_other_windows() -> bool:
	var fake_player := _FakePlayer.new()
	add_child(fake_player)
	var camera := _FakeCamera.new()
	camera.name = "Camera"
	fake_player.add_child(camera)
	var settings: CanvasLayer = _build_fake_settings_overlay()
	fake_player.add_child(settings)
	await get_tree().process_frame

	var host := Control.new()
	host.custom_minimum_size = Vector2i(1280, 720)
	host.size = Vector2i(1280, 720)
	add_child(host)
	var palette: Control = load("res://scripts/ui/hud_palette.gd").new()
	palette.theme = HudTokens.load_theme()
	host.add_child(palette)
	palette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await get_tree().process_frame

	_press_physical_key(KEY_G)
	await get_tree().process_frame
	await get_tree().process_frame
	if not bool(palette.get("_open")):
		fake_player.queue_free()
		host.queue_free()
		return _fail("G did not open the palette (settings sibling present)")

	_press_physical_key(KEY_ESCAPE)
	await get_tree().process_frame
	await get_tree().process_frame
	var settings_open := bool(settings.call("is_open"))
	var palette_open := bool(palette.get("_open"))
	fake_player.queue_free()
	host.queue_free()
	if settings_open:
		return _fail("Escape opened the settings overlay ON TOP of the already-open palette")
	if palette_open:
		return _fail(
			"Escape did not close the palette because the settings overlay "
			+ "swallowed the event on its own failed/no-op open attempt"
		)
	return true


class _FakePlayer:
	extends Node

	var _enabled := true

	func set_gameplay_input_enabled(enabled: bool) -> void:
		_enabled = enabled

	func is_gameplay_input_enabled() -> bool:
		return _enabled


class _FakeCamera:
	extends Camera3D

	var sensitivity := 0.3

	func set_look_sensitivity(_value: float) -> void:
		pass

	func set_camera_fov(_value: float) -> void:
		pass


func _build_fake_settings_overlay() -> CanvasLayer:
	var overlay: CanvasLayer = load("res://scripts/player_settings_overlay.gd").new()
	var panel := Control.new()
	panel.name = "Panel"
	overlay.add_child(panel)
	var margin := Control.new()
	margin.name = "Margin"
	panel.add_child(margin)
	var content := Control.new()
	content.name = "Content"
	margin.add_child(content)
	var sensitivity_row := Control.new()
	sensitivity_row.name = "Sensitivity"
	content.add_child(sensitivity_row)
	var sensitivity_slider := HSlider.new()
	sensitivity_slider.name = "Slider"
	sensitivity_row.add_child(sensitivity_slider)
	var sensitivity_value := Label.new()
	sensitivity_value.name = "Value"
	sensitivity_row.add_child(sensitivity_value)
	var fov_row := Control.new()
	fov_row.name = "Fov"
	content.add_child(fov_row)
	var fov_slider := HSlider.new()
	fov_slider.name = "Slider"
	fov_row.add_child(fov_slider)
	var fov_value := Label.new()
	fov_value.name = "Value"
	fov_row.add_child(fov_value)
	var close_button := Button.new()
	close_button.name = "Close"
	content.add_child(close_button)
	return overlay


## Mirrors what the OS actually sends for a real keypress: both physical_keycode
## (layout-independent position) and keycode (logical/localized) populated, not
## just physical_keycode — a synthetic event with keycode left at 0 does not
## match InputMap entries recorded with keycode set (as release_mouse is).
func _press_physical_key(physical_keycode: Key) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = physical_keycode
	down.keycode = physical_keycode
	down.pressed = true
	Input.parse_input_event(down)
	var up := InputEventKey.new()
	up.physical_keycode = physical_keycode
	up.keycode = physical_keycode
	up.pressed = false
	Input.parse_input_event(up)


func _fail(reason: String) -> bool:
	push_error("UI-WINDOW-STACK-INPUT: FAIL - %s" % reason)
	print("UI-WINDOW-STACK-INPUT: FAIL - %s" % reason)
	get_tree().quit(1)
	return false
