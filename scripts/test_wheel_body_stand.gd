extends Node3D
## WHEEL-BODY-V1 стенд на ровном полу, на той самой паре деталей, которую
## ставит игра (композер + детали визарда).
##
## Фаза «на весу» — шасси без гравитации, колёса висят: droop-упор, твёрдость
## для запросов физики, раскрутка под моментом, тормоз, серво руля.
## Фаза «на грунте» — гравитацию вернули: посадка под нагрузкой, дребезг в
## покое, проезд под полным газом.
##
## Меряется на авторских деталях специально: первые версии WHEEL-BODY-V1 были
## зелёными на сеточных и сломанными в игре — у точной детали гнездо смотрит
## вбок, вдоль оси ступицы, и вся геометрия другая.

const _HeadlessTestHarness := preload(
	"res://scripts/testing/headless_test_harness.gd"
)

const FLOOR_TOP_Y := -6.0

var _floor_body: StaticBody3D
var _world: SimulationWorld
var _projection: SimulationPhysicsProjection
var _assembly_id := 0
var _wheel_ids: Array[int] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, "WHEEL-BODY-STAND", 120.0)
	_spawn_floor()
	if not _build_rover():
		return
	if not await _phase_airborne():
		return
	if not await _phase_grounded():
		return
	print("WHEEL-BODY-STAND: PASS")
	get_tree().quit(0)


func _spawn_floor() -> void:
	_floor_body = StaticBody3D.new()
	_floor_body.name = "Floor"
	_floor_body.collision_layer = 1
	_floor_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 2.0, 400.0)
	shape.shape = box
	_floor_body.add_child(shape)
	add_child(_floor_body)
	_floor_body.global_position = Vector3(0.0, FLOOR_TOP_Y - 1.0, 0.0)


## Ровер собирается композером — тем же путём, каким его собирает игра.
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

	var intent := RoverIntent.defaults()
	if intent.wheel_archetype() == null or intent.suspension_archetype() == null:
		return _fail("нет пары «подвеска + колесо» — стенд мерить нечего")
	var composed := RoverComposer.compose(_world, intent)
	if not bool(composed.get("ok", false)):
		return _fail(
			"compose failed: %s %s"
			% [composed.get("error", ""), composed.get("failures", [])]
		)
	_assembly_id = int(composed["assembly_id"])
	for pair: Dictionary in WheelSimulationService.discover_pairs(
		_world,
		_assembly_id
	):
		if WheelSimulationService.is_complete_pair(pair):
			_wheel_ids.append(int(pair.get("wheel_element_id", 0)))
	if _wheel_ids.is_empty():
		return _fail("у собранного ровера нет рабочих пар колёс")
	for wheel_id: int in _wheel_ids:
		var power := _world.ensure_industry_element_runtime(wheel_id)
		power.machine_enabled = true
		power.powered = true
	var locomotion := _world.get_locomotion_controller(_assembly_id)
	locomotion.activate()
	locomotion.set_parking_brake(false)
	_projection.project_assembly_now(
		_assembly_id,
		_world.get_assembly_raw(_assembly_id).motion.duplicate_state()
	)
	_projection.wake_assembly_bodies(_assembly_id)
	print("STAND rover: %d колёс, деталь «%s»" % [
		_wheel_ids.size(), intent.wheel_archetype_id,
	])
	return true


## Оси должны быть теми, что задумал автор детали: ось качения горизонтальна,
## ход подвески вертикален. Ровно это ломалось, когда «вверх» брали из гнезда.
func _check_axes() -> bool:
	for wheel_id: int in _wheel_ids:
		var frame := WheelBodyProjectionUtil.wheel_frame_assembly_local(
			_world.get_element(wheel_id)
		)
		if frame.is_empty():
			return _fail("колесо %d без кадра осей" % wheel_id)
		var axle: Vector3 = frame["axle"]
		var travel_up: Vector3 = frame["up"]
		if absf(axle.dot(Vector3.UP)) > 0.01:
			return _fail(
				"ось качения %d не горизонтальна: %s" % [wheel_id, str(axle)]
			)
		if travel_up.dot(Vector3.UP) < 0.99:
			return _fail(
				"ось хода %d не вертикальна: %s" % [wheel_id, str(travel_up)]
			)
	print("STAND axes: оси качения горизонтальны, ход вертикален")
	return true


