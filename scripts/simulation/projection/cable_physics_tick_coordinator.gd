class_name CablePhysicsTickCoordinator
extends RefCounted
## Cable/rope physics tick cluster extracted from SimulationPhysicsProjection.

const MIN_MASS := 0.001
const CABLE_ROPE_COLLISION_BUDGET := 320
const CABLE_ANCHOR_PROBE_INTERVAL_S := 0.33
const CABLE_ANCHOR_PROBE_RADIUS := 0.3
const CABLE_FREEZE_BODY_LIN_M_S := 0.05
const CABLE_FREEZE_BODY_ANG_R_S := 0.05
const CABLE_FREEZE_TICKS := 30
const CABLE_FREEZE_TIMEOUT_TICKS := 180
const ROPE_WAKE_OVERSHOOT_M := 0.001
const ACTUATOR_BACKING_MAX_LINKS := 16
const XpbdCableRopeSolverScript := preload(
	"res://scripts/simulation/projection/xpbd_cable_rope_solver.gd"
)

static func tick_cable_ropes(
	projection,
	delta: float) -> void:
	if projection._world == null or delta <= 0.0:
		return
	# Avoid list_links().duplicate() every tick when the yard has no ropes.
	if projection._world.get_industry_network().rope_link_count() <= 0:
		projection._rope_states = {}
		return
	var ropes: Array[IndustryElectricLink] = []
	for link: IndustryElectricLink in projection._world.get_industry_network().list_links():
		if link.is_rope():
			ropes.append(link)
	if ropes.is_empty():
		projection._rope_states = {}
		return
	var space_state: PhysicsDirectSpaceState3D = projection.get_world_3d().direct_space_state
	var collision_budget := CablePhysicsTickCoordinator.CABLE_ROPE_COLLISION_BUDGET
	projection._rope_collision_cursor = (projection._rope_collision_cursor + 1) % ropes.size()
	var live: Dictionary = {}
	var snapped: Array[int] = []
	for offset: int in range(ropes.size()):
		var link: IndustryElectricLink = ropes[
			(offset + projection._rope_collision_cursor) % ropes.size()
		]
		var state: Variant = projection._rope_states.get(link.link_id)
		# A cable that was baked before a save comes back baked: seed the frozen
		# state straight from the persisted shape, so it is static from frame one
		# and never pays the settle spike again. Only when it has no runtime state
		# yet (fresh load) — after that the normal fast path owns it.
		if not (state is Dictionary) and not link.baked_path_local.is_empty():
			state = CablePhysicsTickCoordinator.seed_frozen_from_bake(projection, link)
			if state != null:
				projection._rope_states[link.link_id] = state
		# Frozen fast path, before anything is computed. A frozen cable is a
		# solved shape riding its body; the only work it can need is to notice
		# the machine changed under it. We do not re-derive that from geometry
		# every tick — the assembly already counts its own structural mutations
		# in topology_revision, so this is one dict lookup and two compares, and
		# a frozen cable costs nothing else: no anchor resolve, no body lookup,
		# no solver step. Any weld, grind, split or merge on that assembly bumps
		# the revision — and the cable is then re-routed analytically and re-baked
		# on the spot. Baked is baked: it does not go back to the solver
		# (see cable_frozen_current).
		if CablePhysicsTickCoordinator.cable_frozen_current(projection, link, state):
			live[link.link_id] = state
			continue
		var anchor_a := CableAnchorUtil.endpoint_world_position(
			projection._world,
			link.element_a,
			link.port_a,
			link.attach_a
		)
		var anchor_b := CableAnchorUtil.endpoint_world_position(
			projection._world,
			link.element_b,
			link.port_b,
			link.attach_b
		)
		var gravity := GravityField.resolve_gravity_accel(
			projection,
			(anchor_a + anchor_b) * 0.5
		)
		var up := -gravity.normalized() if gravity.length_squared() > 0.0 else Vector3.UP
		if projection.use_xpbd_cable_rope:
			collision_budget = CablePhysicsTickCoordinator.tick_one_xpbd_rope(projection, 
				link,
				state,
				anchor_a,
				anchor_b,
				gravity,
				up,
				delta,
				space_state,
				collision_budget,
				live,
				snapped
			)
		else:
			collision_budget = CablePhysicsTickCoordinator.tick_one_verlet_rope(projection, 
				link,
				state,
				anchor_a,
				anchor_b,
				gravity,
				up,
				delta,
				space_state,
				collision_budget,
				live
			)
	projection._rope_states = live
	for link_id: int in snapped:
		projection._world.disconnect_network(0, "", 0, "", link_id)


