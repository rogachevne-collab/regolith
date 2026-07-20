extends Node3D
## Demo: two stacked granular patches — pour on the shelf, watch mobilised
## spoil spill off the lip onto the catch floor, with active grains as the
## presentation layer on top of the field (not truth).
##
## Spec: docs/specs/GRANULAR-V0.md

const CELL := 0.25
const SHELF_W := 20
const SHELF_D := 16
const FLOOR_W := 36
const FLOOR_D := 36
const REPOSE_DEG := 33.0
const POUR_RATE_M3_PER_S := 0.55
const POUR_RADIUS_CELLS := 1.4
## Only the +Z lip hangs over the drop — one curtain, not four walls raining.
const SHELF_OPEN_EDGES := GranularPatch.EDGE_POS_Z
const SPILL_RATE_M3_PER_S := 0.45
const CATCH_RADIUS_CELLS := 1.8
const MAX_SURFACE_GRAINS := 500
const MAX_AIR_GRAINS := 80
const GRAIN_MIN_FLOW := 0.02
const AIR_GRAIN_VOLUME := 0.012
const GRAVITY := 1.62
const AIR_SPAWN_CHANCE := 0.35

@onready var _shelf_surface: MeshInstance3D = $Shelf/Surface
@onready var _shelf_body: StaticBody3D = $Shelf/SurfaceBody
@onready var _floor_surface: MeshInstance3D = $Floor/Surface
@onready var _floor_body: StaticBody3D = $Floor/SurfaceBody
@onready var _shelf_grains: MultiMeshInstance3D = $Shelf/Grains
@onready var _floor_grains: MultiMeshInstance3D = $Floor/Grains
@onready var _air_grains: MultiMeshInstance3D = $AirGrains
@onready var _marker: MeshInstance3D = $AimMarker
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _rig: Node3D = $CameraRig
@onready var _overlay: Label = $CanvasLayer/Overlay
@onready var _status: Label = $CanvasLayer/Status

var _shelf: GranularPatch
var _floor: GranularPatch
var _shelf_shown: PackedFloat32Array
var _floor_shown: PackedFloat32Array
var _shelf_indices := PackedInt32Array()
var _floor_indices := PackedInt32Array()
var _pouring := false
var _aim := Vector3.ZERO
var _orbit_yaw := 0.55
var _orbit_pitch := -0.4
var _orbit_distance := 16.0
var _dragging := false
var _air: Array[Dictionary] = []
var _spilled_total := 0.0
var _dump_seq := 0


func _ready() -> void:
	_shelf = GranularPatch.create(SHELF_W, SHELF_D, CELL, REPOSE_DEG)
	_floor = GranularPatch.create(FLOOR_W, FLOOR_D, CELL, REPOSE_DEG)
	_shelf_shown = _shelf.thickness_data()
	_floor_shown = _floor.thickness_data()
	_shelf_indices = _build_indices(SHELF_W, SHELF_D)
	_floor_indices = _build_indices(FLOOR_W, FLOOR_D)
	_setup_collider(_shelf_body, SHELF_W, SHELF_D)
	_setup_collider(_floor_body, FLOOR_W, FLOOR_D)
	_setup_grain_multimesh(_shelf_grains, MAX_SURFACE_GRAINS)
	_setup_grain_multimesh(_floor_grains, MAX_SURFACE_GRAINS)
	_setup_grain_multimesh(_air_grains, MAX_AIR_GRAINS)
	_shelf_grains.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_floor_grains.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_air_grains.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rebuild_surface(_shelf, _shelf_shown, _shelf_indices, _shelf_surface, _shelf_body)
	_rebuild_surface(_floor, _floor_shown, _floor_indices, _floor_surface, _floor_body)
	_update_camera()
	_update_aim(get_viewport().get_visible_rect().size * 0.5)
	_overlay.text = "\n".join([
		"E — hold to pour on the shelf, near the far lip",
		"R — reset   right mouse — orbit   wheel — zoom",
		"Spoil spills off one open edge onto the floor and piles there.",
		"Grains are decoration — the height field is the real material.",
	])


