class_name ControlTerminalSnapshotBuilder
extends RefCounted
## Read-only снапшот сборки для терминала управления (CONTROL-ACTIONS-V0).
## По образцу VehiclePowerSnapshotBuilder: ничего не мутирует, отдаёт простой
## Dictionary. Данные без chrome — подписи/теги/иконки собирает панель
## (HudTokens), чтобы билдер оставался UI-агностичным.

const SEV_OK := "ok"
const SEV_WARN := "warn"
const SEV_FAULT := "fault"

## Причины, считающиеся отказом (красный). Всё прочее ненормальное — янтарь.
const FAULT_REASONS: Array[StringName] = [
	&"element_broken",
	&"actuator_broken",
]


static func build(world: SimulationWorld, assembly_id: int) -> Dictionary:
	if world == null:
		return failure(&"not_ready")
	if assembly_id <= 0:
		return failure(&"invalid_assembly")
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null:
		return failure(&"invalid_assembly")

	var joint_by_element := _driven_joint_by_element(world, assembly_id)
	var ordinals: Dictionary = {}
	var nodes: Array[Dictionary] = []

	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element == null:
			continue
		var node := _build_node(world, element, 0, joint_by_element)
		if not _is_listable(node):
			continue
		# Нумерация идёт только по попавшим в список — иначе в подписях дыры.
		var archetype_id := element.archetype_id
		var ordinal := int(ordinals.get(archetype_id, 0)) + 1
		ordinals[archetype_id] = ordinal
		node["ordinal"] = ordinal
		nodes.append(node)

	var alarms: Array[Dictionary] = []
	for node: Dictionary in nodes:
		if str(node["severity"]) != SEV_OK:
			alarms.append(node)
	alarms.sort_custom(_alarm_sort)

	return {
		"valid": true,
		"assembly_id": assembly_id,
		"element_count": assembly.element_ids.size(),
		"node_count": nodes.size(),
		"alarm_count": alarms.size(),
		"nodes": nodes,
		"alarms": alarms,
		"power": VehiclePowerSnapshotBuilder.build(world, assembly_id),
	}


static func failure(reason: StringName = &"invalid_assembly") -> Dictionary:
	return {
		"valid": false,
		"reason": reason,
		"assembly_id": 0,
		"node_count": 0,
		"alarm_count": 0,
		"nodes": [] as Array[Dictionary],
		"alarms": [] as Array[Dictionary],
		"power": VehiclePowerSnapshotBuilder.failure(reason),
	}


static func _build_node(
	world: SimulationWorld,
	element: SimulationElement,
	ordinal: int,
	joint_by_element: Dictionary
) -> Dictionary:
	var element_id := element.element_id
	var joint_id := int(joint_by_element.get(element_id, 0))
	var node := {
		"element_id": element_id,
		"joint_id": joint_id,
		"archetype_id": element.archetype_id,
		"custom_name": element.custom_name,
		"ordinal": ordinal,
		"category": "other",
		"value": 0.0,
		"value_kind": "none",
		"status": &"ok",
		"severity": SEV_OK,
		"kind": "other",
		"detail": {},
	}

	# Незавершённый / сломанный каркас перебивает функциональный статус.
	var construction := element.status_reason()

	if joint_id > 0:
		var joint := world.get_joint(joint_id)
		if joint != null and joint.motor != null:
			var motor := joint.motor
			node["category"] = "actuator"
			node["kind"] = _actuator_kind(joint.kind)
			node["value"] = motor.observed_position_m
			node["value_kind"] = (
				"length_m"
				if joint.kind == SimulationJoint.Kind.PISTON
				else "angle_rad"
			)
			node["status"] = ActuatorSimulationService.status_name_for_motor(motor)
			node["detail"] = {
				# `enabled` и `control_mode` нужны глаголам пульта: тумблер мотора
				# и реверс обязаны инвертировать текущее авторитетное состояние.
				"enabled": motor.enabled,
				"control_mode": int(motor.control_mode),
				"observed": motor.observed_position_m,
				"observed_velocity": motor.observed_velocity_mps,
				"target_position_m": motor.target_position_m,
				"target_velocity_mps": motor.target_velocity_mps,
				"extend_velocity_mps": motor.extend_velocity_mps,
				"retract_velocity_mps": motor.retract_velocity_mps,
				"force_limit_n": motor.force_limit_n,
				"lower_limit_m": motor.lower_limit_m,
				"upper_limit_m": motor.upper_limit_m,
				"power_draw_w": motor.power_draw_w,
			}
	else:
		node["category"] = _category_for(element)
		if WheelPlacementUtil.is_wheel_archetype(element.get_archetype()):
			node["kind"] = "wheel"
			node["category"] = "actuator"
			node["detail"] = _wheel_detail(world, element)
		elif WheelPlacementUtil.is_suspension_archetype(element.get_archetype()):
			node["kind"] = "suspension"
			node["category"] = "actuator"
			node["detail"] = _suspension_detail(world, element)
		if node["category"] == "power" and IndustryElectricProfile.is_battery(element):
			var max_kwh := IndustryElectricProfile.battery_max_kwh(element)
			if max_kwh > 0.000001:
				var runtime := world.ensure_industry_element_runtime(element_id)
				node["value"] = clampf(runtime.battery_kwh / max_kwh, 0.0, 1.0)
				node["value_kind"] = "fraction"
		node["status"] = element.industry_status_reason()

	if construction != &"ok":
		node["status"] = construction
	node["severity"] = _severity_for(StringName(node["status"]))
	return node


