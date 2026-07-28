class_name TerminalCommandExecutor
extends RefCounted

## Gateway submit / verb execution / hold tracking for the K-пульт.
## Optimistic detail patches go through terminal._patch_selected_detail.


static func submit(terminal, command_kind: String, element_id: int, params: Dictionary) -> void:
	if terminal._gateway == null or command_kind.is_empty():
		return
	var command_id: int = terminal._gateway.call("submit", {
		"kind": StringName(command_kind),
		"source": terminal,
		"target": {
			"valid": true,
			"target_kind": InteractionHit.KIND_SIMULATION_ELEMENT,
			"element_id": element_id,
		},
		"parameters": params,
	})
	terminal._pending_commands[command_id] = true


## Диагностика без логов (спека §Диагностика): отказ команды пульта выводится
## причиной в статус-баре, а не молчит. Успех ничего не пишет.
static func on_command_completed(terminal, command_id: int, result: Dictionary) -> void:
	if not terminal._pending_commands.erase(command_id):
		return
	var reason := StringName(result.get("reason", &"ok"))
	if reason == &"ok":
		return
	terminal._fault_text = HudTokens.status_label(reason).to_lower()
	terminal._fault_left = terminal.FAULT_HOLD_S
	TerminalCommandExecutor.update_fault_cell(terminal)


static func update_fault_cell(terminal) -> void:
	if terminal._fault_cell == null:
		return
	terminal._fault_cell.text = terminal._fault_text
	terminal._fault_cell.visible = not terminal._fault_text.is_empty()


static func submit_param(
	terminal,
	param_id: String,
	value: float,
	element_id: int,
	joint_id: int
) -> void:
	var entry := GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return
	var command_kind := str(entry.get("command", ""))
	var params := {str(entry.get("field", "")): value}
	match str(entry.get("target", "element")):
		"joint":
			params["joint_id"] = joint_id
		_:
			if command_kind == "configure_wheel":
				params["wheel_element_id"] = element_id
			else:
				params["suspension_element_id"] = element_id
	TerminalCommandExecutor.submit(terminal, command_kind, element_id, params)


## Часть уставок клампится не постоянным диапазоном каталога, а фактическим
## паспортом конкретного узла (предел хода этой подвески, тормозной момент
## этой модели колеса) — каталог даёт разумный дефолт, живой снапшот, если
## несёт точные границы этого экземпляра, их переопределяет. Без этого шаг
## либо упирался бы в чужой лимит раньше времени, либо разрешал то, что
## authoritative-сторона всё равно отклонит.
static func effective_bounds(param_id: String, detail: Dictionary, entry: Dictionary) -> Vector2:
	var lo := float(entry.get("soft_min", 0.0))
	var hi := float(entry.get("soft_max", 1.0))
	match param_id:
		"suspension.travel":
			lo = float(detail.get("min_travel_m", lo))
			hi = float(detail.get("max_travel_m", hi))
		"wheel.brake_torque":
			hi = float(detail.get("max_brake_torque_n_m", hi))
		"wheel.steering_angle":
			hi = float(detail.get("authored_max_steering_angle_rad", hi))
	return Vector2(lo, hi)


## Клик по «−»/«+»: шаг из каталога от текущего живого значения, кламп по
## soft-диапазону. Авторитетный кламп всё равно за симуляцией.
static func apply_param_step(terminal, param_id: String, direction: int) -> void:
	var entry := GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return
	var node: Dictionary = terminal._selected_node()
	var detail: Dictionary = node.get("detail", {})
	var field := str(entry.get("field", ""))
	var bounds: Vector2 = TerminalCommandExecutor.effective_bounds(param_id, detail, entry)
	var value := clampf(
		float(detail.get(field, 0.0)) + float(entry.get("step", 0.0)) * direction,
		bounds.x,
		bounds.y
	)
	TerminalCommandExecutor.submit_param(
		terminal,
		param_id,
		value,
		int(node.get("element_id", 0)),
		int(node.get("joint_id", 0))
	)
	if not field.is_empty():
		terminal._patch_selected_detail({field: value})


