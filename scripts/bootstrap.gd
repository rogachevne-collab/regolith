extends Node3D

const SKY_PROBE_Y := 120.0
const SPAWN_CLEARANCE := 1.05
const MIN_WARMUP_FRAMES := 30
const STABLE_PHYSICS_FRAMES := 4

@onready var _terrain: VoxelTerrain = $VoxelTerrain
@onready var _player: Node3D = $Player
@onready var _launch_vehicle: RigidBody3D = $LaunchVehicle
@onready var _cart: RigidBody3D = $Cart
@onready var _assembly: RigidBody3D = $Assembly
@onready var _loading: Label = $CanvasLayer/Loading
@onready var _coordinates: Label = $CanvasLayer/Coordinates

var _warmup_frames := 0
var _stable_player := 0
var _player_spawn_xz := Vector2.ZERO
var _player_spawn_pos := Vector3.ZERO


func _ready() -> void:
	_loading.visible = true
	_cart.freeze = true
	_assembly.freeze = true
	var assembly_cells: Array[Vector3i] = [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(1, 1, 0),
		Vector3i(0, 0, 1),
		Vector3i(1, 0, 1),
		Vector3i(0, 1, 1),
		Vector3i(1, 1, 1),
		Vector3i(2, 0, 0),
		Vector3i(3, 0, 0),
	]
	_assembly.call("build_from", assembly_cells)
	_player_spawn_xz = Vector2(_player.global_position.x, _player.global_position.z)
	if _player.has_method("set_spawn_locked"):
		_player.set_spawn_locked(true)
	# Hold player in the sky until physics collider exists — no fall at y=0.
	_player.global_position = Vector3(_player_spawn_xz.x, SKY_PROBE_Y, _player_spawn_xz.y)
	_place_when_ground_exists()


func _process(_delta: float) -> void:
	var player_position: Vector3 = _player.global_position
	var cart_position: Vector3 = _cart.global_position
	_coordinates.text = (
		"Игрок:  %.1f, %.1f, %.1f\n"
		+ "Тележка: %.1f, %.1f, %.1f"
	) % [
		player_position.x,
		player_position.y,
		player_position.z,
		cart_position.x,
		cart_position.y,
		cart_position.z,
	]