func _process(delta: float) -> void:
	if _pouring:
		_pour(delta)
	if not _shelf.is_settled():
		_shelf.advance(delta, GRAVITY)
	if not _floor.is_settled():
		_floor.advance(delta, GRAVITY)
	_drain_spill(delta)
	_integrate_air(delta)
	var shelf_moved := _chase_into(_shelf, true, delta)
	var floor_moved := _chase_into(_floor, false, delta)
	if shelf_moved:
		_rebuild_surface(
			_shelf, _shelf_shown, _shelf_indices, _shelf_surface, _shelf_body
		)
	if floor_moved:
		_rebuild_surface(
			_floor, _floor_shown, _floor_indices, _floor_surface, _floor_body
		)
	_rebuild_surface_grains(_shelf, _shelf_shown, _shelf_grains, $Shelf)
	# Floor pile is the field mesh; skipping floor surface-grains avoids a
	# second grid of cubes fighting the mound.
	_floor_grains.multimesh.visible_instance_count = 0
	_update_status()


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_distance = maxf(_orbit_distance - 1.0, 4.0)
			_update_camera()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_distance = minf(_orbit_distance + 1.0, 40.0)
			_update_camera()
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		if _dragging:
			_orbit_yaw -= motion.relative.x * 0.006
			_orbit_pitch = clampf(
				_orbit_pitch - motion.relative.y * 0.006, -1.35, -0.08
			)
			_update_camera()
		else:
			_update_aim(motion.position)
		return
	var key := event as InputEventKey
	if key == null or key.echo:
		return
	if key.keycode == KEY_E:
		_pouring = key.pressed
		return
	if key.pressed and key.keycode == KEY_R:
		_reset()


func _pour(delta: float) -> void:
	var local: Vector3 = $Shelf.to_local(_aim)
	var fx: float = local.x / CELL
	var fz: float = local.z / CELL
	if fx < 0.0 or fz < 0.0 or fx > float(SHELF_W - 1) or fz > float(SHELF_D - 1):
		return
	_dump_seq += 1
	var volume := POUR_RATE_M3_PER_S * delta
	var reach := int(ceil(POUR_RADIUS_CELLS)) + 1
	var cx := int(round(fx))
	var cz := int(round(fz))
	var cells := PackedInt32Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := cx + dx
			var z := cz + dz
			if x < 0 or z < 0 or x >= SHELF_W or z >= SHELF_D:
				continue
			var ox: float = float(x) - fx
			var oz: float = float(z) - fz
			var d := sqrt(ox * ox + oz * oz)
			if d > POUR_RADIUS_CELLS:
				continue
			var jitter := 0.65 + 0.7 * _hash2(x + _dump_seq, z + _dump_seq * 3)
			var w := (1.0 - d / POUR_RADIUS_CELLS) * jitter
			cells.append(z * SHELF_W + x)
			weights.append(w)
			total += w
	if total <= 0.0:
		return
	for k in cells.size():
		var i := cells[k]
		_shelf.deposit(i % SHELF_W, i / SHELF_W, volume * weights[k] / total)


func _drain_spill(delta: float) -> void:
	var events := _shelf.spill_edge(SPILL_RATE_M3_PER_S * delta, SHELF_OPEN_EDGES)
	for event: Dictionary in events:
		var volume: float = event["volume_m3"]
		_spilled_total += volume
		var lip_h: float = _shelf.surface_height_at_m(
			float(event["x_m"]), float(event["z_m"])
		)
		if is_nan(lip_h):
			lip_h = 0.05
		var world: Vector3 = $Shelf.to_global(
			Vector3(float(event["x_m"]), lip_h, float(event["z_m"]))
		)
		# Nudge past the lip so the catch lands on the floor, not back on the shelf.
		world.x += float(event["out_x"]) * CELL * 1.5
		world.z += float(event["out_z"]) * CELL * 1.5
		_deposit_catch_lobe(world, volume)
		_spawn_air_grains(world, volume, Vector3(event["out_x"], 0.0, event["out_z"]))


