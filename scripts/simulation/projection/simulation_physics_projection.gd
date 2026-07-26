class_name SimulationPhysicsProjection
extends Node3D

const XpbdCableRopeSolverScript := preload(
	"res://scripts/simulation/projection/xpbd_cable_rope_solver.gd"
)

## When on, placed cables use the Ropes! XPBD core with gate-4 pin reactions
## inside [XpbdCableRopeSolver] — [method CablePhysicsTickCoordinator.tick_cable_tension]
## is skipped.
@export var use_xpbd_cable_rope := true

var _world: SimulationWorld
var _assembly_physics_material: PhysicsMaterial
var _locomotive_physics_material: PhysicsMaterial
var _bodies: Dictionary = {}
## assembly_id -> consecutive settled physics frames under parking brake.
var _park_settle_frames: Dictionary = {}
var _element_records: Dictionary = {}
var _projected_revision: Dictionary = {}
var _mounted_bodies: Dictionary = {}
var _collision_profiles: Dictionary = {}
var _body_groups: Dictionary = {}
var _assembly_group_bodies: Dictionary = {}
var _piston_constraints: Dictionary = {}
var _rotor_constraints: Dictionary = {}
## assembly_id -> Array[Dictionary] wheel constraint records (WHEEL-BODY-V1).
var _wheel_constraints: Dictionary = {}
var _root_group_ids: Dictionary = {}
var _impact_service: ImpactResolverService
var _cable_anchor_probe_cooldown := 0.0
## link_id → rope solver state (CableRopeSolver or XpbdCableRopeSolver).
var _rope_states: Dictionary = {}
var _rope_collision_cursor := 0
## link_id → slackest overshoot seen since this rope last thawed an endpoint.
## See CablePhysicsTickCoordinator.ROPE_WAKE_OVERSHOOT_M and wake_roped_bodies.
var _rope_wake_overshoot: Dictionary = {}
## Drivers reparented off bodies about to queue_free (seat entry + Static→Rigid
## / multibody reproject). Restored onto the live seat body after rebuild —
## otherwise Player+Camera die with the old RigidBody and the viewport shows
## only default_clear_color.
var _evacuated_drivers: Array[Dictionary] = []
## PERF-H03: `_bodies` / `_wheel_constraints` only change on structural
## mutation (project/remove a body, rebuild wheel constraints), not every
## physics tick — bump on those sites instead of re-sorting+allocating a
## fresh key array from scratch in every one of the several per-tick passes
## below (parking-freeze scan, wheel tick, motion capture).
var _tick_key_structure_rev := 0
var _tick_key_cache_rev := -1
var _bodies_keys_cache: Array[int] = []
var _wheel_constraints_keys_cache: Array[int] = []
## Co-op owner-authoritative locomotion: assemblies this peer simulates with
## full Jolt (wheel joints) even when `world.authoritative` is false (guest
## driver). Host keeps guest-owned assemblies in `_ghost_assemblies` as
## kinematic receivers of the owner's state stream.
var _local_sim_assemblies: Dictionary = {}
var _ghost_assemblies: Dictionary = {}

## Diagnostic only (PERF-COOP-REGRESS): Performance.TIME_PHYSICS_PROCESS
## measures the whole engine iteration — PhysicsServer3D::sync/flush_queries,
## every node's _physics_process() (this one included), THEN
## PhysicsServer3D::step() (main/main.cpp Main::iteration) — so it cannot
## tell GDScript tick cost apart from the native Jolt step. This breaks that
## number down by sub-tick so the overlay/bench can show where our own script
## time goes instead of guessing. Cheap (a handful of get_ticks_usec() calls
## per physics tick) — not a hot-path allocation, R9-safe.
var _last_tick_breakdown_us: Dictionary = {}
## Wall-clock timestamp (usec) this node's _physics_process last returned.
## Performance.TIME_PHYSICS_PROCESS is USELESS for per-tick measurement: it is
## set exactly once per real-world second to the WORST single tick seen in
## that second and holds that value for the rest of the second (confirmed in
## engine source, main/main.cpp Main::iteration — `if (frame > 1000000) {
## performance->set_physics_process_time(...); frame = 0; }`, `frame` being a
## running sum of elapsed usec). Sampling it every tick and averaging (as an
## earlier pass here did) just averages repeated copies of last second's
## worst spike — not a real per-tick average.
## The wall-clock gap between "our script ends this tick" and "our script
## starts next tick" is a real measurement instead: per main.cpp's physics
## loop, that gap is exactly nav processing + PhysicsServer3D::step()
## (native Jolt) + message_queue.flush() + iteration_end() + the next tick's
## PhysicsServer3D::sync()/flush_queries() — i.e. everything OUTSIDE our own
## GDScript, dominated in practice by the native step. Works the same whether
## or not the engine is running multiple physics substeps per rendered frame.
var _prev_tick_end_us := -1
## Bumped every physics tick so pollers (bench/overlay) sampling once per
## rendered frame can tell whether a new tick actually landed since their
## last read, instead of re-averaging the same stale dictionary N times when
## render FPS > physics Hz.
var _tick_seq := 0

