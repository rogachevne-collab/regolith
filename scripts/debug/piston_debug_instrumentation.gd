class_name PistonDebugInstrumentation
extends Node

## Runtime piston diagnostics for load / multi-piston / force-budget issues.
## See docs/cheatsheets/piston-debug-instrumentation.md

@export var enabled := true
@export var overlay_enabled := true
@export var log_to_console := false
@export var log_interval_s := 1.0
@export var log_status_changes := true
@export var session_path: NodePath
@export var player_path: NodePath
@export var focus_assembly_id := 0

var _session: SimulationSession
var _player: Node3D
var _overlay: RichTextLabel
var _log_accum := 0.0
var _last_status: Dictionary = {}
var _focus_index := 0


func _ready() -> void:
	_session = get_node_or_null(session_path) as SimulationSession
	_player = get_node_or_null(player_path) as Node3D
	if overlay_enabled:
		_build_overlay()


func _unhandled_input(event: InputEvent) -> void:
	if not enabled or not event.is_pressed() or event.is_echo():
		return
	if Input.is_action_just_pressed("piston_debug_toggle_overlay"):
		overlay_enabled = not overlay_enabled
		if _overlay != null:
			_overlay.visible = overlay_enabled
	elif Input.is_action_just_pressed("piston_debug_dump_log"):
		_dump_console_snapshot(true)
	elif Input.is_action_just_pressed("piston_debug_cycle_focus"):
		_cycle_focus_assembly()


func _physics_process(delta: float) -> void:
	if not enabled or _session == null or _session.world == null:
		return
	var snapshots := _collect_snapshots()
	_update_status_transitions(snapshots)
	if overlay_enabled and _overlay != null:
		_overlay.text = _format_overlay(snapshots)
	if log_to_console:
		_log_accum += delta
		if _log_accum >= log_interval_s:
			_log_accum = 0.0
			_dump_console_snapshot(false, snapshots)


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 12
	add_child(layer)
	_overlay = RichTextLabel.new()
	_overlay.name = "PistonDebugOverlay"
	_overlay.custom_minimum_size = Vector2(720, 420)
	_overlay.offset_left = 16.0
	_overlay.offset_top = 220.0
	_overlay.offset_right = 736.0
	_overlay.offset_bottom = 640.0
	_overlay.scroll_active = true
	_overlay.fit_content = true
	_overlay.bbcode_enabled = true
	_overlay.add_theme_color_override("default_color", Color(0.92, 0.96, 1.0, 0.95))
	_overlay.add_theme_font_size_override("normal_font_size", 14)
	layer.add_child(_overlay)


func _collect_snapshots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var world := _session.world
	var projection := _session.projection
	if projection == null:
		return out
	for assembly: SimulationAssembly in world.list_assemblies():
		if assembly == null or assembly.tombstoned:
			continue
		var assembly_id := assembly.assembly_id
		var records := projection.list_piston_constraint_records(assembly_id)
		if records.is_empty():
			continue
		var compile := world.compile_body_groups(assembly_id)
		for record: Dictionary in records:
			out.append(
				_build_snapshot(
					world,
					projection,
					assembly_id,
					record,
					records.size(),
					compile
				)
			)
	return out