## Живое состояние цели из последнего снапшота. Инверсия тумблера и
## относительный шаг обязаны считаться от того, что сейчас в симуляции, а не от
## того, что запомнил слот при привязке.
static func live_detail(terminal, element_id: int, joint_id: int) -> Dictionary:
	for node_variant: Variant in terminal._nodes:
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		var matches := (
			(joint_id > 0 and int(node.get("joint_id", 0)) == joint_id)
			or (joint_id <= 0 and int(node.get("element_id", -1)) == element_id)
		)
		if matches:
			var detail: Variant = node.get("detail", {})
			return detail if detail is Dictionary else {}
	return {}


## Seat route flags for toggle invert. Closed compact bar has empty `_nodes` —
## read InteractionCard / authoritative SeatControlState, never assume default
## true (that would make OFF→ON stick and never toggle OFF).
static func seat_route_flag(terminal, element_id: int, key: String) -> bool:
	var detail: Dictionary = TerminalCommandExecutor.live_detail(terminal, element_id, 0)
	if detail.has(key):
		return bool(detail[key])
	if terminal._gateway != null and terminal._gateway.has_method("get_world"):
		var world: SimulationWorld = terminal._gateway.call("get_world") as SimulationWorld
		if world != null:
			var card := world.get_interaction_card(element_id)
			if card != null and card.keys.has(key):
				return bool(card.keys[key])
			return SeatControlState.flag_of(
				world.get_seat_control_state_ref(element_id),
				key
			)
	return true


static func is_momentary(terminal, action_id: String) -> bool:
	return action_id in terminal.MOMENTARY_ACTIONS


## Вид узла для глагола: у ротора цель — скорость, у поршня/шарнира — позиция.
static func spec_kind(spec: Dictionary) -> String:
	var kind := str(spec.get("node_kind", ""))
	if not kind.is_empty():
		return kind
	return str(spec.get("action_id", "")).split(".")[0]