static func tick_one_verlet_rope(
	projection,
	link: IndustryElectricLink,
	state: Variant,
	anchor_a: Vector3,
	anchor_b: Vector3,
	gravity: Vector3,
	up: Vector3,
	delta: float,
	space_state: PhysicsDirectSpaceState3D,
	collision_budget: int,
	live: Dictionary
) -> int:
	if not state is Dictionary:
		state = CableRopeSolver.create_state(
			anchor_a,
			anchor_b,
			link.rest_length_m,
			up,
			space_state
		)
	var particles := CableRopeSolver.path(state).size()
	var collides := space_state != null and collision_budget >= particles
	if collides:
		collision_budget -= particles
	CableRopeSolver.step(
		state,
		anchor_a,
		anchor_b,
		link.rest_length_m,
		gravity,
		delta,
		space_state,
		collides
	)
	live[link.link_id] = state
	return collision_budget


static func tick_one_xpbd_rope(
	projection,
	link: IndustryElectricLink,
	state: Variant,
	anchor_a: Vector3,
	anchor_b: Vector3,
	gravity: Vector3,
	up: Vector3,
	delta: float,
	space_state: PhysicsDirectSpaceState3D,
	collision_budget: int,
	live: Dictionary,
	snapped: Array[int]
) -> int:
	var body_a := CablePhysicsTickCoordinator.rope_endpoint_body(projection, link.element_a)
	var body_b := CablePhysicsTickCoordinator.rope_endpoint_body(projection, link.element_b)
	if body_a == null and body_b == null:
		return collision_budget
	# A cable with both ends on ONE body cannot change shape by being driven
	# around: in that body's own frame nothing is moving. Once it has settled
	# it is frozen — the solved shape is kept in body-local space and simply
	# rides along, costing nothing per tick. This is the battery-to-distributor
	# case, eight of which on a rover were paying full XPBD to hang perfectly
	# still. A lifting cable or one crossing an actuator has its ends on
	# DIFFERENT bodies and never reaches this path, which is the whole reason
	# the condition is "same body" rather than a decorative/utility flag
	# somebody has to author.
	var shared_body: RigidBody3D = (
		body_a if body_a != null and body_a == body_b else null
	)
	# A frozen cable is caught by the tick loop's fast path and never reaches
	# here — either it was never frozen, or it stopped being bakeable at all and
	# cable_frozen_current thawed it (clearing _frozen and resetting the settle
	# counter). A stale bake alone does not land here: that is re-routed in place.
	# So there is nothing to clean up here, and touching _still_ticks would reset
	# the very counter cable_try_freeze is trying to accumulate at the end of
	# this function.
	if not state is Dictionary:
		state = CablePhysicsTickCoordinator.XpbdCableRopeSolverScript.create_state(
			anchor_a,
			anchor_b,
			link.rest_length_m,
			up,
			space_state
		)
	if state is Dictionary:
		CablePhysicsTickCoordinator.wake_roped_bodies(projection, 
			link.link_id,
			body_a,
			body_b,
			CableTensionUtil.effective_overshoot_m(
				CablePhysicsTickCoordinator.XpbdCableRopeSolverScript.routed_length_m(state),
				link.rest_length_m
			)
		)
	# A same-body cable never collides with the world (see step's collide_world):
	# it is strapped to one chassis and projection-collision with that jittering
	# chassis is the energy pump that kept it awake. It also costs no collision
	# budget — which is the whole reason the freeze path exists.
	var collide_world := shared_body == null
	var particles := CablePhysicsTickCoordinator.XpbdCableRopeSolverScript.path(state).size()
	var collides := collide_world and space_state != null and collision_budget >= particles
	if collides:
		collision_budget -= particles
	# ROPE-CHAIN-V0: mass-couple the movable end when the other end is
	# anchored, so a taut MECHANICAL rope/chain pulls the load up to the fixed
	# point (lift) or drags it along (tow) instead of only pinning. Only when
	# the link is MECHANICAL and the ends are on different bodies; a same-body
	# utility cable (shared_body) still freezes, an ELECTRIC cable still pins —
	# it conducts and tugs back, it does not move the bodies it is tied to.
	var couple_a := 0.0
	var couple_b := 0.0
	if link.is_mechanical() and shared_body == null:
		var a_movable := body_a != null and not body_a.freeze
		var b_movable := body_b != null and not body_b.freeze
		if a_movable and not b_movable:
			couple_a = maxf(body_a.mass, 0.001)
		elif b_movable and not a_movable:
			couple_b = maxf(body_b.mass, 0.001)
		elif a_movable and b_movable:
			# Two free bodies: pin-only ends pump energy through rope/body
			# collision. Mass-couple the lagging end so tow force transmits.
			collide_world = false
			collides = false
			var span := anchor_a.distance_to(anchor_b)
			if span > link.rest_length_m + 0.01:
				var axis := anchor_b - anchor_a
				var axis_len_sq := axis.length_squared()
				if axis_len_sq > 1e-6:
					axis /= sqrt(axis_len_sq)
					var va := CablePhysicsTickCoordinator._endpoint_axis_velocity(
						body_a, anchor_a, axis
					)
					var vb := CablePhysicsTickCoordinator._endpoint_axis_velocity(
						body_b, anchor_b, axis
					)
					var follower: int = int(state.get("_mech_follower_end", -1))
					if follower < 0:
						follower = 1 if va < vb else 0
						state["_mech_follower_end"] = follower
					if follower == 0 and va > vb:
						couple_a = maxf(body_a.mass, MIN_MASS)
					elif follower == 1 and vb > va:
						couple_b = maxf(body_b.mass, MIN_MASS)
	var result: Dictionary = CablePhysicsTickCoordinator.XpbdCableRopeSolverScript.step(
		state,
		anchor_a,
		anchor_b,
		link.rest_length_m,
		gravity,
		delta,
		space_state,
		collides,
		body_a,
		body_b,
		CablePhysicsTickCoordinator.rope_endpoint_backing(projection, body_a),
		CablePhysicsTickCoordinator.rope_endpoint_backing(projection, body_b),
		link.break_force_n,
		collide_world,
		couple_a,
		couple_b
	)
	if bool(result.get("snapped", false)):
		snapped.append(link.link_id)
		return collision_budget
	live[link.link_id] = state
	if shared_body != null:
		CablePhysicsTickCoordinator.cable_try_freeze(projection, state, link, shared_body)
	CablePhysicsTickCoordinator.wake_roped_bodies(projection, 
		link.link_id,
		body_a,
		body_b,
		float(result.get("overshoot_m", 0.0))
	)
	return collision_budget


