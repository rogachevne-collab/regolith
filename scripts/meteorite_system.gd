extends Node
## Occasional meteorite falls on the moon + debug near-player spawn.
## Contract: docs/specs/METEORITES-V0.md

const _IMPACT_VFX := preload("res://scenes/vfx/kinetic_impact_burst.tscn")

@export_group("Meteorites")
@export var enabled := true
@export_range(10.0, 3600.0, 1.0, "or_greater") var min_interval_s := 180.0
@export_range(10.0, 7200.0, 1.0, "or_greater") var max_interval_s := 480.0
@export_range(5.0, 500.0, 1.0, "or_greater") var spawn_offset_min_m := 40.0
@export_range(5.0, 800.0, 1.0, "or_greater") var spawn_offset_max_m := 120.0
@export_range(20.0, 600.0, 1.0, "or_greater") var spawn_height_m := 140.0
@export_range(5.0, 200.0, 0.5, "or_greater") var impact_speed_m_s := 55.0
@export_range(0.2, 8.0, 0.1, "or_greater") var meteor_radius_m := 1.2
@export_range(10.0, 20000.0, 1.0, "or_greater") var meteor_mass_kg := 600.0
@export_range(0.4, 20.0, 0.1, "or_greater") var crater_radius_m := 3.2
@export_range(0.05, 1.0, 0.05) var crater_sdf_scale := 1.0
@export_range(1.0, 500.0, 1.0, "or_greater") var volume_budget_m3 := 80.0
@export_range(1, 8) var max_active := 1
@export_range(5.0, 120.0, 1.0, "or_greater") var lifetime_s := 25.0
@export var damage_player := true
@export_range(1.0, 100.0, 0.5, "or_greater") var player_damage := 28.0

@export_group("Debug")
@export var debug_spawn_enabled := true
@export var show_debug_button := true
@export_range(4.0, 80.0, 0.5, "or_greater") var debug_offset_m := 18.0
@export_range(15.0, 200.0, 1.0, "or_greater") var debug_spawn_height_m := 48.0

@export_group("Paths")
@export var bootstrap_path: NodePath = NodePath("..")
@export var gateway_path: NodePath = NodePath("../WorldCommandGateway")
@export var player_path: NodePath = NodePath("../Player")
@export var terrain_path: NodePath = NodePath("../VoxelTerrain")
@export var gravity_field_path: NodePath = NodePath("../GravityField")
@export var canvas_layer_path: NodePath = NodePath("../CanvasLayer")

var _bootstrap: Node
var _gateway: Node
var _player: Node3D
var _terrain: Node3D
var _gravity: GravityField
var _canvas: CanvasLayer
var _rng := RandomNumberGenerator.new()
var _countdown_s := -1.0
var _active: Array[RigidBody3D] = []
var _debug_button: Button
var _world_ready_seen := false


func _ready() -> void:
	_rng.randomize()
	_bootstrap = get_node_or_null(bootstrap_path)
	_gateway = get_node_or_null(gateway_path)
	_player = get_node_or_null(player_path) as Node3D
	_terrain = get_node_or_null(terrain_path) as Node3D
	_gravity = get_node_or_null(gravity_field_path) as GravityField
	_canvas = get_node_or_null(canvas_layer_path) as CanvasLayer
	_setup_debug_button()
	_register_console_command()
	_schedule_next()


func _exit_tree() -> void:
	if LimboConsole != null and LimboConsole.has_method("unregister_command"):
		LimboConsole.unregister_command("meteor")


func _process(delta: float) -> void:
	_prune_active()
	if not _is_world_ready():
		return
	if not _world_ready_seen:
		_world_ready_seen = true
		_schedule_next()
	if not enabled:
		return
	if _countdown_s < 0.0:
		_schedule_next()
		return
	_countdown_s -= delta
	if _countdown_s > 0.0:
		return
	if _active.size() >= max_active:
		_countdown_s = 1.0
		return
	spawn_near_player(false)
	_schedule_next()