## Единственный исполнитель глаголов: и клавиша пульта, и кнопка в фейсплейте
## идут сюда. `pressed=false` приходит на отпускании — только для «удерж».
## Пульт ничего не мутирует сам: собирает существующую команду гейтвея.
static func run_action(terminal, spec: Dictionary, pressed: bool) -> void:
	if terminal._gateway == null or spec.is_empty():
		return
	var action := str(spec.get("action_id", ""))
	if action.is_empty():
		return
	var element_id := int(spec.get("element_id", 0))
	var joint_id := int(spec.get("joint_id", 0))
	if not pressed:
		if TerminalCommandExecutor.is_momentary(terminal, action):
			TerminalCommandExecutor.submit(terminal, "set_actuator_target", element_id, {
				"joint_id": joint_id,
				"mode": SimulationMotorState.ControlMode.STOP,
			})
		return
	if action.begins_with("param."):
		TerminalCommandExecutor.run_param_action(terminal, spec, element_id, joint_id)
		return
	match action:
		"wheel.steerable_toggle":
			var next_steerable: bool = not bool(
				TerminalCommandExecutor.live_detail(terminal, element_id, 0).get(
					"steerable", false
				)
			)
			TerminalCommandExecutor.submit(terminal, "configure_wheel", element_id, {
				"wheel_element_id": element_id,
				"steerable": next_steerable,
			})
			terminal._patch_selected_detail({"steerable": next_steerable})
		"wheel.invert_drive_toggle":
			var next_invert: bool = not bool(
				TerminalCommandExecutor.live_detail(terminal, element_id, 0).get(
					"drive_inverted", false
				)
			)
			TerminalCommandExecutor.submit(terminal, "configure_wheel", element_id, {
				"wheel_element_id": element_id,
				"invert_drive": next_invert,
			})
			terminal._patch_selected_detail({"drive_inverted": next_invert})
		"seat.control_wheels_toggle":
			var next_wheels: bool = not TerminalCommandExecutor.seat_route_flag(
				terminal, element_id, "control_wheels"
			)
			TerminalCommandExecutor.submit(terminal, "configure_seat_controls", element_id, {
				"seat_element_id": element_id,
				"control_wheels": next_wheels,
			})
			terminal._patch_selected_detail({"control_wheels": next_wheels})
		"seat.control_thrusters_toggle":
			var next_thrusters: bool = not TerminalCommandExecutor.seat_route_flag(
				terminal, element_id, "control_thrusters"
			)
			TerminalCommandExecutor.submit(terminal, "configure_seat_controls", element_id, {
				"seat_element_id": element_id,
				"control_thrusters": next_thrusters,
			})
			terminal._patch_selected_detail({"control_thrusters": next_thrusters})
		"seat.control_gyros_toggle":
			var next_gyros: bool = not TerminalCommandExecutor.seat_route_flag(
				terminal, element_id, "control_gyros"
			)
			TerminalCommandExecutor.submit(terminal, "configure_seat_controls", element_id, {
				"seat_element_id": element_id,
				"control_gyros": next_gyros,
			})
			terminal._patch_selected_detail({"control_gyros": next_gyros})
		"machine.toggle", "machine.enable", "machine.disable":
			var enabled_now := bool(
				TerminalCommandExecutor.live_detail(terminal, element_id, 0).get(
					"machine_enabled", true
				)
			)
			var next_enabled := enabled_now
			if action == "machine.toggle":
				next_enabled = not enabled_now
			elif action == "machine.enable":
				next_enabled = true
			else:
				next_enabled = false
			TerminalCommandExecutor.submit(terminal, "set_machine_enabled", element_id, {
				"element_id": element_id,
				"enabled": next_enabled,
			})
			terminal._patch_selected_detail({"machine_enabled": next_enabled})
		"actuator.stop":
			TerminalCommandExecutor.submit(terminal, "set_actuator_target", element_id, {
				"joint_id": joint_id,
				"mode": SimulationMotorState.ControlMode.STOP,
			})
		"actuator.motor_toggle":
			# Мотор включается/выключается только через set_actuator_target:
			# у configure_actuator поля `enabled` нет.
			TerminalCommandExecutor.submit(terminal, "set_actuator_target", element_id, {
				"joint_id": joint_id,
				"mode": SimulationMotorState.ControlMode.STOP,
				"enabled": not bool(
					TerminalCommandExecutor.live_detail(terminal, element_id, joint_id).get(
						"enabled", true
					)
				),
			})
		"actuator.reverse":
			TerminalCommandExecutor.submit(
				terminal,
				"set_actuator_target",
				element_id,
				TerminalCommandExecutor.reverse_params(terminal, spec, element_id, joint_id)
			)
		"piston.extend", "hinge.extend", "rotor.spin_cw":
			TerminalCommandExecutor.submit(
				terminal,
				"set_actuator_target",
				element_id,
				TerminalCommandExecutor.drive_params(terminal, spec, element_id, joint_id, true)
			)
		"piston.retract", "hinge.retract", "rotor.spin_ccw":
			TerminalCommandExecutor.submit(
				terminal,
				"set_actuator_target",
				element_id,
				TerminalCommandExecutor.drive_params(terminal, spec, element_id, joint_id, false)
			)


## `param.set` пишет абсолютное значение, `increase/decrease` — относительный
## шаг от живого значения с клампом по soft-диапазону каталога.
static func run_param_action(
	terminal,
	spec: Dictionary,
	element_id: int,
	joint_id: int
) -> void:
	var param_id := str(spec.get("param_id", ""))
	var entry := GameBalance.parameter_entry(param_id)
	if entry.is_empty():
		return
	var action := str(spec.get("action_id", ""))
	var value := float(spec.get("value", 0.0))
	if action != "param.set":
		var detail: Dictionary = TerminalCommandExecutor.live_detail(
			terminal, element_id, joint_id
		)
		var delta := float(spec.get("delta", 0.0))
		if action == "param.decrease":
			delta = -delta
		var field := str(entry.get("field", ""))
		var bounds: Vector2 = TerminalCommandExecutor.effective_bounds(param_id, detail, entry)
		value = clampf(
			float(detail.get(field, 0.0)) + delta,
			bounds.x,
			bounds.y
		)
	TerminalCommandExecutor.submit_param(terminal, param_id, value, element_id, joint_id)