## Spread a spill into a small lobe so the floor grows a pile, not a spike.
func _deposit_catch_lobe(world: Vector3, volume_m3: float) -> void:
	var floor_local: Vector3 = $Floor.to_local(world)
	var fx := floor_local.x / CELL
	var fz := floor_local.z / CELL
	var cx := int(round(fx))
	var cz := int(round(fz))
	var reach := int(ceil(CATCH_RADIUS_CELLS)) + 1
	var cells := PackedInt32Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := cx + dx
			var z := cz + dz
			if x < 0 or z < 0 or x >= FLOOR_W or z >= FLOOR_D:
				continue
			var ox := float(x) - fx
			var oz := float(z) - fz
			var dist := sqrt(ox * ox + oz * oz)
			if dist > CATCH_RADIUS_CELLS:
				continue
			var w := 1.0 - dist / CATCH_RADIUS_CELLS
			cells.append(z * FLOOR_W + x)
			weights.append(w)
			total += w
	if total <= 0.0:
		var x := clampi(cx, 0, FLOOR_W - 1)
		var z := clampi(cz, 0, FLOOR_D - 1)
		_floor.deposit(x, z, volume_m3)
		return
	for k in cells.size():
		var i := cells[k]
		_floor.deposit(i % FLOOR_W, i / FLOOR_W, volume_m3 * weights[k] / total)


func _spawn_air_grains(origin: Vector3, volume_m3: float, outward: Vector3) -> void:
	if _hash2(_dump_seq + _air.size(), 91) > AIR_SPAWN_CHANCE:
		return
	var count := mini(maxi(int(round(volume_m3 / AIR_GRAIN_VOLUME)), 1), 3)
	for _i in count:
		if _air.size() >= MAX_AIR_GRAINS:
			_air.pop_front()
		var side := (_hash2(_air.size() + 3, _dump_seq) - 0.5) * 0.55
		var along := (_hash2(_air.size() + 11, _dump_seq + 2) - 0.5) * 0.35
		var jitter := outward.cross(Vector3.UP).normalized() * side + outward * along
		jitter.y = 0.02 + _hash2(_air.size() + 9, _dump_seq + 1) * 0.08
		var speed := 0.35 + _hash2(_air.size(), 4) * 0.55
		_air.append({
			"pos": origin + jitter,
			"vel": outward * speed + Vector3(
				(_hash2(_air.size() + 5, 1) - 0.5) * 0.25,
				-0.05,
				(_hash2(_air.size() + 6, 2) - 0.5) * 0.25
			),
			"age": 0.0,
			"size": 0.05 + _hash2(_air.size() + 21, 8) * 0.06,
		})


func _integrate_air(delta: float) -> void:
	var floor_y: float = $Floor.global_position.y
	var alive: Array[Dictionary] = []
	for grain: Dictionary in _air:
		var vel: Vector3 = grain["vel"]
		vel.y -= GRAVITY * delta
		var pos: Vector3 = grain["pos"] + vel * delta
		grain["vel"] = vel
		grain["pos"] = pos
		grain["age"] = float(grain["age"]) + delta
		var local: Vector3 = $Floor.to_local(pos)
		var surface := _floor.surface_height_at_m(local.x, local.z)
		var hit_y: float = floor_y + (0.0 if is_nan(surface) else surface)
		if pos.y <= hit_y + 0.02 or float(grain["age"]) > 4.0:
			continue
		alive.append(grain)
	_air = alive
	var multimesh := _air_grains.multimesh
	var shown := mini(_air.size(), MAX_AIR_GRAINS)
	multimesh.visible_instance_count = shown
	for i in shown:
		var grain: Dictionary = _air[i]
		var size: float = grain["size"]
		var basis := Basis.from_euler(
			Vector3(grain["age"] * 4.0, grain["age"] * 2.3, 0.0)
		).scaled(Vector3(size, size * 0.6, size * 0.8))
		multimesh.set_instance_transform(
			i, Transform3D(basis, grain["pos"])
		)


