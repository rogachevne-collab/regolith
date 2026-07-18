@tool
extends EditorPlugin

## Project → Tools → Regolith — moon save / heightmap utilities.

const _DevTools := preload("res://scripts/tools/moon_dev_tools.gd")
const _Params := preload("res://scripts/simulation/runtime/moon_terrain_params.gd")

const _ID_CLEAR_SAVE := 0
const _ID_REBAKE := 1
const _ID_OPEN_FOLDER := 2

var _submenu: PopupMenu


func _enter_tree() -> void:
	_submenu = PopupMenu.new()
	_submenu.add_item("Clear Save (keep heightmap)", _ID_CLEAR_SAVE)
	_submenu.add_item("Rebake Moon Heightmap", _ID_REBAKE)
	_submenu.add_separator()
	_submenu.add_item("Open Moon Userdata Folder", _ID_OPEN_FOLDER)
	_submenu.id_pressed.connect(_on_menu_id)
	add_tool_submenu_item("Regolith", _submenu)


func _exit_tree() -> void:
	remove_tool_menu_item("Regolith")
	_submenu = null


func _on_menu_id(id: int) -> void:
	match id:
		_ID_CLEAR_SAVE:
			_confirm_then(
				"Clear Save",
				(
					"Remove world_save.json and moon.sqlite for gen_v%d?\n"
					+ "Heightmap is kept. Stop Play first if the game is running."
				)
				% _Params.GENERATOR_VERSION,
				_do_clear_save
			)
		_ID_REBAKE:
			_confirm_then(
				"Rebake Moon Heightmap",
				(
					"Delete crust_heightmap.exr and bake again (2048×1024)?\n"
					+ "Native bake is usually a few seconds; GDScript fallback is slower."
				),
				_do_rebake
			)
		_ID_OPEN_FOLDER:
			_report(_DevTools.open_stream_folder())


func _confirm_then(title: String, text: String, on_ok: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.dialog_text = text
	dialog.ok_button_text = "Run"
	dialog.confirmed.connect(
		func() -> void:
			on_ok.call()
			dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	EditorInterface.popup_dialog_centered(dialog)


func _do_clear_save() -> void:
	if EditorInterface.is_playing_scene():
		_toast(
			"Stop Play first — running game may rewrite the save on quit.",
			true
		)
		return
	_report(_DevTools.clear_progress(true))


func _do_rebake() -> void:
	_toast("Baking moon heightmap…", false)
	_report(_DevTools.rebake_heightmap())


func _report(result: Dictionary) -> void:
	var msg := str(result.get("message", ""))
	var ok: bool = bool(result.get("ok", false))
	if ok:
		print("Regolith Tools: ", msg)
	else:
		push_error("Regolith Tools: " + msg)
	_toast(msg, not ok)


func _toast(message: String, is_error: bool) -> void:
	var toaster := EditorInterface.get_editor_toaster()
	if toaster == null:
		return
	var severity := (
		EditorToaster.SEVERITY_ERROR if is_error else EditorToaster.SEVERITY_INFO
	)
	toaster.push_toast(message, severity)
