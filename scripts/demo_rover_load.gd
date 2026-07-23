extends Node3D

## Visual rover load demo: compose + physics/visual projection + load report overlay.
## Run: .\run.ps1 res://scenes/demo_rover_load.tscn

@export var phrase := (
	"колбаса низкая на 6 колёсах, кокпит в центре, питание сбоку"
)

const FLOOR_TOP_Y := 0.0

var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _visuals: ElementVisualProjection
var _report_label: Label


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_spawn_environment()
	if not _build_rover():
		return
	_update_report()


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

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	add_child(camera)
	camera.position = Vector3(7.0, 4.5, 7.0)
	camera.look_at_from_position(
		camera.position,
		Vector3(0.0, 1.0, 1.5),
		Vector3.UP
	)

	var canvas := CanvasLayer.new()
	add_child(canvas)
	_report_label = Label.new()
	_report_label.position = Vector2(16, 16)
	_report_label.add_theme_font_size_override("font_size", 14)
	canvas.add_child(_report_label)


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
