extends Node3D

## Visual rover load demo: compose + load report + fixed camera presets.
## Run: .\run.ps1 res://scenes/demo_rover_load.tscn
## Keys 1-5 / [ ] cycle presets (side, 3/4, front, rear, top).

@export var phrase := (
	"огромная колбаса на 12 колёсах, широкая, высокая, кокпит в центре, питание сбоку, два бура на морде"
)

const FLOOR_TOP_Y := 0.0
const LOOK_AT := Vector3(1.5, 2.0, 5.0)

## name → camera world position (pulled back so the full silhouette fits).
const PRESETS: Array[Dictionary] = [
	{"name": "1 side", "pos": Vector3(20.0, 6.0, 5.0)},
	{"name": "2 three-quarter", "pos": Vector3(18.0, 8.0, 18.0)},
	{"name": "3 front", "pos": Vector3(1.5, 4.0, -16.0)},
	{"name": "4 rear", "pos": Vector3(1.5, 4.5, 24.0)},
	{"name": "5 top", "pos": Vector3(1.5, 28.0, 5.0)},
]

var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _visuals: ElementVisualProjection
var _report_label: Label
var _hint_label: Label
var _camera: Camera3D
var _preset_index := 1


func _ready() -> void:
	call_deferred("_run")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		match key.keycode:
			KEY_1, KEY_KP_1:
				_set_preset(0)
			KEY_2, KEY_KP_2:
				_set_preset(1)
			KEY_3, KEY_KP_3:
				_set_preset(2)
			KEY_4, KEY_KP_4:
				_set_preset(3)
			KEY_5, KEY_KP_5:
				_set_preset(4)
			KEY_BRACKETLEFT:
				_set_preset(_preset_index - 1)
			KEY_BRACKETRIGHT:
				_set_preset(_preset_index + 1)


func _run() -> void:
	_spawn_environment()
	if not _build_rover():
		return
	_update_report()
	_set_preset(_preset_index)
	if _wants_capture():
		await _capture_all_presets()


func _wants_capture() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg.strip_edges().to_lower() == "capture":
			return true
	return OS.get_environment("REGOLITH_DEMO_CAPTURE") == "1"


func _capture_all_presets() -> void:
	# Hide HUD so shots are clean for visual review.
	if _report_label != null:
		_report_label.visible = false
	if _hint_label != null:
		_hint_label.visible = false
	var dir := "user://rover_demo_shots"
	DirAccess.make_dir_recursive_absolute(dir)
	# Absolute path for the agent to open next.
	var abs_dir := ProjectSettings.globalize_path(dir)
	print("ROVER-DEMO-CAPTURE dir=%s" % abs_dir)
	for i: int in PRESETS.size():
		_set_preset(i)
		await get_tree().process_frame
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var slug := str(PRESETS[i]["name"]).replace(" ", "_").replace("/", "")
		var path := "%s/%d_%s.png" % [dir, i + 1, slug]
		var err := img.save_png(path)
		print(
			"ROVER-DEMO-CAPTURE preset=%s path=%s err=%s"
			% [PRESETS[i]["name"], ProjectSettings.globalize_path(path), err]
		)
	get_tree().quit(0)


func _spawn_environment() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80.0, 2.0, 80.0)
	shape.shape = box
	floor_body.add_child(shape)
	add_child(floor_body)
	floor_body.global_position = Vector3(0.0, FLOOR_TOP_Y - 1.0, 0.0)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, 35.0, 0.0)
	light.light_energy = 1.1
	add_child(light)

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.current = true
	add_child(_camera)

	var canvas := CanvasLayer.new()
	add_child(canvas)
	_report_label = Label.new()
	_report_label.position = Vector2(16, 16)
	_report_label.add_theme_font_size_override("font_size", 14)
	canvas.add_child(_report_label)
	_hint_label = Label.new()
	_hint_label.position = Vector2(16, 220)
	_hint_label.add_theme_font_size_override("font_size", 13)
	canvas.add_child(_hint_label)


func _set_preset(index: int) -> void:
	if _camera == null or PRESETS.is_empty():
		return
	_preset_index = posmod(index, PRESETS.size())
	var preset: Dictionary = PRESETS[_preset_index]
	var pos: Vector3 = preset["pos"]
	_camera.look_at_from_position(pos, LOOK_AT, Vector3.UP)
	_refresh_hint()


func _refresh_hint() -> void:
	if _hint_label == null:
		return
	var names: PackedStringArray = []
	for i: int in PRESETS.size():
		var mark := ">" if i == _preset_index else " "
		names.append("%s%s" % [mark, PRESETS[i]["name"]])
	_hint_label.text = (
		"camera: %s\nkeys 1-5 or [ ]"
		% "  ".join(names)
	)


func _build_rover() -> bool:
	_world = SimulationWorld.new()
	_world.ensure_resource_store(PlayerIdentity.store_id("player"))
	for resource_id: String in [
		"plate_metal", "girder", "mechanism", "conduit",
		"plate_basalt", "sintered_basalt", "plate_alloy",
	]:
		_world.set_resource_amount(
			PlayerIdentity.store_id("player"), resource_id, 800.0
		)

	_projection = SimulationPhysicsProjection.new()
	add_child(_projection)
	_projection.bind_world(_world)

	_visuals = ElementVisualProjection.new()
	add_child(_visuals)
	_visuals.bind(_world, _projection)

	var intent := RoverIntent.from_phrase(phrase)
	var composed := RoverComposer.compose(_world, intent)
	if not bool(composed.get("ok", false)):
		_report_label.text = (
			"compose failed: %s\n%s"
			% [composed.get("error", ""), composed.get("failures", [])]
		)
		return false

	var assembly_id := int(composed["assembly_id"])
	var locomotion := _world.get_locomotion_controller(assembly_id)
	locomotion.mark_released_from_anchor()
	locomotion.set_parking_brake(true)
	_projection.project_assembly_now(
		assembly_id,
		_world.get_assembly_raw(assembly_id).motion.duplicate_state()
	)
	_visuals.rebuild_assembly(assembly_id)

	var body := _projection.get_physics_body(assembly_id) as RigidBody3D
	if body != null:
		body.gravity_scale = 0.0
		body.global_position = Vector3(0.0, 1.2, 0.0)
		body.freeze = true

	return true


func _update_report() -> void:
	if _world == null:
		return
	var assembly_id := 0
	for assembly: SimulationAssembly in _world.list_assemblies():
		if not assembly.tombstoned:
			assembly_id = assembly.assembly_id
			break
	if assembly_id <= 0:
		_report_label.text = "no assembly"
		return
	var intent := RoverIntent.from_phrase(phrase)
	var report := RoverLoadReport.analyze(_world, assembly_id, intent)
	_report_label.text = RoverLoadReport.format_text(report)