func _physics_process(_delta: float) -> void:
	## Backup when RigidBody contact_monitor misses streaming voxel colliders.
	for body in _active:
		if body == null or not is_instance_valid(body):
			continue
		if body.has_meta("meteorite_spent"):
			continue
		_try_raycast_impact(body)


func _unhandled_input(event: InputEvent) -> void:
	if not debug_spawn_enabled:
		return
	if event.is_action_pressed("debug_spawn_meteor"):
		debug_spawn_near_player()
		get_viewport().set_input_as_handled()


func debug_spawn_near_player() -> void:
	if not debug_spawn_enabled:
		return
	if not _is_world_ready():
		push_warning("MeteoriteSystem: world not ready")
		return
	spawn_near_player(true)


func spawn_near_player(debug_near: bool) -> RigidBody3D:
	if _player == null or _gateway == null or _terrain == null:
		push_warning("MeteoriteSystem: missing refs")
		return null
	if _active.size() >= max_active and not debug_near:
		return null
	var player_pos := _player.global_position
	var up := _up_at(player_pos)
	var offset_m := debug_offset_m if debug_near else _rng.randf_range(
		minf(spawn_offset_min_m, spawn_offset_max_m),
		maxf(spawn_offset_min_m, spawn_offset_max_m)
	)
	var tangent := (
		_forward_tangent(up) if debug_near else _random_tangent(up)
	)
	var aim := player_pos + tangent * offset_m
	var surface := _probe_surface(aim)
	if not _is_finite_vec3(surface):
		surface = MoonGeometry.surface_point(aim)
	var height := debug_spawn_height_m if debug_near else spawn_height_m
	var spawn_pos := surface + up * height
	var velocity := -up * impact_speed_m_s
	var meteor := _make_meteor()
	var host := get_parent()
	if host == null:
		host = self
	host.add_child(meteor)
	meteor.global_position = spawn_pos
	meteor.linear_velocity = velocity
	meteor.angular_velocity = Vector3(
		_rng.randf_range(-2.0, 2.0),
		_rng.randf_range(-2.0, 2.0),
		_rng.randf_range(-1.5, 1.5)
	)
	_active.append(meteor)
	print(
		"MeteoriteSystem: spawn debug=%s pos=%s vel=%s offset=%.1f"
		% [debug_near, spawn_pos, velocity, offset_m]
	)
	get_tree().create_timer(lifetime_s).timeout.connect(
		func() -> void:
			if is_instance_valid(meteor):
				meteor.queue_free()
	)
	return meteor


func _schedule_next() -> void:
	var lo := minf(min_interval_s, max_interval_s)
	var hi := maxf(min_interval_s, max_interval_s)
	_countdown_s = _rng.randf_range(lo, hi)


func _is_world_ready() -> bool:
	if _bootstrap != null and _bootstrap.has_method("is_world_ready"):
		return bool(_bootstrap.call("is_world_ready"))
	return true


func _up_at(world_position: Vector3) -> Vector3:
	if _gravity != null:
		return _gravity.up_at(world_position)
	return GravityField.resolve_up(self, world_position)


func _forward_tangent(up: Vector3) -> Vector3:
	var camera := _player.get_node_or_null("Camera") as Camera3D if _player else null
	var forward := Vector3.FORWARD
	if camera != null:
		forward = -camera.global_transform.basis.z
	forward = forward.slide(up)
	if forward.length_squared() <= 0.0001:
		return _random_tangent(up)
	return forward.normalized()


func _random_tangent(up: Vector3) -> Vector3:
	var basis := Basis.IDENTITY
	if _gravity != null:
		basis = _gravity.tangent_basis_at(
			_player.global_position if _player else Vector3.UP,
			Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0))
		)
	else:
		var forward := Vector3.FORWARD.slide(up)
		if forward.length_squared() < 0.0001:
			forward = Vector3.RIGHT.slide(up)
		basis = Basis.looking_at(forward.normalized(), up)
	var angle := _rng.randf_range(0.0, TAU)
	return (basis.x * cos(angle) + basis.z * sin(angle)).normalized()


