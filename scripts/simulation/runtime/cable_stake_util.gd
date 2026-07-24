class_name CableStakeUtil
extends RefCounted
## Ground anchor for a cable run.
##
## A rope end that landed on terrain used to be stored as `element_id == 0`: a
## point in the world with nothing at it. Such an end is invisible, cannot be
## removed and cannot be destroyed — and, the part that actually matters,
## [method IndustryElectricPortUtil.link_still_valid] drops any link whose
## endpoint is not a real element carrying an electric port. A cable pegged to
## the ground therefore conducted nothing at all; it was a decorative rope.
##
## The stake is what makes ground routing exist: a one-element assembly, frozen
## where it was driven, with a contact on top. Route A→B→C over two stakes and
## the electric graph — plain adjacency over element ids — sees one component,
## so power flows the length of the run. Break the middle stake and the run
## breaks exactly there.

const STAKE_ARCHETYPE: ElementArchetype = preload(
	"res://resources/archetypes/slice01/cable_stake.tres"
)

## How deep the stake goes below the clicked surface point, metres. Without it
## the stake balances on its own foot like a pencil stood on a table: it reads
## as dropped rather than driven, and the anchor holding it up is invisible.
const SINK_DEPTH_M := 0.25

## Height above the CLICKED point where the rope ties on, metres. The stake is
## two construction cells tall (1 m) and a quarter of that is underground, so
## this lands on the upper part of what is actually sticking out.
const TIE_HEIGHT_M := 0.6

## A click this close to a standing stake ties onto it instead of driving a
## new one. Roughly the stake's own height: near enough that the player means
## that stake, far enough that a deliberate second stake still fits beside it.
const REUSE_RADIUS_M := 1.0


## The stake for a rope end at [param point]: the one already standing there
## if there is one, a freshly driven one otherwise. Returns its element id, or
## 0 if none could be placed — no materials, or the cell is taken. Callers must
## fail the whole connect on 0 rather than fall back to a world-pinned end:
## that fallback silently rebuilds the dead cable this exists to prevent.
##
## Reuse is what makes a routed run work. Chaining A→B→C, the second span
## starts from the same ground click the first one ended on, and driving a
## second stake into the first one's hole would leave the run split in two at a
## point that looks like one. Reuse also does the obvious thing when a player
## deliberately ties a third cable onto a stake that is already carrying two.
## The result carries `element_id` on success and the placement's own failure
## reason otherwise — collapsing every way a stake can fail to refuse into one
## code tells the player "no materials" when the truth was "that cell is taken".
static func ensure(world, point: Vector3, up: Vector3) -> StructuralCommandResult:
	var existing := find_near(world, point)
	if existing > 0:
		return StructuralCommandResult.ok({"element_id": existing})
	return drive(world, point, up)


## Stake already standing within [constant REUSE_RADIUS_M] of [param point], or
## 0. The comparison is against the element's group origin rather than its
## foot, so it carries up to a cell of slop — deliberately: two stakes that
## close are one stake as far as anyone playing can tell, and the wanted answer
## in that case is reuse anyway.
static func find_near(world, point: Vector3) -> int:
	var best := 0
	var best_distance := REUSE_RADIUS_M
	for element_id_variant: Variant in world._elements.keys():
		var element_id := int(element_id_variant)
		var element: SimulationElement = world._elements[element_id]
		if element == null or element.archetype_id != STAKE_ARCHETYPE.archetype_id:
			continue
		var origin: Vector3 = world.element_group_transform(element_id).origin
		var distance := origin.distance_to(point)
		if distance <= best_distance:
			best = element_id
			best_distance = distance
	return best


## Drive a new stake at [param point], standing along [param up]. Prefer
## [method ensure] — this one always adds one.
##
## A stake stands along gravity, not along the surface normal, because that is
## how a stake is driven: hammered down, not laid perpendicular to a slope.
##
## This does not go through [method ConstructionCommandService.place_element],
## and the reason is worth writing down: that path is the contract for a block
## the PLAYER builds, and it enforces the whole contract — a build cost, a
## store to bill, terrain the block can be anchored against. A stake fails all
## three for the same reason. It is not bought, nobody's inventory is involved,
## and it is placed by the act of routing a cable rather than by the build
## tool. The archetype is `internal_archetype`, the same category piston heads
## live in: parts the world places and the player can still grind off.
static func drive(world, point: Vector3, up: Vector3) -> StructuralCommandResult:
	if not world._archetypes.register(STAKE_ARCHETYPE):
		return StructuralCommandResult.failed(
			StructuralCommandResult.REASON_ARCHETYPE_CONFLICT
		)
	var basis := upright_basis(up)
	var assembly := SimulationAssembly.new()
	assembly.assembly_id = world._allocator.allocate_assembly_id()
	assembly.grid_frame = GridSpawnUtil.grid_frame_from_transform(
		Transform3D(basis, point)
	)
	# The grid frame is snapped, the continuous root is not: the stake's foot
	# lands on the clicked point rather than on the corner of whatever cell the
	# click fell into. Same split the build tool uses when it drops a block on a
	# slope — topology on the grid, pose in the world. Frozen, because a stake
	# that can be dragged is not an anchor.
	var contact := GridPoseUtil.ground_contact_local(STAKE_ARCHETYPE, 0)
	assembly.motion = GridSpawnUtil.motion_from_transform(
		Transform3D(basis, point - basis * contact - basis.y * SINK_DEPTH_M),
		true
	)
	var element_id: int = world._allocator.allocate_element_id()
	var element := SimulationElement.frame(
		element_id,
		assembly.assembly_id,
		STAKE_ARCHETYPE,
		Vector3i.ZERO,
		0,
		{}
	)
	var joint_ids: Array[int] = []
	var allocate_joint := func() -> int:
		return world._allocator.allocate_joint_id()
	for joint: SimulationJoint in RuntimeConnectivity.materialize_ground_start_anchors(
		assembly.assembly_id,
		[element],
		allocate_joint
	):
		world._register_joint(joint)
		joint_ids.append(joint.joint_id)
	element.terrain_contact = true
	world._assemblies[assembly.assembly_id] = assembly
	world._elements[element_id] = element
	assembly.element_ids.append(element_id)
	IndustryStoreService.sync_element_storage(world, element)
	assembly.bump_revision()
	world._notify_topology_changed(assembly.assembly_id)
	joint_ids.sort()
	world._emit_structural_event({
		"kind": &"assembly_spawned",
		"assembly_id": assembly.assembly_id,
		"topology_revision": assembly.topology_revision,
		"element_ids": assembly.element_ids.duplicate(),
		"placed_element_id": element_id,
		"joint_ids": joint_ids,
	})
	return StructuralCommandResult.ok({"element_id": element_id})


## Where a rope ties onto a stake driven at [param foot]: near the top, where
## the contact is and where a hand would tie it, not at the ground line. The
## point is world-space; storage localizes it into the stake's frame like any
## other block-clipped end.
static func tie_point(foot: Vector3, up: Vector3) -> Vector3:
	var axis := up.normalized() if up.length_squared() > 1e-12 else Vector3.UP
	return foot + axis * TIE_HEIGHT_M


## Orthonormal basis with Y along [param up]. X and Z are arbitrary: a stake
## has no facing anybody can tell apart.
static func upright_basis(up: Vector3) -> Basis:
	var y := up.normalized() if up.length_squared() > 1e-12 else Vector3.UP
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 1e-6:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	return Basis(x, y, x.cross(y))