func get_last_tick_breakdown_us() -> Dictionary:
	return _last_tick_breakdown_us


## True when this peer should build wheel/actuator joints and integrate Jolt
## for the assembly (host world, or guest driving locally).
func simulates_assembly_physics(assembly_id: int) -> bool:
	if assembly_id <= 0:
		return false
	if _ghost_assemblies.has(assembly_id):
		return false
	if _world != null and _world.authoritative:
		return true
	return _local_sim_assemblies.has(assembly_id)


func begin_local_assembly_sim(assembly_id: int) -> void:
	if assembly_id <= 0 or _local_sim_assemblies.has(assembly_id):
		return
	_local_sim_assemblies[assembly_id] = true
	StructuralEventCoordinator.reproject_assembly(self, assembly_id)
	wake_assembly_bodies(assembly_id)


## Drop-and-rebuild local sim after snapshot restore (bodies were cleared;
## the flag alone would leave begin_local_assembly_sim as a no-op).
func rebind_local_assembly_sim(assembly_id: int) -> void:
	if assembly_id <= 0:
		return
	_local_sim_assemblies.erase(assembly_id)
	begin_local_assembly_sim(assembly_id)


func end_local_assembly_sim(assembly_id: int) -> void:
	if assembly_id <= 0 or not _local_sim_assemblies.has(assembly_id):
		return
	_local_sim_assemblies.erase(assembly_id)
	StructuralEventCoordinator.reproject_assembly(self, assembly_id)


func set_assembly_network_ghost(assembly_id: int, ghost: bool) -> void:
	if assembly_id <= 0:
		return
	var was_ghost := _ghost_assemblies.has(assembly_id)
	if ghost:
		_ghost_assemblies[assembly_id] = true
	else:
		_ghost_assemblies.erase(assembly_id)
	if was_ghost == ghost:
		return
	StructuralEventCoordinator.reproject_assembly(self, assembly_id)


func _ensure_tick_key_caches() -> void:
	if _tick_key_cache_rev == _tick_key_structure_rev:
		return
	_tick_key_cache_rev = _tick_key_structure_rev
	_bodies_keys_cache = AssemblyTeardownCoordinator.sorted_int_keys(_bodies)
	_wheel_constraints_keys_cache = AssemblyTeardownCoordinator.sorted_int_keys(
		_wheel_constraints
	)

func bind_impact_service(service: ImpactResolverService) -> void:
	_impact_service = service

func bind_world(world: SimulationWorld) -> void:
	if _world == world:
		return
	unbind_world()
	_world = world
	if _world != null:
		_world.structural_event.connect(_on_structural_event)
		rebuild_all()

func unbind_world() -> void:
	if (
		_world != null
		and _world.structural_event.is_connected(_on_structural_event)
	):
		_world.structural_event.disconnect(_on_structural_event)
	_world = null

func rebuild_all() -> void:
	AssemblyTeardownCoordinator.clear_all_bodies(self)
	if _world == null:
		AssemblyTeardownCoordinator.restore_evacuated_drivers(self)
		return
	for assembly: SimulationAssembly in _world.list_assemblies():
		if not assembly.tombstoned:
			AssemblyProjectionCoordinator.project_assembly(
				self,
				assembly.assembly_id,
				null
			)
	AssemblyTeardownCoordinator.restore_evacuated_drivers(self)

## All live rigid bodies for an assembly (root or multibody groups). Used by
## visual projection to find a removed element's mesh after element_records
## were cleared on incremental physics remove.

func list_assembly_physics_bodies(assembly_id: int) -> Array[PhysicsBody3D]:
	var out: Array[PhysicsBody3D] = []
	var groups: Variant = _assembly_group_bodies.get(assembly_id)
	if groups is Dictionary:
		for body_variant: Variant in (groups as Dictionary).values():
			if body_variant is PhysicsBody3D and is_instance_valid(body_variant):
				out.append(body_variant as PhysicsBody3D)
		return out
	var body := get_physics_body(assembly_id)
	if body != null and is_instance_valid(body):
		out.append(body)
	return out

