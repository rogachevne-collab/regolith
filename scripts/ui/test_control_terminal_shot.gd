extends Control
## Изолированный прогон вёрстки терминала: тёмный фон сцены + панель, кадр,
## скриншот в res://.tmp_terminal_shot.png, выход. Не часть игры.

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.063, 0.075)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var term: Control = preload("res://scripts/ui/hud_control_terminal.gd").new()
	term.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(term)
	term.open()

	for i in range(4):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	print("SHOT_SAVED err=", img.save_png("res://.tmp_terminal_shot.png"))

	# Второй кадр: колёсный узел + привязанные слоты (эмуляция броска на клавиши).
	term.call("select_index", 4)
	term.call("bind_slot", 0, {
		"kind": "control_param", "action_id": "param.set",
		"param_id": "wheel.drive_torque", "value": 0.8, "glyph": "equal",
		"label": "Тяга 0.80", "node_tag": "WHL1", "element_id": 0,
	})
	term.call("bind_slot", 1, {
		"kind": "control_param", "action_id": "param.increase",
		"param_id": "wheel.drive_torque", "delta": 0.1, "glyph": "plus",
		"label": "Тяга +0.10", "node_tag": "WHL1", "element_id": 0,
	})
	term.call("bind_slot", 2, {
		"kind": "control_action", "action_id": "wheel.reverse",
		"glyph": "reverse", "label": "Направление", "node_tag": "WHL1",
		"element_id": 0,
	})
	for i in range(3):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img2 := get_viewport().get_texture().get_image()
	print("SHOT2_SAVED err=", img2.save_png("res://.tmp_terminal_wheel.png"))
	get_tree().quit()
