class_name TerrainFloatingDebrisService
extends RefCounted

## Post-dig floating SDF islands → RigidBody debris via Voxel Tools
## `VoxelToolLodTerrain.separate_floating_chunks` (LOD terrain only).
## Balance: `industry.floating_chunks` in game_balance.json.

const GROUP_NAME := &"terrain_floating_debris"
## Player CharacterBody is layer 4; include so debris can be pushed.
const PLAYER_COLLISION_LAYER := 4
const DEBRIS_MATERIAL_PATH := "res://resources/terrain_debris_material.tres"
const MIN_MASS_KG := 8.0
const MAX_MASS_KG := 220.0
const MASS_PER_M3 := 45.0
## VT starts bodies kinematic then flips to rigid; force if still stuck.
const FORCE_RIGID_AFTER_S := 0.35

var _last_separate_msec := 0
var _active: Array[RigidBody3D] = []
var _debris_material: Material


func try_separate_after_dig(
	terrain: Node3D,
	voxel_tool: VoxelTool,
	world_center: Vector3,
	removed_m3: float,
	parent: Node
) -> int:
	if parent == null or terrain == null or voxel_tool == null:
		return 0
	if not IndustryArchetypeProfile.floating_chunks_enabled():
		return 0
	if removed_m3 < IndustryArchetypeProfile.floating_chunks_min_removed_m3():
		return 0
	if not voxel_tool.has_method("separate_floating_chunks"):
		return 0
	var now := Time.get_ticks_msec()
	var cooldown := IndustryArchetypeProfile.floating_chunks_cooldown_ms()
	if now - _last_separate_msec < cooldown:
		return 0
	var box_voxels := float(IndustryArchetypeProfile.floating_chunks_box_size_voxels())
	if box_voxels < 4.0:
		return 0
	var local_center := VoxelSpaceUtil.world_to_local(terrain, world_center)
	var half := box_voxels * 0.5
	var box := AABB(
		local_center - Vector3(half, half, half),
		Vector3(box_voxels, box_voxels, box_voxels)
	)
	if (
		voxel_tool.has_method("is_area_editable")
		and not bool(voxel_tool.call("is_area_editable", box))
	):
		return 0
	_prune_dead()
	var spawned: Array = voxel_tool.call("separate_floating_chunks", box, parent)
	_last_separate_msec = now
	if spawned.is_empty():
		return 0
	var layer := IndustryArchetypeProfile.floating_chunks_collision_layer()
	var despawn_s := IndustryArchetypeProfile.floating_chunks_despawn_s()
	var count := 0
	for item: Variant in spawned:
		var body := item as RigidBody3D
		if body == null or not is_instance_valid(body):
			continue
		_configure_body(body, layer, despawn_s)
		_active.append(body)
		count += 1
	_enforce_cap()
	return count


func _configure_body(body: RigidBody3D, layer: int, despawn_s: float) -> void:
	body.add_to_group(GROUP_NAME)
	# Layer 2 (default): player mask includes it. Mask hits terrain + debris + player.
	body.collision_layer = layer
	body.collision_mask = 1 | layer | PLAYER_COLLISION_LAYER
	body.continuous_cd = true
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.can_sleep = true
	body.freeze = false
	_apply_debris_material(body)
	_apply_mass_from_mesh(body)
	body.set_meta(&"dig_hp", body.mass)
	body.set_meta(&"dig_hp_max", body.mass)
	body.set_meta(&"dig_mass_kg", body.mass)
	if body.is_inside_tree():
		var tree := body.get_tree()
		if tree != null:
			# VT starts kinematic briefly so terrain colliders update; ensure dynamic.
			tree.create_timer(FORCE_RIGID_AFTER_S).timeout.connect(
				func() -> void:
					if is_instance_valid(body):
						body.freeze = false
						body.sleeping = false
			)
			if despawn_s > 0.05:
				tree.create_timer(despawn_s).timeout.connect(
					func() -> void:
						if is_instance_valid(body):
							body.queue_free()
				)


func _debris_material_shared() -> Material:
	if _debris_material == null:
		_debris_material = load(DEBRIS_MATERIAL_PATH) as Material
	return _debris_material


func _apply_debris_material(body: RigidBody3D) -> void:
	var mat := _debris_material_shared()
	if mat == null:
		return
	for child: Node in body.find_children("*", "MeshInstance3D", true, false):
		var mesh_i := child as MeshInstance3D
		if mesh_i == null:
			continue
		# Drop Transvoxel/VT material — CUSTOM0 + u_transition_mask look broken off-terrain.
		mesh_i.material_override = mat


func _apply_mass_from_mesh(body: RigidBody3D) -> void:
	var volume_m3 := 0.0
	for child: Node in body.find_children("*", "MeshInstance3D", true, false):
		var mesh_i := child as MeshInstance3D
		if mesh_i == null or mesh_i.mesh == null:
			continue
		var aabb := mesh_i.mesh.get_aabb()
		var size := aabb.size * mesh_i.scale
		volume_m3 += maxf(size.x * size.y * size.z, 0.05)
	if volume_m3 <= 0.05:
		volume_m3 = 0.4
	body.mass = clampf(volume_m3 * MASS_PER_M3, MIN_MASS_KG, MAX_MASS_KG)


func _prune_dead() -> void:
	var kept: Array[RigidBody3D] = []
	for body: RigidBody3D in _active:
		if is_instance_valid(body) and not body.is_queued_for_deletion():
			kept.append(body)
	_active = kept


func _enforce_cap() -> void:
	var cap := IndustryArchetypeProfile.floating_chunks_max_bodies()
	if cap <= 0:
		return
	_prune_dead()
	while _active.size() > cap:
		var oldest: RigidBody3D = _active.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