# --- frozen cables -----------------------------------------------------------


## Freeze a same-body cable once its host has been at rest long enough for the
## cable to hang itself. This is the ONLY time the solver ever shapes such a
## cable: from here on it stays baked for good, and a machine change under it is
## answered by re-routing the baked shape, not by simulating again (see
## cable_frozen_current). The at-rest counter RESETS the moment the host moves,
## so a cable never freezes mid-shake.


static func cable_try_freeze(
	projection,
	state: Dictionary,
	link: IndustryElectricLink,
	body: RigidBody3D
) -> void:
	var sim = state.get("sim")
	if sim == null:
		return
	# The assembly and the revision it is at now. This is the whole waking
	# mechanism: the assembly counts its own structural mutations, so a frozen
	# cable watches one integer instead of re-deriving "did the machine change"
	# from geometry every tick.
	var element: SimulationElement = projection._world.get_element(link.element_a)
	if element == null:
		return
	var assembly: SimulationAssembly = projection._world.get_assembly_raw(element.assembly_id)
	if assembly == null:
		return
	# Two ways to freeze, whichever comes first. The clean one: the host is at
	# rest (parked or asleep), so the cable has hung itself and we snapshot a
	# settled shape — this is the common yard case. The guaranteed one: the
	# cable has simply been alive long enough. That fallback exists because a
	# rover chassis on 6DOF wheel joints often NEVER reads at rest — the
	# suspension keeps it micro-jittering above any honest velocity floor — so
	# a rest-only gate meant its cables never froze and never tinted, which is
	# exactly the report. A cable bolted between two points on one frame is the
	# same shape whether that frame is parked or bouncing, so freezing it on age
	# is safe; the worst case is a snapshot a few millimetres off, invisible on
	# a taut utility cable and re-taken on the next structural change anyway.
	var at_rest := (
		body.freeze
		or body.sleeping
		or (
			body.linear_velocity.length() < CablePhysicsTickCoordinator.CABLE_FREEZE_BODY_LIN_M_S
			and body.angular_velocity.length() < CablePhysicsTickCoordinator.CABLE_FREEZE_BODY_ANG_R_S
		)
	)
	var still := (int(state.get("_still_ticks", 0)) + 1) if at_rest else 0
	state["_still_ticks"] = still
	var age := int(state.get("_age_ticks", 0)) + 1
	state["_age_ticks"] = age
	if still < CablePhysicsTickCoordinator.CABLE_FREEZE_TICKS and age < CablePhysicsTickCoordinator.CABLE_FREEZE_TIMEOUT_TICKS:
		return
	# Everything the frozen shape is only true FOR is recorded next to it, so
	# waking is a comparison rather than a guess.
	var to_local := body.global_transform.affine_inverse()
	var path_local := PackedVector3Array()
	for point: Vector3 in sim.positions:
		path_local.append(to_local * point)
	state["_frozen"] = {
		# Body only for rendering: rope_path rides the frozen local shape on this
		# transform. Waking never reads it — that is the assembly revision below.
		"body": body,
		"path_local": path_local,
		"assembly_id": assembly.assembly_id,
		"revision": assembly.topology_revision,
		"rest_m": link.rest_length_m,
	}
	# Persist the baked shape onto the link so it survives a save (see
	# IndustryElectricLink.baked_path_local). The link is body-local, so it is
	# valid for the machine exactly as it stands; _thaw clears it the instant the
	# machine changes.
	link.baked_path_local = path_local