func _probe_surface(near_position: Vector3) -> Vector3:
	var up := _up_at(near_position)
	var origin := near_position + up * maxf(spawn_height_m, 40.0)
	var direction := -up
	var space := get_viewport().world_3d.direct_space_state if get_viewport() else null
	if space == null:
		return Vector3.INF
	var hit := VoxelSpaceUtil.physics_surface_along_ray(
		space,
		origin,
		direction,
		MoonGeometry.GROUND_PROBE_DISTANCE_M + spawn_height_m
	)
	if _is_finite_vec3(hit):
		return hit
	var tool := TerrainCompat.get_voxel_tool(_terrain)
	if tool == null:
		return Vector3.INF
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var ray: VoxelRaycastResult = VoxelSpaceUtil.raycast_world(
		tool,
		_terrain,
		origin,
		direction,
		MoonGeometry.GROUND_PROBE_DISTANCE_M + spawn_height_m
	)
	if ray == null:
		return Vector3.INF
	return VoxelSpaceUtil.raycast_hit_world_point(
		_terrain,
		origin,
		direction,
		ray
	)


func _make_meteor() -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Meteorite"
	body.mass = meteor_mass_kg
	body.gravity_scale = 1.0
	body.continuous_cd = true
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.collision_layer = 2
	body.collision_mask = 7
	body.linear_damp = 0.0
	body.angular_damp = 0.15
	body.set_meta("meteorite", true)

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = meteor_radius_m
	shape.shape = sphere
	body.add_child(shape)

	var visual := _make_meteor_visual()
	body.add_child(visual)

	body.body_shape_entered.connect(
		func(
			_body_rid: RID,
			other: Node,
			_other_shape_index: int,
			_local_shape_index: int
		) -> void:
			_on_meteor_contact(body, other)
	)
	return body


func _make_meteor_visual() -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.42, 0.32)
	mat.roughness = 0.88
	mat.metallic = 0.08
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.45, 0.12)
	mat.emission_energy_multiplier = 2.8
	for _i in 4:
		var blob := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = meteor_radius_m * _rng.randf_range(0.45, 0.95)
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 12
		mesh.rings = 8
		blob.mesh = mesh
		blob.material_override = mat
		blob.position = Vector3(
			_rng.randf_range(-0.45, 0.45),
			_rng.randf_range(-0.4, 0.4),
			_rng.randf_range(-0.45, 0.45)
		) * meteor_radius_m * 0.55
		root.add_child(blob)
	# Hot core so the body reads against lunar dusk on soft renderers.
	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = meteor_radius_m * 0.55
	core_mesh.height = core_mesh.radius * 2.0
	core_mesh.radial_segments = 10
	core_mesh.rings = 6
	core.mesh = core_mesh
	core.material_override = mat
	root.add_child(core)
	return root