func _place_when_ground_exists() -> void:
	var tool: VoxelTool = _terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var player_origin := Vector3(_player_spawn_xz.x, SKY_PROBE_Y, _player_spawn_xz.y)
	var vehicle_origin := Vector3(
		_launch_vehicle.global_position.x,
		SKY_PROBE_Y,
		_launch_vehicle.global_position.z)
	var cart_origin := Vector3(
		_cart.global_position.x,
		SKY_PROBE_Y,
		_cart.global_position.z)
	var assembly_origin := Vector3(
		_assembly.global_position.x,
		SKY_PROBE_Y,
		_assembly.global_position.z)
	var cart_x_minus_origin := cart_origin + Vector3.LEFT
	var cart_x_plus_origin := cart_origin + Vector3.RIGHT
	var cart_z_minus_origin := cart_origin + Vector3.FORWARD
	var cart_z_plus_origin := cart_origin + Vector3.BACK

	while true:
		if _warmup_frames < MIN_WARMUP_FRAMES:
			_warmup_frames += 1
			var pct: int = int(
				float(_warmup_frames) / float(MIN_WARMUP_FRAMES) * 100.0
			)
			_loading.text = "Загрузка террейна... %d%%" % pct
			await get_tree().process_frame
			continue

		var player_hit: VoxelRaycastResult = tool.raycast(
			player_origin, Vector3.DOWN, 200.0)
		var vehicle_hit: VoxelRaycastResult = tool.raycast(
			vehicle_origin, Vector3.DOWN, 200.0)
		var cart_hit: VoxelRaycastResult = tool.raycast(
			cart_origin, Vector3.DOWN, 200.0)
		var assembly_hit: VoxelRaycastResult = tool.raycast(
			assembly_origin, Vector3.DOWN, 200.0)
		var cart_x_minus_hit: VoxelRaycastResult = tool.raycast(
			cart_x_minus_origin, Vector3.DOWN, 200.0)
		var cart_x_plus_hit: VoxelRaycastResult = tool.raycast(
			cart_x_plus_origin, Vector3.DOWN, 200.0)
		var cart_z_minus_hit: VoxelRaycastResult = tool.raycast(
			cart_z_minus_origin, Vector3.DOWN, 200.0)
		var cart_z_plus_hit: VoxelRaycastResult = tool.raycast(
			cart_z_plus_origin, Vector3.DOWN, 200.0)
		var surfaces_ready := (
			player_hit != null
			and vehicle_hit != null
			and cart_hit != null
			and assembly_hit != null
			and cart_x_minus_hit != null
			and cart_x_plus_hit != null
			and cart_z_minus_hit != null
			and cart_z_plus_hit != null
		)
		if surfaces_ready and _probe_player_spawn_ready(player_hit.distance):
			var player_surface_y: float = _resolve_surface_y(
				_player_spawn_xz,
				player_origin.y - player_hit.distance
			)
			var player_position := Vector3(
				_player_spawn_xz.x,
				player_surface_y + SPAWN_CLEARANCE,
				_player_spawn_xz.y
			)
			_launch_vehicle.global_position = (
				vehicle_origin
				+ Vector3.DOWN * vehicle_hit.distance
				+ Vector3.UP * 0.52)
			var cart_ground: Vector3 = (
				cart_origin + Vector3.DOWN * cart_hit.distance
			)
			var cart_x_minus_ground: Vector3 = (
				cart_x_minus_origin
				+ Vector3.DOWN * cart_x_minus_hit.distance
			)
			var cart_x_plus_ground: Vector3 = (
				cart_x_plus_origin
				+ Vector3.DOWN * cart_x_plus_hit.distance
			)
			var cart_z_minus_ground: Vector3 = (
				cart_z_minus_origin
				+ Vector3.DOWN * cart_z_minus_hit.distance
			)
			var cart_z_plus_ground: Vector3 = (
				cart_z_plus_origin
				+ Vector3.DOWN * cart_z_plus_hit.distance
			)
			var terrain_tangent_x: Vector3 = (
				cart_x_plus_ground - cart_x_minus_ground
			)
			var terrain_tangent_z: Vector3 = (
				cart_z_plus_ground - cart_z_minus_ground
			)
			var terrain_up: Vector3 = (
				terrain_tangent_z.cross(terrain_tangent_x).normalized()
			)
			var cart_forward: Vector3 = (
				Vector3.FORWARD
				- terrain_up * Vector3.FORWARD.dot(terrain_up)
			).normalized()
			var cart_right: Vector3 = (
				cart_forward.cross(terrain_up).normalized()
			)
			var cart_basis := Basis(
				cart_right,
				terrain_up,
				-cart_forward
			).orthonormalized()
			_cart.global_transform = Transform3D(
				cart_basis,
				cart_ground + terrain_up * 1.22
			)
			_cart.linear_velocity = Vector3.ZERO
			_cart.angular_velocity = Vector3.ZERO
			_cart.freeze = false
			_assembly.global_position = (
				assembly_origin
				+ Vector3.DOWN * assembly_hit.distance
				+ Vector3.UP * 1.5
			)
			_assembly.linear_velocity = Vector3.ZERO
			_assembly.angular_velocity = Vector3.ZERO
			_assembly.freeze = false
			_player.call("begin_spawn_settle", player_position)
			_loading.text = "Посадка..."
			while not _player.call("is_spawn_settled"):
				await get_tree().physics_frame
			_loading.visible = false
			return

		if not surfaces_ready:
			_stable_player = 0
		if _stable_player == 0:
			_loading.text = "Ожидание коллизии..."
		await get_tree().process_frame


func _probe_player_spawn_ready(voxel_distance: float) -> bool:
	var surface_y_voxel: float = SKY_PROBE_Y - voxel_distance
	var surface_y: float = _resolve_surface_y(_player_spawn_xz, surface_y_voxel)
	_player_spawn_pos = Vector3(
		_player_spawn_xz.x,
		surface_y + SPAWN_CLEARANCE,
		_player_spawn_xz.y
	)

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var ray_from := Vector3(_player_spawn_xz.x, SKY_PROBE_Y, _player_spawn_xz.y)
	var ray_to := Vector3(_player_spawn_xz.x, surface_y - 8.0, _player_spawn_xz.y)
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		ray_from, ray_to
	)
	query.collision_mask = 1
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var phys_hit: Dictionary = space.intersect_ray(query)
	if phys_hit.is_empty():
		_stable_player = 0
		return false

	_stable_player += 1
	_loading.text = "Посадка %d/%d" % [_stable_player, STABLE_PHYSICS_FRAMES]
	return _stable_player >= STABLE_PHYSICS_FRAMES


func _resolve_surface_y(xz: Vector2, surface_y_voxel: float) -> float:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var ray_from := Vector3(xz.x, SKY_PROBE_Y, xz.y)
	var ray_to := Vector3(xz.x, surface_y_voxel - 8.0, xz.y)
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		ray_from, ray_to
	)
	query.collision_mask = 1
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var phys_hit: Dictionary = space.intersect_ray(query)
	if phys_hit.is_empty():
		return surface_y_voxel

	var surface_y_phys: float = (phys_hit["position"] as Vector3).y
	return maxf(surface_y_voxel, surface_y_phys)