## The tick-loop fast path: is this a frozen cable whose machine has not changed
## under it? One dict lookup on the state, one on the assembly, two compares —
## and if it holds, the caller skips the entire rope tick for this cable.
##
## The stamp is entirely the assembly's own change-reporting. Any weld, grind,
## split or merge on that assembly bumps its topology_revision; the assembly
## vanishing (a split re-roots into new ids) fails the lookup. The winch is the
## one change that is a link property rather than an assembly mutation, so rest
## length is compared directly. Nothing here reads the cable's geometry or the
## body's pose: a driving, tilting, slamming machine changes none of these
## numbers, and that is the point — the cable is bolted to the frame and rides
## it for free.
##
## A stale stamp does NOT mean "simulate again". Baked is baked: the cable is
## re-routed analytically against the machine as it now stands and re-baked in
## the same tick (see reroute_and_rebake). Re-settling a strapped utility cable
## in the solver bought nothing a hanging curve does not give — it just paid a
## settle spike on every weld, on every cable on that machine at once.


static func cable_frozen_current(
	projection,
	link: IndustryElectricLink, state: Variant) -> bool:
	if not state is Dictionary:
		return false
	var frozen: Dictionary = (state as Dictionary).get("_frozen", {})
	if frozen.is_empty():
		return false
	var assembly: SimulationAssembly = projection._world.get_assembly_raw(int(frozen.get("assembly_id", 0)))
	if (
		is_equal_approx(float(frozen.get("rest_m", -1.0)), link.rest_length_m)
		and assembly != null
		and assembly.topology_revision == int(frozen.get("revision", -1))
	):
		return true
	return CablePhysicsTickCoordinator.reroute_and_rebake(projection, state as Dictionary, link)


## The machine changed under a baked cable, so the baked shape is stale — but a
## strapped utility cable does not need a solver to know what it looks like. Lay
## it again as a hanging curve between its endpoints as they now stand
## (CableCurveUtil, the same shape the routing preview draws) and re-bake in the
## same tick: no thaw, no settle window, no solver step, and the mesh never sees
## an intermediate frame.
##
## The one honest cost: an analytic curve does not drape over geometry, so a
## cable that would have laid itself over a newly welded part becomes a plain
## span across it. On a short taut cable bolted along one frame that is invisible;
## it is the reason this path is only ever taken for same-body cables.
##
## Resolution comes from the link, not from the old stamp: a split re-roots the
## assembly into fresh ids, so the id recorded beside the old shape can be gone
## while the cable itself is perfectly fine on its new host. Only two things send
## a cable back to the solver — losing its body, or its ends no longer sharing
## one. Both mean it stopped being the kind of cable a bake can describe.


