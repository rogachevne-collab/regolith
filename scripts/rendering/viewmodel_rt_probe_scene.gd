extends Node

## Minimal scene: probe RT, optional hello-triangle, then quit.
## Usage: godot --path . res://scenes/test_viewmodel_rt_probe.tscn --quit-after 3

func _ready() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		print("VIEWMODEL_RT_PROBE: RenderingDevice=null")
		get_tree().quit(1)
		return
	var rt := rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)
	print("VIEWMODEL_RT_PROBE: SUPPORTS_RAYTRACING_PIPELINE=", rt)
	print("VIEWMODEL_RT_PROBE: engine=", Engine.get_version_info())
	if rt:
		var hello_script: Script = load("res://scripts/rendering/viewmodel_rt_hello.gd")
		var hello: Node = hello_script.new()
		add_child(hello)
		await get_tree().process_frame
		await get_tree().process_frame
		print("VIEWMODEL_RT_PROBE: hello_triangle=", hello.get("last_ok"))
		if hello.has_method("cleanup"):
			hello.call("cleanup")
		hello.queue_free()
		await get_tree().process_frame
	get_tree().quit(0 if rt else 2)
