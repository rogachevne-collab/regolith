class_name TerminalSnapshotController
extends RefCounted

## Цикл обновления снапшотов K-пульта: опрос gateway, dirty-сигнатуры,
## точечный live-patch выбранного узла. Отрисовка остаётся на терминале-view.

## Обновление живых значений — 10 Гц (окно модальное, чаще не нужно).
const REFRESH_S := 0.1
## Полный snapshot/list audit: ловит аварии без topology bump (Phase 3).
const FULL_AUDIT_S := 1.0


static func advance_and_refresh(terminal, delta: float) -> void:
	terminal._refresh_left = maxf(terminal._refresh_left - delta, 0.0)
	terminal._full_audit_left = maxf(terminal._full_audit_left - delta, 0.0)
	if terminal._refresh_left > 0.0:
		return
	terminal._refresh_left = REFRESH_S
	TerminalSnapshotController.refresh(terminal)


## Живые данные: сидя — своя сборка, иначе — сборка наведённого элемента.
## Без гейтвея (изолированная сцена вёрстки) остаются mock-данные.
static func refresh(terminal) -> void:
	if terminal._gateway == null or not terminal._gateway.has_method("control_terminal_snapshot"):
		return
	# Пока тащат (drag-drop или протяг ползунка) или зажат клик по
	# тумблеру/степперу — не перестраиваем: иначе источник/контрол уйдёт в
	# queue_free до отпускания и `_on_click` (огонь на release) не сработает.
	# Если контрол всё же умер, а флаг остался — снимаем по состоянию ЛКМ.
	if terminal._faceplate_press_active and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		terminal._faceplate_press_active = false
	if (
		terminal.get_viewport().gui_is_dragging()
		or terminal._slider_drag_active
		or terminal._faceplate_press_active
	):
		return
	# Закрытое окно кормит только компактную ленту — берём дешёвый bar-only
	# снапшот (хост + привязки), а не полный обход сборки/тревог/энергоблока на
	# ~16 мс. Полный снапшот строим лишь когда окно открыто и его видно.
	if not terminal._open:
		TerminalSnapshotController.refresh_bar_closed(terminal)
		return
	TerminalSnapshotController.refresh_open(terminal)


static func snapshot_host_hint(terminal) -> int:
	return ControlTerminalSnapshotBuilder.host_hint_for_refresh(
		terminal._pinned_host_element_id,
		terminal._aimed_element_id()
	)


static func refresh_bar_closed(terminal) -> void:
	if not terminal._gateway.has_method("control_terminal_bar_snapshot"):
		return
	var bar_snap: Dictionary = terminal._gateway.call(
		"control_terminal_bar_snapshot",
		terminal._target_assembly,
		TerminalSnapshotController.snapshot_host_hint(terminal)
	)
	if not bool(bar_snap.get("valid", false)):
		terminal._set_target_assembly(0)
		terminal._apply_bar_snapshot(0, [])
		terminal._last_bar_sig = ""
		return
	if terminal._target_assembly <= 0:
		terminal._set_target_assembly(int(bar_snap.get("assembly_id", 0)))
	var host_id: int = int(bar_snap.get("control_seat_element_id", 0))
	var closed_bar: Dictionary = bar_snap.get("action_bar", {})
	var pages: Array = closed_bar.get("pages", [])
	var bar_sig: String = "%d|%d" % [host_id, hash(pages)]
	if bar_sig == terminal._last_bar_sig:
		return
	terminal._last_bar_sig = bar_sig
	terminal._apply_bar_snapshot(host_id, pages)