func _build_snapshot(
	world: SimulationWorld,
	projection: SimulationPhysicsProjection,
	assembly_id: int,
	record: Dictionary,
	piston_count: int,
	compile: Dictionary
) -> Dictionary:
	var sim_joint: SimulationJoint = record.get("sim_joint")
	var base_body: PhysicsBody3D = record.get("base_body")
	var head_body: PhysicsBody3D = record.get("head_body")
	var joint_id := int(record.get("joint_id", 0))
	var motor := sim_joint.motor if sim_joint != null else null
	var axis_world := Vector3.UP
	if base_body != null:
		axis_world = (
			base_body.global_transform.basis
			* record.get("axis_local", Vector3.UP)
		).normalized()
	var measured := {}
	if base_body != null and head_body != null:
		measured = PistonProjectionUtil.measure_axial_state(
			base_body,
			head_body,
			record.get("base_anchor_local", Vector3.ZERO),
			record.get("head_anchor_local", Vector3.ZERO),
			axis_world
		)
	var head_mass := PistonProjectionUtil.carriage_mass_kg(
		world,
		record.get("carriage_element_ids", [])
	)
	if head_body is RigidBody3D:
		head_mass = maxf((head_body as RigidBody3D).mass, head_mass)
	var gravity := GravityField.resolve_gravity_accel(
		self,
		head_body.global_position if head_body is Node3D else Vector3.ZERO
	)
	var hold_n := PistonProjectionUtil.axial_load_hold_force_n(
		head_mass,
		axis_world,
		gravity
	)
	var powered := false
	if sim_joint != null:
		powered = PistonProjectionUtil.is_piston_powered(
			world,
			sim_joint.element_a_id
		)
	var operational := false
	var base_element := (
		world.get_element(sim_joint.element_a_id)
		if sim_joint != null
		else null
	)
	if base_element != null:
		operational = base_element.is_operational()
	var force_limit := motor.force_limit_n if motor != null else 0.0
	var applied := motor.applied_force_n if motor != null else 0.0
	var saturated := motor.force_saturated if motor != null else false
	var status := motor.status if motor != null else SimulationMotorState.Status.IDLE
	var motion_budget := force_limit
	if motor != null and motor.control_mode != SimulationMotorState.ControlMode.STOP:
		var commanded := PistonProjectionUtil.desired_axial_velocity_mps(motor)
		if commanded != 0.0:
			var motion_sign := signf(commanded)
			if motion_sign > 0.0:
				motion_budget -= maxf(hold_n, 0.0)
			else:
				motion_budget -= maxf(-hold_n, 0.0)
	var head_group_id := 0
	var base_group_id := 0
	for spec: Dictionary in compile.get("driven_specs", []):
		if int(spec.get("joint_id", 0)) != joint_id:
			continue
		head_group_id = int(spec.get("head_group_id", 0))
		base_group_id = int(spec.get("base_group_id", 0))
		break
	return {
		"assembly_id": assembly_id,
		"joint_id": joint_id,
		"extension_m": float(measured.get("extension_m", 0.0)),
		"velocity_mps": float(measured.get("relative_velocity_mps", 0.0)),
		"lower_limit_m": motor.lower_limit_m if motor != null else 0.0,
		"upper_limit_m": motor.upper_limit_m if motor != null else 0.0,
		"mass_kg": head_mass,
		"hold_n": hold_n,
		"gravity_dot_axis": gravity.dot(axis_world.normalized()),
		"force_limit_n": force_limit,
		"applied_force_n": applied,
		"force_saturated": saturated,
		"motion_budget_n": motion_budget,
		"powered": powered,
		"operational": operational,
		"status": status,
		"status_name": _status_name(status),
		"piston_count": piston_count,
		"root_group_id": int(compile.get("root_group_id", 0)),
		"compile_valid": bool(compile.get("valid", false)),
		"compile_reason": String(compile.get("reason", "")),
		"base_group_id": base_group_id,
		"head_group_id": head_group_id,
		"carriage_elements": (
			(record.get("carriage_element_ids", []) as Array).size()
		),
		"axis_world": axis_world,
	}


func _format_overlay(snapshots: Array[Dictionary]) -> String:
	if snapshots.is_empty():
		return (
			"[color=#888]Piston debug[/color]\n"
			+ "Нет поршней в projection.\n"
			+ "F10 overlay · F11 dump · F12 focus"
		)
	var focus_id := _resolve_focus_assembly_id(snapshots)
	var lines: PackedStringArray = PackedStringArray()
	lines.append(
		"[b]Piston debug[/b]  focus assembly=%d  (F12 cycle, F11 dump)"
		% focus_id
	)
	var shown := 0
	for snap: Dictionary in snapshots:
		if int(snap.get("assembly_id", 0)) != focus_id:
			continue
		shown += 1
		lines.append(_format_snapshot_line(snap, true))
	if shown == 0:
		for snap: Dictionary in snapshots:
			lines.append(_format_snapshot_line(snap, false))
	return "\n".join(lines)


func _format_snapshot_line(snap: Dictionary, highlight: bool) -> String:
	var warn := ""
	if float(snap.get("motion_budget_n", 0.0)) <= 0.0 and bool(
		snap.get("powered", false)
	):
		warn = " [color=#ff6644]NO MOTION BUDGET[/color]"
	elif bool(snap.get("force_saturated", false)):
		warn = " [color=#ffaa44]SAT[/color]"
	var compile_ok := bool(snap.get("compile_valid", false))
	var compile_tag := (
		"ok" if compile_ok else str(snap.get("compile_reason", "?"))
	)
	var prefix := "[b]" if highlight else ""
	var suffix := "[/b]" if highlight else ""
	return (
		"%sJ%d asm=%d ext=%.2f/%.2f v=%.2f m=%.0f hold=%.0f budget=%.0f/%.0f %s grp %d→%d car=%d pistons=%d root=%d compile=%s%s"
		% [
			prefix,
			int(snap.get("joint_id", 0)),
			int(snap.get("assembly_id", 0)),
			float(snap.get("extension_m", 0.0)),
			float(snap.get("upper_limit_m", 0.0)),
			float(snap.get("velocity_mps", 0.0)),
			float(snap.get("mass_kg", 0.0)),
			float(snap.get("hold_n", 0.0)),
			float(snap.get("motion_budget_n", 0.0)),
			float(snap.get("force_limit_n", 0.0)),
			str(snap.get("status_name", "?")),
			int(snap.get("base_group_id", 0)),
			int(snap.get("head_group_id", 0)),
			int(snap.get("carriage_elements", 0)),
			int(snap.get("piston_count", 0)),
			int(snap.get("root_group_id", 0)),
			compile_tag,
			suffix,
		]
		+ warn
	)


