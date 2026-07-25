extends SceneTree

## Headless probe: prints RT capability and exits.
## Usage: godot --headless --script res://scripts/rendering/viewmodel_rt_probe.gd

func _init() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		print("VIEWMODEL_RT_PROBE: RenderingDevice=null (headless/no GPU?)")
		quit(1)
		return
	var rt := rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)
	print("VIEWMODEL_RT_PROBE: SUPPORTS_RAYTRACING_PIPELINE=", rt)
	print("VIEWMODEL_RT_PROBE: engine=", Engine.get_version_info())
	quit(0 if rt else 2)