static func reroute_and_rebake(
	projection,
	state: Dictionary, link: IndustryElectricLink) -> bool:
	var element: SimulationElement = projection._world.get_element(link.element_a)
	if element == null:
		CablePhysicsTickCoordinator.thaw(projection, state, link)
		return false
	var assembly: SimulationAssembly = projection._world.get_assembly_raw(element.assembly_id)
	var body := CablePhysicsTickCoordinator.rope_endpoint_body(projection, link.element_a)
	if (
		assembly == null
		or body == null
		or body != CablePhysicsTickCoordinator.rope_endpoint_body(projection, link.element_b)
	):
		CablePhysicsTickCoordinator.thaw(projection, state, link)
		return false
	var anchor_a := CableAnchorUtil.endpoint_world_position(
		projection._world,
		link.element_a,
		link.port_a,
		link.attach_a
	)
	var anchor_b := CableAnchorUtil.endpoint_world_position(
		projection._world,
		link.element_b,
		link.port_b,
		link.attach_b
	)
	var gravity := GravityField.resolve_gravity_accel(
		projection,
		(anchor_a + anchor_b) * 0.5
	)
	var up := -gravity.normalized() if gravity.length_squared() > 0.0 else Vector3.UP
	# Same point count the solver would have produced for this span, so the mesh
	# keeps its resolution across a re-bake instead of visibly coarsening.
	var segments := maxi(
		CablePhysicsTickCoordinator.XpbdCableRopeSolverScript.particle_count(
			link.rest_length_m, anchor_a.distance_to(anchor_b)
		) - 1,
		1
	)
	var to_local := body.global_transform.affine_inverse()
	var path_local := PackedVector3Array()
	for point: Vector3 in CableCurveUtil.sample_span(
		anchor_a, anchor_b, link.rest_length_m, up, segments
	):
		path_local.append(to_local * point)
	state["_frozen"] = {
		"body": body,
		"path_local": path_local,
		"assembly_id": assembly.assembly_id,
		"revision": assembly.topology_revision,
		"rest_m": link.rest_length_m,
	}
	link.baked_path_local = path_local
	return true


## Seed a frozen state directly from a link's persisted bake — a cable that was
## baked before a save, coming back static without a single simulation tick. The
## shape is body-local, so it needs the current host body and the assembly's
## revision now; if the endpoints no longer share a live body the bake is stale
## (the machine was rebuilt in a way saves cannot carry) and is dropped.


static func seed_frozen_from_bake(
	projection,
	link: IndustryElectricLink) -> Variant:
	var element: SimulationElement = projection._world.get_element(link.element_a)
	if element == null:
		link.baked_path_local = PackedVector3Array()
		return null
	var assembly: SimulationAssembly = projection._world.get_assembly_raw(element.assembly_id)
	var body := CablePhysicsTickCoordinator.rope_endpoint_body(projection, link.element_a)
	if assembly == null or body == null or body != CablePhysicsTickCoordinator.rope_endpoint_body(projection, link.element_b):
		link.baked_path_local = PackedVector3Array()
		return null
	return {"_frozen": {
		"body": body,
		"path_local": link.baked_path_local,
		"assembly_id": assembly.assembly_id,
		"revision": assembly.topology_revision,
		"rest_m": link.rest_length_m,
	}}


## Give a cable back to the solver: drop its frozen shape, its at-rest counter
## and the persisted bake. This is now the rare path — a stale bake is re-routed
## in place, so the only cables that land here are the ones a bake can no longer
## describe at all (body gone, or the two ends no longer on one body). Such a
## cable is a genuinely different cable and has to be re-solved from scratch.
##
## The counter reset matters: it must get the full settle window before it can
## freeze again, or a still machine re-freezes the very next tick and snapshots
## the stale shape it had before the change. Clearing the link's bake matters
## too, or a save taken mid-thaw would restore the old shape.


static func thaw(
	projection,
	state: Dictionary, link: IndustryElectricLink) -> void:
	state.erase("_frozen")
	state["_still_ticks"] = 0
	state["_age_ticks"] = 0
	if link != null:
		link.baked_path_local = PackedVector3Array()