func _root_body() -> RigidBody3D:
	return _projection.get_physics_body(_assembly_id) as RigidBody3D


func _wheel_body(wheel_id: int) -> RigidBody3D:
	return _projection.get_element_projection(wheel_id).get("body") as RigidBody3D


## Шасси держим без гравитации: колёса под своим весом висят на нижнем упоре,
## а ровер не улетает вниз, пока мы меряем. Замораживать нельзя — на
## замороженном корпусе колёса вообще не тикают.
func _phase_airborne() -> bool:
	if not _check_axes():
		return false
	var root := _root_body()
	if root == null:
		return _fail("у ровера нет корневого тела")
	root.gravity_scale = 0.0
	var locomotion := _world.get_locomotion_controller(_assembly_id)
	for _i: int in range(60):
		await get_tree().physics_frame

	var probe_id := _wheel_ids[0]
	var runtime := _world.get_wheel_runtime(probe_id)
	var droop := float(runtime.get("compression_m", NAN))
	print("STAND droop: сжатие %.4f м, статус %s, угол руля в покое %.4f" % [
		droop,
		runtime.get("status", "?"),
		float(runtime.get("steering_angle_rad", 0.0)),
	])
	if not is_finite(droop) or droop > 0.02:
		return _fail("колесо должно висеть на упоре, сжатие %.4f" % droop)

	# Твёрдость и посадка резины: снизу вверх под колесом ничего нет, значит
	# первым обязано попасться тело колеса — ровно на радиусе от оси. Это тот
	# самый вопрос «колесо там, где нарисовано», только числом.
	var wheel_body := _wheel_body(probe_id)
	if wheel_body == null:
		return _fail("у колеса %d нет своего тела" % probe_id)
	var wheel_definition: WheelDefinition = (
		_world.get_element(probe_id).get_archetype().wheel_definition
	)
	var hub := wheel_body.to_global(wheel_body.center_of_mass)
	var probe_start := hub - Vector3.UP * (wheel_definition.radius_m + 0.5)
	var query := PhysicsRayQueryParameters3D.create(probe_start, hub)
	query.collision_mask = 2
	var hit := _projection.get_world_3d().direct_space_state.intersect_ray(query)
	var hit_body: Variant = hit.get("collider")
	if hit.is_empty() or hit_body != wheel_body:
		return _fail(
			"луч снизу обязан попасть в тело колеса, попал в %s"
			% ("ничто" if hit.is_empty() else str(hit_body))
		)
	var bottom_gap := hub.y - Vector3(hit["position"]).y
	print("STAND solidity: низ шины в %.3f м под осью (радиус %.3f)" % [
		bottom_gap, wheel_definition.radius_m,
	])
	if absf(bottom_gap - wheel_definition.radius_m) > 0.03:
		return _fail(
			"низ шины на %.3f м под осью, а радиус %.3f"
			% [bottom_gap, wheel_definition.radius_m]
		)

	# Раскрутка под моментом.
	locomotion.set_drive_command(1.0)
	for _i: int in range(90):
		await get_tree().physics_frame
	var spin := float(_world.get_wheel_runtime(probe_id).get("wheel_speed", 0.0))
	print("STAND spin-up: %.1f рад/с за 1.5 с" % spin)
	if absf(spin) < 5.0:
		return _fail("колесо не раскрутилось: %.2f рад/с" % spin)
	locomotion.set_drive_command(0.0)

	# Тормоз. Времени даём по инерции колеса, а не «секунду на глаз»: у шины
	# радиусом 0.75 и массой 40 кг момент инерции ~11 кг·м², и штатные 180 Н·м
	# гасят её за пару секунд.
	locomotion.set_brake_command(1.0)
	for _i: int in range(240):
		await get_tree().physics_frame
	var braked := float(
		_world.get_wheel_runtime(probe_id).get("wheel_speed", 0.0)
	)
	print("STAND brake: %.2f рад/с после 4 с тормоза" % braked)
	if absf(braked) > 1.0:
		return _fail("тормоз не остановил колесо: %.2f рад/с" % braked)
	locomotion.set_brake_command(0.0)

	# Серво руля: до упора и обратно. Управляемые колёса назначил композер.
	var steer_id := 0
	for wheel_id: int in _wheel_ids:
		if _world.ensure_wheel_instance_state(wheel_id).steerable:
			steer_id = wheel_id
			break
	if steer_id <= 0:
		return _fail("у ровера нет ни одного управляемого колеса")
	var max_steer: float = (
		_world.get_element(steer_id).get_archetype()
			.wheel_definition.max_steering_angle_rad
	)
	locomotion.set_steering_command(1.0)
	for _i: int in range(90):
		await get_tree().physics_frame
	var steer := absf(float(
		_world.get_wheel_runtime(steer_id).get("steering_angle_rad", 0.0)
	))
	print("STAND steering: %.3f рад (упор %.3f)" % [steer, max_steer])
	if steer < max_steer * 0.7:
		return _fail("серво руля дошло только до %.3f рад" % steer)
	locomotion.set_steering_command(0.0)
	for _i: int in range(90):
		await get_tree().physics_frame
	var steer_back := absf(float(
		_world.get_wheel_runtime(steer_id).get("steering_angle_rad", 0.0)
	))
	print("STAND steering return: %.3f рад" % steer_back)
	if steer_back > 0.05:
		return _fail("руль не вернулся: %.3f рад" % steer_back)
	return true


