class_name CoopAssemblyMotionUtil
extends RefCounted


## Non-wheel body poses + per-wheel scalars. Empty if assembly unknown, or
## (when `require_live`) parked under the speed gate. Guest owner-upload passes
## `require_live=false` so the host ghost keeps updating at crawl / airborne.
static func pack_assembly_motion_entry(
	session,
	assembly_id: int,
	require_live: bool = true
) -> Dictionary:
	var world: SimulationWorld = session._world()
	if world == null:
		return {}
	var assembly: SimulationAssembly = world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.motion == null:
		return {}
	var root_id := world.root_body_group_id(assembly_id)
	if root_id <= 0:
		return {}
	var wheel_gids: Dictionary = wheel_group_ids(session, assembly_id)
	var moving := motion_is_live(session, assembly.motion)
	var motions: Dictionary = {root_id: assembly.motion.to_dict()}
	for group_id_variant: Variant in assembly.body_group_motions:
		var group_id := int(group_id_variant)
		if wheel_gids.has(group_id):
			continue
		var group_motion: AssemblyMotionState = (
			assembly.body_group_motions[group_id_variant]
		)
		if group_motion == null:
			continue
		motions[group_id] = group_motion.to_dict()
		moving = moving or motion_is_live(session, group_motion)
	if require_live and not moving:
		return {}
	return {
		"m": motions,
		"w": pack_wheel_scalars(session, assembly_id),
	}


static func wheel_group_ids(session, assembly_id: int) -> Dictionary:
	var world: SimulationWorld = session._world()
	if world == null:
		return {}
	var out: Dictionary = {}
	var compiled: Dictionary = world.compile_body_groups(assembly_id)
	for spec_variant: Variant in compiled.get("wheel_specs", []):
		if not spec_variant is Dictionary:
			continue
		var gid := int(spec_variant.get("wheel_group_id", 0))
		if gid > 0:
			out[gid] = true
	return out


static func pack_wheel_scalars(session, assembly_id: int) -> Dictionary:
	var world: SimulationWorld = session._world()
	if world == null:
		return {}
	var out: Dictionary = {}
	var compiled: Dictionary = world.compile_body_groups(assembly_id)
	for spec_variant: Variant in compiled.get("wheel_specs", []):
		if not spec_variant is Dictionary:
			continue
		var wheel_id := int(spec_variant.get("wheel_element_id", 0))
		var group_id := int(spec_variant.get("wheel_group_id", 0))
		if wheel_id <= 0:
			continue
		var runtime: Dictionary = world.get_wheel_runtime(wheel_id)
		if runtime.is_empty():
			continue
		out[wheel_id] = {
			"c": float(runtime.get("compression_m", 0.0)),
			"s": float(runtime.get("steering_angle_rad", 0.0)),
			"v": float(
				runtime.get(
					"wheel_speed_rad_s",
					runtime.get("wheel_speed", 0.0)
				)
			),
			"g": group_id,
		}
	return out


static func unpack_assembly_stream_entry(packed: Dictionary) -> Dictionary:
	# New shape: {"m": motions, "w": wheels}. Legacy: flat group_id → motion.
	if packed.has("m") and packed["m"] is Dictionary:
		return {
			"motions_raw": packed["m"] as Dictionary,
			"wheels": (
				packed["w"] as Dictionary
				if packed.get("w") is Dictionary
				else {}
			),
		}
	return {"motions_raw": packed, "wheels": {}}


static func motion_is_live(session, motion: AssemblyMotionState) -> bool:
	if motion.frozen or motion.sleeping:
		return false
	return (
		motion.linear_velocity.length_squared() > session.ASSEMBLY_SPEED_SQ
		or motion.angular_velocity.length_squared() > session.ASSEMBLY_SPIN_SQ
	)