## Phase 3: полный snapshot+list rebuild только при structural dirty / audit;
## иначе — O(1) live выбранного узла + power.
static func refresh_open(terminal) -> void:
	var world: SimulationWorld = null
	if terminal._gateway.has_method("get_world"):
		world = terminal._gateway.call("get_world") as SimulationWorld
	var assembly_id: int = terminal._target_assembly
	if assembly_id <= 0:
		assembly_id = TerminalSnapshotController.assembly_id_from_aim(terminal)
	var structure_key: String = TerminalSnapshotController.open_structure_key(
		terminal, world, assembly_id
	)
	var need_full: bool = (
		structure_key != terminal._last_structure_key
		or terminal._full_audit_left <= 0.0
		or terminal._nodes.is_empty()
	)
	if not need_full:
		TerminalSnapshotController.refresh_open_live_only(
			terminal, world, assembly_id
		)
		return
	terminal._full_audit_left = FULL_AUDIT_S
	terminal._last_structure_key = structure_key
	var snap: Dictionary = terminal._gateway.call(
		"control_terminal_snapshot",
		terminal._target_assembly,
		TerminalSnapshotController.snapshot_host_hint(terminal)
	)
	if not bool(snap.get("valid", false)):
		# Keep pin / host while open — look-away must not wipe the terminal.
		terminal._fill_unit(snap)
		terminal._fill_nodes([])
		terminal._fill_alarms([])
		terminal._last_structure_sig = ""
		terminal._last_live_sig = ""
		terminal._last_structure_key = ""
		return
	if terminal._target_assembly <= 0:
		terminal._set_target_assembly(int(snap.get("assembly_id", 0)))
	var host_id: int = int(snap.get("control_seat_element_id", 0))
	if terminal._open and host_id > 0:
		terminal._pinned_host_element_id = host_id
	var bar: Dictionary = snap.get("action_bar", {})
	terminal._apply_bar_snapshot(host_id, bar.get("pages", []))
	terminal._fill_unit(snap)
	var nodes: Array = snap.get("nodes", [])
	var alarms: Array = snap.get("alarms", [])
	var structure_sig: String = TerminalSnapshotController.structure_sig_from_lists(
		nodes, alarms
	)
	var live_sig: String = TerminalSnapshotController.live_sig_from_snap(
		terminal, snap, nodes
	)
	if structure_sig != terminal._last_structure_sig:
		terminal._fill_nodes(nodes)
		terminal._fill_alarms(alarms)
		terminal._last_structure_sig = structure_sig
	else:
		# Список тот же — только данные + фейсплейт при live change.
		terminal._nodes = nodes
		if live_sig != terminal._last_live_sig:
			terminal._fill_faceplate()
	terminal._last_live_sig = live_sig


static func refresh_open_live_only(
	terminal,
	world: SimulationWorld,
	assembly_id: int
) -> void:
	if world == null or assembly_id <= 0:
		return
	var power: Dictionary = VehiclePowerSnapshotBuilder.build(world, assembly_id)
	terminal._fill_unit({
		"valid": true,
		"assembly_id": assembly_id,
		"element_count": (
			world.get_assembly_raw(assembly_id).element_ids.size()
			if world.get_assembly_raw(assembly_id) != null
			else 0
		),
		"power": power,
	})
	if terminal._selected_element_id <= 0:
		return
	if not TerminalSnapshotController.patch_selected_node_live(terminal, world):
		return
	var live_sig: String = TerminalSnapshotController.live_sig_from_node(
		terminal, terminal._selected_node(), power
	)
	if live_sig == terminal._last_live_sig:
		return
	terminal._last_live_sig = live_sig
	terminal._fill_faceplate()


static func open_structure_key(
	terminal,
	world: SimulationWorld,
	assembly_id: int
) -> String:
	var topo: int = 0
	if world != null and assembly_id > 0:
		var assembly: Variant = world.get_assembly_raw(assembly_id)
		if assembly != null:
			topo = assembly.topology_revision
	return "%d|%d|%d|%s|%s" % [
		assembly_id,
		topo,
		terminal._host_element_id,
		terminal._filter,
		terminal._search,
	]


static func assembly_id_from_aim(terminal) -> int:
	var hint: int = terminal._aimed_element_id()
	if hint <= 0 or terminal._gateway == null or not terminal._gateway.has_method("get_world"):
		return 0
	var world: SimulationWorld = terminal._gateway.call("get_world") as SimulationWorld
	if world == null:
		return 0
	var element: Variant = world.get_element(hint)
	return element.assembly_id if element != null else 0