## `brake_torque_n_m` хранится с сентинелом −1 = «как в архетипе» — точно как у
## подвески; без резолва пульт показал бы «−1 Н·м», что бессмысленно оператору.
## Заодно тащим живую телеметрию колеса (грунт/пробуксовка/питание) вместо
## дублирования тумблеров поворотности из блока уставок ниже.
static func _wheel_detail(world: SimulationWorld, element: SimulationElement) -> Dictionary:
	var element_id := element.element_id
	var definition: WheelDefinition = element.get_archetype().wheel_definition
	var state := world.ensure_wheel_instance_state(element_id)
	var runtime := world.ensure_industry_element_runtime(element_id)
	var wheel_runtime := world.get_wheel_runtime(element_id)
	return {
		"steerable": state.steerable,
		"drive_inverted": state.drive_inverted,
		"drive_torque_scale": state.drive_torque_scale,
		"brake_torque_n_m": (
			state.brake_torque_n_m
			if state.brake_torque_n_m >= 0.0
			else (definition.brake_torque_n_m if definition != null else 0.0)
		),
		"max_brake_torque_n_m": (
			definition.brake_torque_n_m if definition != null else 0.0
		),
		"powered": runtime.machine_enabled and runtime.powered,
		"grounded": bool(wheel_runtime.get("grounded", false)),
		"slip_speed_mps": float(wheel_runtime.get("slip_speed_mps", 0.0)),
	}


## Уставки подвески хранятся с сентинелом −1 = «как в архетипе». Пульт обязан
## показывать действующее значение, иначе игрок правит от −1.00, а не от 1600.
static func _suspension_detail(
	world: SimulationWorld,
	element: SimulationElement
) -> Dictionary:
	var definition: SuspensionDefinition = (
		element.get_archetype().suspension_definition
	)
	if definition == null:
		return {}
	var state := world.ensure_suspension_instance_state(element.element_id)
	return {
		"travel_m": (
			state.travel_m
			if state.travel_m > 0.0
			else definition.suspension_travel_m
		),
		"spring_stiffness_n_per_m": (
			state.spring_stiffness_n_per_m
			if state.spring_stiffness_n_per_m >= 0.0
			else definition.spring_stiffness_n_per_m
		),
		"spring_damping_n_s_per_m": (
			state.spring_damping_n_s_per_m
			if state.spring_damping_n_s_per_m >= 0.0
			else definition.spring_damping_n_s_per_m
		),
		"min_travel_m": definition.min_travel_m,
		"max_travel_m": definition.max_travel_m,
	}


## Вид привода определяет, какие параметры и команды показывать в фейсплейте.
static func _actuator_kind(joint_kind: SimulationJoint.Kind) -> String:
	match joint_kind:
		SimulationJoint.Kind.PISTON:
			return "piston"
		SimulationJoint.Kind.ROTOR:
			return "rotor"
		SimulationJoint.Kind.HINGE:
			return "hinge"
	return "other"


static func _category_for(element: SimulationElement) -> String:
	var archetype := element.get_archetype()
	if archetype == null:
		return "other"
	var roles := archetype.roles
	if "Processor" in roles or "Fabricator" in roles or "Tool" in roles:
		return "machine"
	if "Source" in roles or "Tank" in roles:
		return "power"
	if "CargoHold" in roles:
		return "cargo"
	if "Actuator" in roles or "Support" in roles:
		return "actuator"
	return "other"


## Что показывать в пульте: управляемое (привод, машина, питание, склад) либо
## всё, что требует внимания. Несущие блоки — рама, балка, фундамент — это
## конструкция, а не узлы управления: сотня рам превращает список в шум и
## настраивать в них нечего. В отказе они всё равно всплывут.
static func _is_listable(node: Dictionary) -> bool:
	if str(node["severity"]) != SEV_OK:
		return true
	return str(node["category"]) != "other"


static func _severity_for(status: StringName) -> String:
	if status == &"ok":
		return SEV_OK
	if status in FAULT_REASONS:
		return SEV_FAULT
	return SEV_WARN


## Отказы вперёд, затем по element_id — порядок стабильный между кадрами.
static func _alarm_sort(a: Dictionary, b: Dictionary) -> bool:
	var a_fault := str(a["severity"]) == SEV_FAULT
	var b_fault := str(b["severity"]) == SEV_FAULT
	if a_fault != b_fault:
		return a_fault
	return int(a["element_id"]) < int(b["element_id"])


## Приводной joint по элементу-базе. Один элемент — не больше одного привода.
static func _driven_joint_by_element(
	world: SimulationWorld,
	assembly_id: int
) -> Dictionary:
	var map: Dictionary = {}
	for joint: SimulationJoint in world.list_joints():
		if joint == null or joint.assembly_id != assembly_id:
			continue
		if not joint.kind in SimulationJoint.DRIVEN_KINDS:
			continue
		if joint.element_a_id > 0 and not map.has(joint.element_a_id):
			map[joint.element_a_id] = joint.joint_id
	return map