func get_physics_body(assembly_id: int) -> PhysicsBody3D:
	return _bodies.get(assembly_id) as PhysicsBody3D

func get_group_physics_body(assembly_id: int, group_id: int) -> PhysicsBody3D:
	var groups: Variant = _assembly_group_bodies.get(assembly_id)
	if groups is Dictionary:
		return groups.get(group_id) as PhysicsBody3D
	return null

func list_piston_constraint_records(assembly_id: int) -> Array:
	if not _piston_constraints.has(assembly_id):
		return []
	var records: Variant = _piston_constraints[assembly_id]
	if records is Array:
		return (records as Array).duplicate()
	return []

func list_wheel_constraint_records(assembly_id: int) -> Array:
	if not _wheel_constraints.has(assembly_id):
		return []
	var records: Variant = _wheel_constraints[assembly_id]
	if records is Array:
		return (records as Array).duplicate()
	return []

func list_rotor_constraint_records(assembly_id: int) -> Array:
	if not _rotor_constraints.has(assembly_id):
		return []
	var records: Variant = _rotor_constraints[assembly_id]
	if records is Array:
		return (records as Array).duplicate()
	return []

func get_element_projection(element_id: int) -> Dictionary:
	var record: Variant = _element_records.get(element_id)
	if record is Dictionary:
		return record
	return {}

func get_element_colliders(
	element_id: int
) -> Array[CollisionShape3D]:
	var result: Array[CollisionShape3D] = []
	var record: Dictionary = get_element_projection(element_id)
	for collider: CollisionShape3D in record.get("colliders", []):
		result.append(collider)
	return result

func compute_b_to_a_grid(
	assembly_a_id: int,
	assembly_b_id: int
) -> GridTransform:
	return SimulationMergeGateway.compute_b_to_a_grid(
		_world,
		assembly_a_id,
		assembly_b_id
	)

func set_collision_profile(
	assembly_id: int,
	layer: int,
	mask: int
) -> void:
	_collision_profiles[assembly_id] = {
		"layer": layer,
		"mask": mask,
	}
	var body := get_physics_body(assembly_id)
	if body != null:
		AssemblyBodyBuildCoordinator.apply_collision_profile(self, assembly_id, body)

func add_body_group(assembly_id: int, group_name: String) -> void:
	if group_name.is_empty():
		return
	var groups: Array = _body_groups.get(assembly_id, [])
	if not groups.has(group_name):
		groups.append(group_name)
	_body_groups[assembly_id] = groups
	var body: PhysicsBody3D = get_physics_body(assembly_id)
	if body != null and body is RigidBody3D:
		(body as RigidBody3D).add_to_group(group_name)

func project_assembly_now(
	assembly_id: int,
	motion_override: AssemblyMotionState = null
) -> void:
	if get_physics_body(assembly_id) != null:
		AssemblyTeardownCoordinator.remove_body(self, assembly_id)
	AssemblyProjectionCoordinator.project_assembly(self, assembly_id, motion_override)
	AssemblyTeardownCoordinator.restore_evacuated_drivers(self)

func sync_body_motion_now(assembly_id: int) -> bool:
	return PhysicsMotionSyncCoordinator.sync_body_motion_now(self, assembly_id)

func align_body_motion(
	target_assembly_id: int,
	reference_assembly_id: int
) -> bool:
	return PhysicsMotionSyncCoordinator.align_body_motion(
		self,
		target_assembly_id,
		reference_assembly_id
	)

func wake_assembly_bodies(assembly_id: int) -> void:
	AssemblyParkingFreezeCoordinator.wake_assembly_bodies(self, assembly_id)

func wake_frozen_near(center: Vector3, radius: float) -> void:
	AssemblyParkingFreezeCoordinator.wake_frozen_near(self, center, radius)

func is_rope_frozen(link_id: int) -> bool:
	var state: Variant = _rope_states.get(link_id)
	if state is Dictionary:
		# A cable with sim state is being simulated, so it is dynamic by
		# definition: frozen only if it settled. The static-structure check
		# below would always be false here, so skip it — this runs per link per
		# frame from _material_for (R9).
		return not (state as Dictionary).get("_frozen", {}).is_empty()
	# No state = the rope tick never ran for it = both ends on bodies it cannot
	# hang on. The only such case that should exist is a cable on an anchored
	# static structure, which is frozen by construction.
	return CablePhysicsTickCoordinator.cable_on_shared_static(self, link_id)