static func structure_sig_from_lists(nodes: Array, alarms: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for node_variant: Variant in nodes:
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		parts.append(
			"%d:%s:%s:%s" % [
				int(node.get("element_id", 0)),
				str(node.get("archetype_id", "")),
				str(node.get("severity", "")),
				str(node.get("status", "")),
			]
		)
	parts.append("a%d" % alarms.size())
	for alarm_variant: Variant in alarms:
		if not alarm_variant is Dictionary:
			continue
		var alarm: Dictionary = alarm_variant
		parts.append(
			"A%d:%s" % [
				int(alarm.get("element_id", 0)),
				str(alarm.get("status", "")),
			]
		)
	return "|".join(parts)


static func live_sig_from_snap(
	terminal,
	snap: Dictionary,
	nodes: Array
) -> String:
	var power: Dictionary = snap.get("power", {})
	var selected: Dictionary = {}
	for node_variant: Variant in nodes:
		if not node_variant is Dictionary:
			continue
		var node: Dictionary = node_variant
		if int(node.get("element_id", -1)) == terminal._selected_element_id:
			selected = node
			break
	return TerminalSnapshotController.live_sig_from_node(terminal, selected, power)


static func live_sig_from_node(
	terminal,
	node: Dictionary,
	power: Dictionary
) -> String:
	var detail: Dictionary = node.get("detail", {}) if not node.is_empty() else {}
	# Дискретные уставки/тумблеры обязаны быть в сигнатуре: иначе submit
	# меняет мир, а фейсплейт продолжает рисовать старый detail.
	return "%d|%s|%.4f|%s|%s|%s|%s|%s|%s|%s|%.3f|%.3f|%.3f|%.3f|%s" % [
		terminal._selected_element_id,
		str(node.get("status", "")),
		float(node.get("value", 0.0)),
		str(detail.get("enabled", "")),
		str(detail.get("control_wheels", "")),
		str(detail.get("control_thrusters", "")),
		str(detail.get("control_gyros", "")),
		str(detail.get("steerable", "")),
		str(detail.get("drive_inverted", "")),
		str(detail.get("machine_enabled", "")),
		float(detail.get("drive_torque_scale", 0.0)),
		float(detail.get("brake_torque_n_m", 0.0)),
		float(detail.get("grip_scale", 0.0)),
		float(detail.get("max_steering_angle_rad", 0.0)),
		str(power.get("powered", "")),
	]


static func patch_selected_node_live(terminal, world: SimulationWorld) -> bool:
	var element: Variant = world.get_element(terminal._selected_element_id)
	if element == null:
		return false
	var card: Variant = world.get_interaction_card(terminal._selected_element_id)
	if card == null:
		return false
	for i: int in range(terminal._nodes.size()):
		if not terminal._nodes[i] is Dictionary:
			continue
		var node: Dictionary = terminal._nodes[i]
		if int(node.get("element_id", -1)) != terminal._selected_element_id:
			continue
		node["status"] = card.keys.get(
			"actuator_status",
			card.keys.get("status_reason", node.get("status", &"ok"))
		)
		node["severity"] = (
			"ok"
			if StringName(node["status"]) in [&"ok", &"idle", &"standby", &"moving"]
			else str(node.get("severity", "warn"))
		)
		if card.keys.has("piston_observed_position_m"):
			node["value"] = float(card.keys["piston_observed_position_m"])
		elif card.keys.has("rotor_observed_angle_rad"):
			node["value"] = float(card.keys["rotor_observed_angle_rad"])
		elif card.keys.has("hinge_observed_angle_rad"):
			node["value"] = float(card.keys["hinge_observed_angle_rad"])
		var detail: Dictionary = node.get("detail", {})
		if detail is Dictionary:
			if card.keys.has("piston_motor_enabled"):
				detail["enabled"] = bool(card.keys["piston_motor_enabled"])
			elif card.keys.has("rotor_motor_enabled"):
				detail["enabled"] = bool(card.keys["rotor_motor_enabled"])
			elif card.keys.has("hinge_motor_enabled"):
				detail["enabled"] = bool(card.keys["hinge_motor_enabled"])
			if card.keys.has("control_wheels"):
				detail["control_wheels"] = bool(card.keys["control_wheels"])
			if card.keys.has("control_thrusters"):
				detail["control_thrusters"] = bool(card.keys["control_thrusters"])
			if card.keys.has("control_gyros"):
				detail["control_gyros"] = bool(card.keys["control_gyros"])
			# Колесо: interaction card несёт wheel_steerable, а фейсплейт читает
			# detail.steerable — без синка тумблеры «нажимаются», но картинка
			# остаётся старой. Берём authoritative WheelInstanceState.
			var archetype: Variant = element.get_archetype()
			if (
				archetype != null
				and WheelPlacementUtil.is_wheel_archetype(archetype)
			):
				var wheel_state: WheelInstanceState = world.ensure_wheel_instance_state(
					terminal._selected_element_id
				)
				detail["steerable"] = wheel_state.steerable
				detail["drive_inverted"] = wheel_state.drive_inverted
				detail["drive_torque_scale"] = wheel_state.drive_torque_scale
				detail["grip_scale"] = wheel_state.grip_scale
				if wheel_state.brake_torque_n_m >= 0.0:
					detail["brake_torque_n_m"] = wheel_state.brake_torque_n_m
				if wheel_state.max_steering_angle_rad >= 0.0:
					detail["max_steering_angle_rad"] = (
						wheel_state.max_steering_angle_rad
					)
			var joint_id: int = int(node.get("joint_id", 0))
			if joint_id > 0:
				var joint: Variant = world.get_joint(joint_id)
				if joint != null and joint.motor != null:
					detail["observed"] = joint.motor.observed_position_m
					detail["observed_velocity"] = joint.motor.observed_velocity_mps
					detail["target_position_m"] = joint.motor.target_position_m
					detail["power_draw_w"] = joint.motor.power_draw_w
			node["detail"] = detail
		terminal._nodes[i] = node
		return true
	return false