func _try_raycast_impact(body: RigidBody3D) -> void:
	var space := get_viewport().world_3d.direct_space_state if get_viewport() else null
	if space == null:
		return
	var velocity := body.linear_velocity
	var direction := velocity
	if direction.length_squared() < 0.25:
		direction = -_up_at(body.global_position)
	else:
		direction = direction.normalized()
	var probe_len := maxf(meteor_radius_m * 2.5, velocity.length() * (1.0 / 60.0) * 2.0)
	var query := PhysicsRayQueryParameters3D.create(
		body.global_position,
		body.global_position + direction * probe_len
	)
	query.collision_mask = 1
	query.exclude = [body.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var collider = hit.get("collider")
	if collider == null or not ImpactResolver.is_world_surface_partner(collider):
		return
	_on_meteor_contact(body, collider as Node)


func _on_meteor_contact(body: RigidBody3D, other: Node) -> void:
	if body == null or not is_instance_valid(body):
		return
	if body.has_meta("meteorite_spent"):
		return
	var hits_terrain := ImpactResolver.is_world_surface_partner(other)
	var suit := ImpactResolver.player_suit_state(other)
	if not hits_terrain and suit == null:
		return
	body.set_meta("meteorite_spent", true)
	var contact := body.global_position
	var up := _up_at(contact)
	print(
		"MeteoriteSystem: impact terrain=%s player=%s at %s"
		% [hits_terrain, suit != null, contact]
	)
	if hits_terrain:
		_carve_crater(contact, -up)
		_spawn_vfx(contact, up)
	elif suit != null and damage_player:
		# Still show a burst if we only clipped the player.
		_spawn_vfx(contact, up)
	if damage_player and suit != null:
		suit.apply_damage(player_damage, &"meteorite")
	body.queue_free()


func _carve_crater(contact_world: Vector3, carve_direction: Vector3) -> void:
	if _gateway == null or not _gateway.has_method("apply_terrain_carve"):
		return
	var direction := carve_direction
	if direction.length_squared() <= 0.000001:
		direction = Vector3.DOWN
	else:
		direction = direction.normalized()
	var radius := maxf(crater_radius_m, 0.4)
	var center := contact_world + direction * (radius * 0.45)
	var op := {
		"stamp_kind": &"sphere",
		"center": center,
		"radius": radius,
		"sdf_scale": clampf(crater_sdf_scale, 0.05, 1.0),
	}
	_gateway.call("apply_terrain_carve", op, volume_budget_m3)


func _spawn_vfx(contact_world: Vector3, up: Vector3) -> void:
	var burst: Node3D = _IMPACT_VFX.instantiate()
	var parent := get_parent()
	if parent == null:
		parent = self
	parent.add_child(burst)
	burst.global_position = contact_world
	var look_target := contact_world + up
	if (look_target - burst.global_position).length_squared() > 0.0001:
		burst.look_at(look_target, Vector3.UP if absf(up.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT)
	_prime_vfx(burst)
	var duration := float(burst.get_meta("vfx_duration", 2.4))
	get_tree().create_timer(duration).timeout.connect(
		func() -> void:
			if is_instance_valid(burst):
				burst.queue_free()
	)


func _prime_vfx(root: Node) -> void:
	if root is GPUParticles3D and (root as GPUParticles3D).one_shot:
		var particles := root as GPUParticles3D
		particles.restart()
		particles.emitting = true
	for child_node in root.get_children():
		_prime_vfx(child_node)


func _prune_active() -> void:
	var kept: Array[RigidBody3D] = []
	for body in _active:
		if body != null and is_instance_valid(body):
			kept.append(body)
	_active = kept


func _setup_debug_button() -> void:
	if not show_debug_button or not debug_spawn_enabled or _canvas == null:
		return
	_debug_button = Button.new()
	_debug_button.name = "DebugMeteorButton"
	_debug_button.text = "Метеорит (F8)"
	_debug_button.tooltip_text = "Устроить падение метеорита рядом с игроком"
	_debug_button.focus_mode = Control.FOCUS_NONE
	_debug_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_debug_button.offset_left = -168.0
	_debug_button.offset_top = -52.0
	_debug_button.offset_right = -16.0
	_debug_button.offset_bottom = -16.0
	_debug_button.pressed.connect(debug_spawn_near_player)
	_canvas.add_child(_debug_button)


func _register_console_command() -> void:
	if not debug_spawn_enabled:
		return
	if LimboConsole == null or not LimboConsole.has_method("register_command"):
		return
	LimboConsole.register_command(
		debug_spawn_near_player,
		"meteor",
		"spawn a meteorite near the player"
	)


func _is_finite_vec3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)