## Поршень/шарнир идут на предел хода, ротор — на скорость: у него ход не задан.
static func drive_params(
	terminal,
	spec: Dictionary,
	element_id: int,
	joint_id: int,
	forward: bool
) -> Dictionary:
	var detail: Dictionary = TerminalCommandExecutor.live_detail(
		terminal, element_id, joint_id
	)
	if TerminalCommandExecutor.spec_kind(spec) == "rotor":
		var speed := float(detail.get(
			"extend_velocity_mps" if forward else "retract_velocity_mps",
			0.0
		))
		return {
			"joint_id": joint_id,
			"mode": SimulationMotorState.ControlMode.VELOCITY,
			"target_velocity_mps": speed if forward else -speed,
		}
	return {
		"joint_id": joint_id,
		"mode": SimulationMotorState.ControlMode.POSITION,
		"target_position_m": float(detail.get(
			"upper_limit_m" if forward else "lower_limit_m",
			0.0
		)),
	}


## Зеркало текущей цели (спека: «reverse читает текущий mode/target и шлёт
## зеркальный»). Ротор — знак скорости, поршень/шарнир — дальний предел хода.
static func reverse_params(
	terminal,
	spec: Dictionary,
	element_id: int,
	joint_id: int
) -> Dictionary:
	var detail: Dictionary = TerminalCommandExecutor.live_detail(
		terminal, element_id, joint_id
	)
	if TerminalCommandExecutor.spec_kind(spec) == "rotor":
		var velocity := float(detail.get("target_velocity_mps", 0.0))
		if absf(velocity) < 0.000001:
			velocity = float(detail.get("observed_velocity", 0.0))
		if absf(velocity) < 0.000001:
			velocity = float(detail.get("extend_velocity_mps", 0.0))
		return {
			"joint_id": joint_id,
			"mode": SimulationMotorState.ControlMode.VELOCITY,
			"target_velocity_mps": -velocity,
		}
	var lower := float(detail.get("lower_limit_m", 0.0))
	var upper := float(detail.get("upper_limit_m", 0.0))
	var target := float(detail.get("target_position_m", 0.0))
	var to_lower := absf(target - lower) > absf(target - upper)
	return {
		"joint_id": joint_id,
		"mode": SimulationMotorState.ControlMode.POSITION,
		"target_position_m": lower if to_lower else upper,
	}


# ---------- удержание ----------

## Нажатие «удерж» регистрируется здесь, чтобы отпускание нашлось даже когда
## событие до окна не дошло: курсор ушёл с кнопки, начался drag, окно закрылось.
## Иначе поршень уезжает в предел и остаётся там.
static func begin_hold(terminal, source: String, spec: Dictionary) -> void:
	if TerminalCommandExecutor.is_momentary(terminal, str(spec.get("action_id", ""))):
		terminal._held[source] = spec.duplicate(true)


static func release_stale_holds(terminal) -> void:
	for source: Variant in terminal._held.keys():
		var key := str(source)
		var alive := false
		if key == "mouse":
			alive = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		elif key.begins_with("slot:"):
			# Не гейтуем на _open: тот же хоткей держит слот и через окно
			# (открыто), и через компактную ленту (окно закрыто, сидя) —
			# живо, пока физически зажата клавиша, а не пока видно окно.
			var index := int(key.substr(5))
			alive = (
				index >= 0
				and index < terminal.SLOT_ACTIONS.size()
				and Input.is_action_pressed(terminal.SLOT_ACTIONS[index])
			)
		if not alive:
			var spec: Dictionary = terminal._held[key]
			terminal._held.erase(key)
			TerminalCommandExecutor.run_action(terminal, spec, false)


static func release_holds(terminal) -> void:
	for source: Variant in terminal._held.keys():
		var spec: Dictionary = terminal._held[source]
		terminal._held.erase(source)
		TerminalCommandExecutor.run_action(terminal, spec, false)
