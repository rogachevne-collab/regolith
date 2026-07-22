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
	var err := img.save_png("res://.tmp_terminal_shot.png")
	print("SHOT_SAVED err=", err)
	get_tree().quit()