func _rebuild_surface_grains(
	patch: GranularPatch,
	shown: PackedFloat32Array,
	node: MultiMeshInstance3D,
	root: Node3D
) -> void:
	var multimesh := node.multimesh
	var placed := 0
	var w := patch.width
	var d := patch.depth
	for z in d:
		for x in w:
			if placed >= MAX_SURFACE_GRAINS:
				break
			var flowing := patch.flowing_thickness_at(x, z)
			if flowing < GRAIN_MIN_FLOW:
				continue
			# Sparse: only a fraction of flowing cells, so it reads as grit
			# on a moving face, not a second grid of cubes.
			var density := clampf(flowing / 0.12, 0.05, 0.35)
			if _hash2(x + 401, z + 17) > density:
				continue
			var jitter_x := (_hash2(x + 3, z) - 0.5) * CELL
			var jitter_z := (_hash2(x, z + 11) - 0.5) * CELL
			var local_x := float(x) * CELL + jitter_x
			var local_z := float(z) * CELL + jitter_z
			var height := shown[z * w + x]
			var size := 0.035 + _hash2(x + 8, z + 2) * 0.05
			var origin := root.to_global(Vector3(local_x, height + size * 0.2, local_z))
			# Slide hint: bias downhill using a cheap neighbour drop.
			var down := Vector3.ZERO
			if x + 1 < w and shown[z * w + x + 1] < height:
				down.x += 1.0
			if x > 0 and shown[z * w + x - 1] < height:
				down.x -= 1.0
			if z + 1 < d and shown[(z + 1) * w + x] < height:
				down.z += 1.0
			if z > 0 and shown[(z - 1) * w + x] < height:
				down.z -= 1.0
			var slide := down.normalized() * (0.02 * density) if down.length_squared() > 0.0 else Vector3.ZERO
			var basis := Basis.from_euler(
				Vector3(
					_hash2(x, z + 5) * TAU,
					_hash2(x + 9, z) * TAU,
					_hash2(x + 2, z + 7) * TAU
				)
			).scaled(Vector3(size, size * 0.55, size * 0.75))
			multimesh.set_instance_transform(
				placed, Transform3D(basis, origin + slide)
			)
			placed += 1
	multimesh.visible_instance_count = placed


func _chase_into(patch: GranularPatch, shelf: bool, delta: float) -> bool:
	var target := patch.thickness_data()
	var shown := _shelf_shown if shelf else _floor_shown
	if shown.size() != target.size():
		shown = target.duplicate()
		if shelf:
			_shelf_shown = shown
		else:
			_floor_shown = shown
		return true
	var tau := 1.0 / maxf(patch.settle_rate_hz(GRAVITY), 0.01)
	var blend := 1.0 - exp(-delta / tau)
	var moved := false
	for i in target.size():
		var difference := target[i] - shown[i]
		if absf(difference) < 1e-5:
			if shown[i] != target[i]:
				shown[i] = target[i]
				moved = true
			continue
		shown[i] += difference * blend
		moved = true
	return moved


func _rebuild_surface(
	patch: GranularPatch,
	shown: PackedFloat32Array,
	indices: PackedInt32Array,
	mesh_node: MeshInstance3D,
	body: StaticBody3D
) -> void:
	var w := patch.width
	var d := patch.depth
	var count := w * d
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(count)
	normals.resize(count)
	colors.resize(count)
	for z in d:
		for x in w:
			var i := z * w + x
			var thickness := shown[i]
			vertices[i] = Vector3(float(x) * CELL, thickness, float(z) * CELL)
			# Keep alpha opaque: zero-alpha empty cells punched black holes in
			# the floor where thin spill spikes met bare mesh.
			var tint := clampf(thickness / 0.12, 0.0, 1.0)
			colors[i] = (
				Color(0.34, 0.33, 0.32)
				.lerp(Color(0.58, 0.55, 0.48), tint)
				.srgb_to_linear()
			)
			colors[i].a = 1.0
	for z in d:
		for x in w:
			var i := z * w + x
			var left := shown[maxi(x - 1, 0) + z * w]
			var right := shown[mini(x + 1, w - 1) + z * w]
			var back := shown[x + maxi(z - 1, 0) * w]
			var front := shown[x + mini(z + 1, d - 1) * w]
			normals[i] = Vector3(left - right, 2.0 * CELL, back - front).normalized()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_node.mesh = mesh
	_update_collider_data(body, patch)