func rope_path(link_id: int) -> PackedVector3Array:
	var state: Variant = _rope_states.get(link_id)
	if state is Dictionary:
		# A frozen cable is not solved at all, so its live positions are stale
		# by however long it has been frozen. The shape it froze in is kept in
		# its body's frame; putting it back into the world is the only work a
		# frozen cable ever does, and only when something asks to draw it.
		var frozen: Dictionary = state.get("_frozen", {})
		if not frozen.is_empty():
			# Guest join can rebuild an assembly's physics bodies without
			# bumping topology_revision (the frozen shape's only invalidation
			# key), so the cached body here can outlive its instance. Check
			# validity on the untyped Variant first — assigning a freed
			# instance straight into a typed RigidBody3D var errors on the
			# assignment itself, before any null/validity check runs.
			var body_variant: Variant = frozen.get("body")
			if body_variant is RigidBody3D and is_instance_valid(body_variant):
				var body := body_variant as RigidBody3D
				var xf := body.global_transform
				var out := PackedVector3Array()
				for point: Vector3 in (frozen.get("path_local") as PackedVector3Array):
					out.append(xf * point)
				return out
		if use_xpbd_cable_rope:
			return XpbdCableRopeSolverScript.path(state)
		return CableRopeSolver.path(state)
	return PackedVector3Array()

func _physics_process(delta: float) -> void:
	# Replica: skip unless a local driver owns an assembly (owner-authoritative
	# locomotion). Ghost assemblies on the host stay frozen and are skipped by
	# wheel/parking gates via simulates_assembly_physics / freeze.
	if _world == null:
		return
	if not _world.authoritative and _local_sim_assemblies.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var native_gap_us := (t0 - _prev_tick_end_us) if _prev_tick_end_us >= 0 else -1
	_ensure_tick_key_caches()
	var t_rotor := Time.get_ticks_usec()
	ActuatorPhysicsTickCoordinator.tick_rotor_actuators(self, delta)
	var t_piston := Time.get_ticks_usec()
	ActuatorPhysicsTickCoordinator.tick_piston_actuators(self, delta)
	var t_wheel := Time.get_ticks_usec()
	WheelPhysicsTickCoordinator.tick_wheel_bodies(self, delta)
	var t_thruster := Time.get_ticks_usec()
	ActuatorPhysicsTickCoordinator.tick_thrusters(self, delta)
	var t_rope := Time.get_ticks_usec()
	# Ropes stay host-authoritative — replica owner-sim is locomotion only.
	if _world.authoritative:
		CablePhysicsTickCoordinator.tick_cable_ropes(self, delta)
		CablePhysicsTickCoordinator.tick_cable_tension(self, delta)
		CablePhysicsTickCoordinator.tick_cable_anchors(self, delta)
	var t_sync := Time.get_ticks_usec()
	PhysicsMotionSyncCoordinator.sync_live_assembly_motions(self)
	var t_end := Time.get_ticks_usec()
	_last_tick_breakdown_us = {
		"key_cache": t_rotor - t0,
		"rotor": t_piston - t_rotor,
		"piston": t_wheel - t_piston,
		"wheel_bodies": t_thruster - t_wheel,
		"thrusters": t_rope - t_thruster,
		"cable": t_sync - t_rope,
		"motion_sync": t_end - t_sync,
		"total": t_end - t0,
		"native_gap_since_prev_tick": native_gap_us,
	}
	_prev_tick_end_us = t_end
	_tick_seq += 1
	_last_tick_breakdown_us["tick_seq"] = _tick_seq

func _exit_tree() -> void:
	unbind_world()
	AssemblyTeardownCoordinator.clear_all_bodies(self)
	# Bodies stop reporting the moment they are freed, so anything still mid
	# blow-up has to be closed out here or the run's worst episode is the one
	# that never reaches the file.
	VelocityGuard.flush()

## Structural events (place / dismantle / split / merge) live in
## [StructuralEventCoordinator]. This stays a plain non-static method: it is the
## exact Callable connected in bind_world and disconnected in unbind_world, and
## Callable.bind would append the projection AFTER the signal argument —
## on_structural_event(event, projection) instead of (projection, event).

func _on_structural_event(event: Dictionary) -> void:
	StructuralEventCoordinator.on_structural_event(self, event)