func _dump_console_snapshot(
	force: bool,
	snapshots: Array[Dictionary] = []
) -> void:
	if snapshots.is_empty():
		snapshots = _collect_snapshots()
	if snapshots.is_empty():
		print("PistonDebug: no pistons")
		return
	var focus_id := _resolve_focus_assembly_id(snapshots)
	print("PistonDebug dump focus_assembly=%d count=%d" % [focus_id, snapshots.size()])
	for snap: Dictionary in snapshots:
		if not force and int(snap.get("assembly_id", 0)) != focus_id:
			continue
		print(
			(
				"  j=%d asm=%d ext=%.3f v=%.3f m=%.1f hold=%.1f g·axis=%.3f "
				+ "F=%.0f/%.0f budget=%.0f sat=%s stat=%s pistons=%d compile=%s"
			)
			% [
				int(snap.get("joint_id", 0)),
				int(snap.get("assembly_id", 0)),
				float(snap.get("extension_m", 0.0)),
				float(snap.get("velocity_mps", 0.0)),
				float(snap.get("mass_kg", 0.0)),
				float(snap.get("hold_n", 0.0)),
				float(snap.get("gravity_dot_axis", 0.0)),
				float(snap.get("applied_force_n", 0.0)),
				float(snap.get("force_limit_n", 0.0)),
				float(snap.get("motion_budget_n", 0.0)),
				str(snap.get("force_saturated", false)),
				str(snap.get("status_name", "?")),
				int(snap.get("piston_count", 0)),
				str(snap.get("compile_reason", "ok")),
			]
		)


func _update_status_transitions(snapshots: Array[Dictionary]) -> void:
	if not log_status_changes:
		return
	for snap: Dictionary in snapshots:
		var joint_id := int(snap.get("joint_id", 0))
		var status_name := str(snap.get("status_name", ""))
		var prev: Variant = _last_status.get(joint_id)
		if prev == null:
			_last_status[joint_id] = status_name
			continue
		if str(prev) == status_name:
			continue
		_last_status[joint_id] = status_name
		print(
			(
				"PistonDebug transition j=%d asm=%d %s→%s "
				+ "hold=%.0f budget=%.0f sat=%s"
			)
			% [
				joint_id,
				int(snap.get("assembly_id", 0)),
				str(prev),
				status_name,
				float(snap.get("hold_n", 0.0)),
				float(snap.get("motion_budget_n", 0.0)),
				str(snap.get("force_saturated", false)),
			]
		)


func _resolve_focus_assembly_id(snapshots: Array[Dictionary]) -> int:
	if focus_assembly_id > 0:
		return focus_assembly_id
	var assembly_ids: Array[int] = []
	for snap: Dictionary in snapshots:
		var id := int(snap.get("assembly_id", 0))
		if id > 0 and not assembly_ids.has(id):
			assembly_ids.append(id)
	if assembly_ids.is_empty():
		return 0
	if _player == null:
		return assembly_ids[0]
	var best_id := assembly_ids[0]
	var best_dist := INF
	for id: int in assembly_ids:
		var body := _session.projection.get_physics_body(id)
		if body == null:
			continue
		var dist := _player.global_position.distance_squared_to(
			body.global_position
		)
		if dist < best_dist:
			best_dist = dist
			best_id = id
	return best_id


func _cycle_focus_assembly() -> void:
	var snapshots := _collect_snapshots()
	if snapshots.is_empty():
		return
	var assembly_ids: Array[int] = []
	for snap: Dictionary in snapshots:
		var id := int(snap.get("assembly_id", 0))
		if id > 0 and not assembly_ids.has(id):
			assembly_ids.append(id)
	if assembly_ids.is_empty():
		return
	_focus_index = (_focus_index + 1) % assembly_ids.size()
	focus_assembly_id = assembly_ids[_focus_index]
	print("PistonDebug focus assembly_id=%d" % focus_assembly_id)


static func _status_name(status: SimulationMotorState.Status) -> String:
	match status:
		SimulationMotorState.Status.IDLE:
			return "idle"
		SimulationMotorState.Status.MOVING:
			return "moving"
		SimulationMotorState.Status.JOINT_LIMIT:
			return "joint_limit"
		SimulationMotorState.Status.STUCK:
			return "stuck"
		SimulationMotorState.Status.OVERLOADED:
			return "overloaded"
		SimulationMotorState.Status.NO_POWER:
			return "no_power"
		SimulationMotorState.Status.ELEMENT_INCOMPLETE:
			return "incomplete"
	return "unknown"