## Whether this cable is not being simulated, so presentation can tint it.
## Two ways to be still: a same-body cable that settled and froze (a solved
## shape riding its body), or a cable strung between two points on an ANCHORED
## structure — which projects as a StaticBody3D, has no RigidBody for the rope
## tick to hang on, and so is drawn as a static curve and never simulated at
## all. The second case was reading as "live" and staying dark even though it
## is the most frozen thing in the world: bolted to a base that cannot move.


static func cable_on_shared_static(
	projection,
	link_id: int) -> bool:
	var link: IndustryElectricLink = projection._world.get_industry_network().get_link(link_id)
	if link == null or not link.is_rope():
		return false
	var element_a: SimulationElement = projection._world.get_element(link.element_a)
	var element_b: SimulationElement = projection._world.get_element(link.element_b)
	if element_a == null or element_b == null:
		return false
	if element_a.assembly_id != element_b.assembly_id:
		return false
	var body: PhysicsBody3D = projection.get_physics_body(element_a.assembly_id)
	return body != null and not (body is RigidBody3D)


static func tick_cable_tension(
	projection,
	delta: float) -> void:
	if projection._world == null or delta <= 0.0 or projection.use_xpbd_cable_rope:
		return
	var snapped: Array[int] = []
	var seen: Dictionary = {}
	for link: IndustryElectricLink in projection._world.get_industry_network().list_links():
		if not link.is_rope():
			continue
		var body_a := CablePhysicsTickCoordinator.rope_endpoint_body(projection, link.element_a)
		var body_b := CablePhysicsTickCoordinator.rope_endpoint_body(projection, link.element_b)
		if body_a == null and body_b == null:
			continue
		seen[link.link_id] = true
		var anchor_a := CableAnchorUtil.endpoint_world_position(
			projection._world,
			link.element_a,
			link.port_a,
			link.attach_a
		)
		var anchor_b := CableAnchorUtil.endpoint_world_position(
			projection._world,
			link.element_b,
			link.port_b,
			link.attach_b
		)
		var tension_n := 0.0
		var backing_a := CablePhysicsTickCoordinator.rope_endpoint_backing(projection, body_a)
		var backing_b := CablePhysicsTickCoordinator.rope_endpoint_backing(projection, body_b)
		var state: Variant = projection._rope_states.get(link.link_id)
		if state is Dictionary:
			# Draped over a rock the rope runs longer than the straight span and
			# hits its limit sooner, and it pulls along its own first segment —
			# toward what it is draped over, not through it.
			# Deadbanded, like the pull itself: a rope resting on the world
			# reports a few centimetres of solver noise, and treating that as
			# load kept thawing parked machines forever.
			CablePhysicsTickCoordinator.wake_roped_bodies(projection, 
				link.link_id,
				body_a,
				body_b,
				CableTensionUtil.effective_overshoot_m(
					CableRopeSolver.routed_length_m(state),
					link.rest_length_m
				)
			)
			tension_n = CableTensionUtil.solve_routed(
				anchor_a,
				body_a,
				CableRopeSolver.pull_direction(state, true),
				anchor_b,
				body_b,
				CableRopeSolver.pull_direction(state, false),
				CableRopeSolver.routed_length_m(state),
				link.rest_length_m,
				delta,
				link.break_force_n,
				backing_a,
				backing_b
			)
		else:
			CablePhysicsTickCoordinator.wake_roped_bodies(projection, 
				link.link_id,
				body_a,
				body_b,
				CableTensionUtil.effective_overshoot_m(
					anchor_a.distance_to(anchor_b),
					link.rest_length_m
				)
			)
			tension_n = CableTensionUtil.solve(
				anchor_a,
				body_a,
				anchor_b,
				body_b,
				link.rest_length_m,
				delta,
				link.break_force_n,
				backing_a,
				backing_b
			)
		if tension_n > CableTensionUtil.break_force_n(link.break_force_n):
			snapped.append(link.link_id)
	for link_id: int in projection._rope_wake_overshoot.keys():
		if not seen.has(link_id):
			projection._rope_wake_overshoot.erase(link_id)
	for link_id: int in snapped:
		projection._world.disconnect_network(0, "", 0, "", link_id)