func _setup_collider(body: StaticBody3D, w: int, d: int) -> void:
	var shape_node := body.get_node("Shape") as CollisionShape3D
	var shape := HeightMapShape3D.new()
	shape.map_width = w
	shape.map_depth = d
	shape_node.shape = shape
	shape_node.scale = Vector3(CELL, CELL, CELL)
	var half_x := float(w - 1) * CELL * 0.5
	var half_z := float(d - 1) * CELL * 0.5
	body.position = Vector3(half_x, 0.0, half_z)


func _update_collider_data(body: StaticBody3D, patch: GranularPatch) -> void:
	var shape_node := body.get_node("Shape") as CollisionShape3D
	var shape := shape_node.shape as HeightMapShape3D
	if shape == null:
		return
	var source := patch.height_map_data()
	var data := shape.map_data
	if data.size() != source.size():
		data.resize(source.size())
	for i in source.size():
		data[i] = source[i] / CELL
	shape.map_data = data


func _setup_grain_multimesh(node: MultiMeshInstance3D, count: int) -> void:
	var grain := BoxMesh.new()
	grain.size = Vector3.ONE
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = grain
	multimesh.instance_count = count
	multimesh.visible_instance_count = 0
	node.multimesh = multimesh


func _build_indices(w: int, d: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	for z in d - 1:
		for x in w - 1:
			var i := z * w + x
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + w)
			indices.append(i + 1)
			indices.append(i + w + 1)
			indices.append(i + w)
	return indices


func _update_aim(screen_position: Vector2) -> void:
	var plane := Plane(Vector3.UP, $Shelf.global_position.y)
	var from := _camera.project_ray_origin(screen_position)
	var dir := _camera.project_ray_normal(screen_position)
	var hit: Variant = plane.intersects_ray(from, dir)
	if hit == null:
		return
	_aim = hit as Vector3
	var local: Vector3 = $Shelf.to_local(_aim)
	var h := _shelf.surface_height_at_m(local.x, local.z)
	_marker.position = Vector3(
		_aim.x, $Shelf.global_position.y + (0.05 if is_nan(h) else h + 0.05), _aim.z
	)


func _update_camera() -> void:
	var focus := Vector3(4.5, 1.2, 4.0)
	_rig.position = focus
	_camera.position = Vector3(
		sin(_orbit_yaw) * cos(_orbit_pitch),
		-sin(_orbit_pitch),
		cos(_orbit_yaw) * cos(_orbit_pitch)
	) * _orbit_distance
	_camera.look_at(focus, Vector3.UP)


func _reset() -> void:
	_shelf = GranularPatch.create(SHELF_W, SHELF_D, CELL, REPOSE_DEG)
	_floor = GranularPatch.create(FLOOR_W, FLOOR_D, CELL, REPOSE_DEG)
	_shelf_shown = _shelf.thickness_data()
	_floor_shown = _floor.thickness_data()
	_air.clear()
	_spilled_total = 0.0
	_air_grains.multimesh.visible_instance_count = 0
	_rebuild_surface(_shelf, _shelf_shown, _shelf_indices, _shelf_surface, _shelf_body)
	_rebuild_surface(_floor, _floor_shown, _floor_indices, _floor_surface, _floor_body)


func _update_status() -> void:
	_status.text = (
		"shelf %.2f m3   floor %.2f m3   spilled %.2f m3   air %d   %s/%s"
		% [
			_shelf.total_volume_m3(),
			_floor.total_volume_m3(),
			_spilled_total,
			_air.size(),
			"shelf settled" if _shelf.is_settled() else "shelf sliding",
			"floor settled" if _floor.is_settled() else "floor sliding",
		]
	)


func _hash2(x: int, z: int) -> float:
	var h := (x * 73856093) ^ (z * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	return float(h & 0x7fffffff) / float(0x7fffffff)