func _phase_grounded() -> bool:
	var root := _root_body()
	root.gravity_scale = 1.0
	_projection.wake_assembly_bodies(_assembly_id)
	for _i: int in range(300):
		await get_tree().physics_frame

	# Колесо стоит НА полу, а не в нём: точка контакта — радиус под осью.
	var definition: WheelDefinition = (
		_world.get_element(_wheel_ids[0]).get_archetype().wheel_definition
	)
	var grounded := 0
	var worst_sink := 0.0
	var compression_sum := 0.0
	for wheel_id: int in _wheel_ids:
		var runtime := _world.get_wheel_runtime(wheel_id)
		if bool(runtime.get("grounded", false)):
			grounded += 1
		compression_sum += float(runtime.get("compression_m", 0.0))
		var contact: Vector3 = runtime.get("contact_world", Vector3.ZERO)
		worst_sink = maxf(worst_sink, FLOOR_TOP_Y - contact.y)
	print(
		"STAND ride: на грунте %d/%d, сжатие %.4f м, глубже пола %.3f м (радиус %.2f)"
		% [
			grounded,
			_wheel_ids.size(),
			compression_sum / _wheel_ids.size(),
			worst_sink,
			definition.radius_m,
		]
	)
	if grounded < _wheel_ids.size():
		return _fail(
			"ровер сел на %d колёс из %d" % [grounded, _wheel_ids.size()]
		)
	if worst_sink > 0.05:
		return _fail("колесо утоплено в пол на %.3f м" % worst_sink)

	# Дребезг в покое.
	var jitter_accum := 0.0
	var jitter_frames := 60
	for _i: int in range(jitter_frames):
		await get_tree().physics_frame
		jitter_accum += root.linear_velocity.length_squared()
	var jitter_rms := sqrt(jitter_accum / jitter_frames)
	print("STAND jitter: скорость шасси RMS %.4f м/с" % jitter_rms)
	if jitter_rms > 0.08:
		return _fail("ровер дребезжит в покое: %.4f м/с" % jitter_rms)

	# Проезд под полным газом.
	var locomotion := _world.get_locomotion_controller(_assembly_id)
	var start := root.global_position
	locomotion.set_drive_command(1.0)
	for _i: int in range(180):
		await get_tree().physics_frame
	var travelled := root.global_position - start
	travelled.y = 0.0
	var spin_max := 0.0
	for wheel_id: int in _wheel_ids:
		spin_max = maxf(spin_max, absf(float(
			_world.get_wheel_runtime(wheel_id).get("wheel_speed", 0.0)
		)))
	locomotion.set_drive_command(0.0)
	print("STAND drive: %.3f м за 180 кадров, макс. вращение %.1f рад/с"
		% [travelled.length(), spin_max])
	if travelled.length() < 3.0:
		return _fail("проезд %.3f м < 3.0 м" % travelled.length())
	if spin_max < 1.0:
		return _fail("колёса не вращаются при движении")
	return true


func _fail(message: String) -> bool:
	push_error("test_wheel_body_stand: %s" % message)
	print("WHEEL-BODY-STAND: FAIL %s" % message)
	get_tree().quit(1)
	return false