## A rope may only pull what physics will listen to. A parked assembly is a
## frozen RigidBody3D, and CableTensionUtil reads frozen as "world anchor" — so
## a crane rigged to a parked machine pulled against a wall: the machine never
## moved, and because the tension was only ever what it took to arrest the light
## end, the rope never even snapped. It just stretched.
##
## Thawing here rather than inside the solver keeps freeze policy in the layer
## that owns it (and lets projection._park_settle_frames be reset in the same breath).
##
## Only a rope that is running FURTHER out wakes anything. A rope that merely
## hangs taut does no work, and waking on tautness alone would fight
## _update_parking_freeze forever — it refreezes a settled rover every
## PARK_FREEZE_SETTLE_FRAMES, we would thaw it the next tick, and a moored rover
## would never sleep again. The baseline tracks the slackest the rope has been
## since the last wake, so a winch that takes up a millimetre a second still
## eventually crosses the threshold.


static func wake_roped_bodies(
	projection,
	link_id: int,
	body_a: RigidBody3D,
	body_b: RigidBody3D,
	overshoot_m: float
) -> void:
	if overshoot_m <= 0.0:
		# Slack rope: re-arm, so the next time it goes taut counts as a pull.
		projection._rope_wake_overshoot.erase(link_id)
		return
	var frozen_a := body_a != null and body_a.freeze
	var frozen_b := body_b != null and body_b.freeze
	if not frozen_a and not frozen_b:
		projection._rope_wake_overshoot[link_id] = overshoot_m
		return
	var baseline: float = float(projection._rope_wake_overshoot.get(link_id, 0.0))
	if overshoot_m <= baseline + CablePhysicsTickCoordinator.ROPE_WAKE_OVERSHOOT_M:
		projection._rope_wake_overshoot[link_id] = minf(baseline, overshoot_m)
		return
	projection._rope_wake_overshoot[link_id] = overshoot_m
	if frozen_a:
		CablePhysicsTickCoordinator.wake_roped_body(projection, body_a)
	if frozen_b:
		CablePhysicsTickCoordinator.wake_roped_body(projection, body_b)


static func wake_roped_body(
	projection,
	body: RigidBody3D) -> void:
	body.freeze = false
	body.sleeping = false
	var assembly_id: int = int(body.get_meta("assembly_id", 0))
	if assembly_id > 0:
		projection._park_settle_frames[assembly_id] = 0

## A rope end hammered into the ground holds on to the ground, not to a point
## in space: dig it out and the anchor tears loose. Probed a few times a second
## — it is a shape query per anchored rope, and terrain never vanishes mid-tick.


static func tick_cable_anchors(
	projection,
	delta: float) -> void:
	if projection._world == null:
		return
	projection._cable_anchor_probe_cooldown -= delta
	if projection._cable_anchor_probe_cooldown > 0.0:
		return
	if projection._world.get_industry_network().rope_link_count() <= 0:
		projection._cable_anchor_probe_cooldown = CablePhysicsTickCoordinator.CABLE_ANCHOR_PROBE_INTERVAL_S
		return
	projection._cable_anchor_probe_cooldown = CablePhysicsTickCoordinator.CABLE_ANCHOR_PROBE_INTERVAL_S
	var space_state: PhysicsDirectSpaceState3D = projection.get_world_3d().direct_space_state
	if space_state == null:
		return
	# Dig the ground out from under a cable's ground anchor and the cable tears
	# loose. The anchor is a stake now rather than a bare world point
	# ([CableStakeUtil]), so the question moved with it: it is the stake that
	# loses its footing, and the cables hanging off it go when it does.
	var torn: Array[int] = []
	var undermined: Array[int] = []
	for link: IndustryElectricLink in projection._world.get_industry_network().list_links():
		if not link.is_rope():
			continue
		for endpoint_id: int in [link.element_a, link.element_b]:
			if not CablePhysicsTickCoordinator.is_cable_stake(projection, endpoint_id):
				continue
			# Judge a stake only while it is actually projected. Unprojected
			# means the player is elsewhere and terrain collision that far out
			# is simply not streamed in — an unloaded chunk is not a hole.
			if projection.get_element_projection(endpoint_id).is_empty():
				continue
			# Probe the ground the stake was driven into, which is the point
			# the player clicked: the tie sits most of a metre up the stake and
			# would never find ground under it, and the assembly's own origin
			# is offset by the grid pose and buried by the sink depth. Walking
			# back down from the tie — through the very helper that positions
			# the rope end — is the one reconstruction that cannot disagree
			# with where the rope actually hangs.
			var attach: Vector3 = (
				link.attach_a if endpoint_id == link.element_a else link.attach_b
			)
			var tie := CableAnchorUtil.endpoint_world_position(
				projection._world, endpoint_id, "", attach
			)
			var stake_up: Vector3 = projection._world.element_group_transform(endpoint_id).basis.y
			if stake_up.length_squared() < 1e-6:
				continue
			var surface: Vector3 = tie - stake_up.normalized() * CableStakeUtil.TIE_HEIGHT_M
			if TerrainAnchorProbe.point_has_ground_support(
				space_state,
				surface,
				CablePhysicsTickCoordinator.CABLE_ANCHOR_PROBE_RADIUS
			):
				continue
			if not torn.has(link.link_id):
				torn.append(link.link_id)
			if not undermined.has(endpoint_id):
				undermined.append(endpoint_id)
	for link_id: int in torn:
		projection._world.disconnect_network(0, "", 0, "", link_id)
	for element_id: int in undermined:
		var stake: SimulationElement = projection._world.get_element(element_id)
		if stake != null:
			# No refund and no store: nobody bought the stake, so nobody is
			# owed anything back when the ground takes it.
			projection._world._remove_element_from_topology(stake, 0, 0.0, null)


static func is_cable_stake(
	projection,
	element_id: int) -> bool:
	if element_id <= 0:
		return false
	var element: SimulationElement = projection._world.get_element(element_id)
	return (
		element != null
		and element.archetype_id == CableStakeUtil.STAKE_ARCHETYPE.archetype_id
	)


static func rope_endpoint_body(
	projection,
	element_id: int) -> RigidBody3D:
	if element_id <= 0:
		return null
	return projection.get_element_projection(element_id).get("body") as RigidBody3D

## What a rope tied to this body is really pulling against. See CableTensionUtil
## for the why; the short version is that a piston carriage is held on its axis
## by a motor, so the rope pulls the machine behind the piston, limited by what
## that motor is rated for — not by the carriage's own few dozen kilos.
##
## Walks up nested pistons (a piston mounted on a piston) keeping the weakest
## rating in the chain, bounded by the same link limit the actuator chains use
## so a malformed chain cannot spin here.
##
## An unpowered or stalled piston reports a live limit of 0 (see
## _tick_piston_actuators): its motor is holding nothing, so the end falls back
## to its own mass and the carriage is simply dragged. Rotor and hinge arms are
## deliberately not walked — their rating is a torque, and turning that into a
## rope force needs the lever arm, not just a mass.


static func _endpoint_axis_velocity(
	body: RigidBody3D,
	anchor: Vector3,
	axis: Vector3
) -> float:
	if body == null or body.freeze:
		return 0.0
	var vel := body.linear_velocity + body.angular_velocity.cross(anchor - body.global_position)
	return vel.dot(axis)


static func rope_endpoint_backing(
	projection,
	body: RigidBody3D) -> Dictionary:
	var force_cap_n := INF
	var current: PhysicsBody3D = body
	for _link: int in range(CablePhysicsTickCoordinator.ACTUATOR_BACKING_MAX_LINKS):
		var record: Dictionary = ActuatorPhysicsTickCoordinator.piston_record_for_head(
			projection,
			current
		)
		if record.is_empty():
			break
		var sim_joint: SimulationJoint = record.get("sim_joint")
		if sim_joint == null or sim_joint.motor == null:
			break
		var live_limit_n := float(
			record.get("motor_limit_n", sim_joint.motor.force_limit_n)
		)
		if live_limit_n <= 0.0:
			return {}
		force_cap_n = minf(force_cap_n, live_limit_n)
		current = record.get("base_body") as PhysicsBody3D
		if current == null:
			break
	if current == body:
		return {}
	if current is RigidBody3D:
		return {
			"inverse_mass": 1.0 / maxf((current as RigidBody3D).mass, AssemblyBodyBuildCoordinator.MIN_MASS),
			"force_cap_n": force_cap_n,
			"reaction_body": current as RigidBody3D,
		}
	# StaticBody3D (or nothing): the piston is bolted to something nailed down.
	return {
		"inverse_mass": 0.0,
		"force_cap_n": force_cap_n,
		"reaction_body": null,
	}

