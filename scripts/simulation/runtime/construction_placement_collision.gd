class_name ConstructionPlacementCollision
extends RefCounted
## World-space guard that Space-Engineers-style construction relies on: the grid
## kernel only knows about the target assembly's own occupancy, so cross-assembly
## overlap, terrain penetration and standing-in-the-way of the player are invisible
## to it. This runs a physics `intersect_shape` per placed collider (in the plan's
## final world pose) and rejects the placement when it would clip something it must
## not:
##
## - **another construction (static or dynamic)** — forbidden for every block;
## - **the player body** — forbidden for every block (no more building into
##   yourself and getting shoved out);
## - **the terrain** — forbidden only for physical/machine elements (drill, piston,
##   rotor, …). Plain structural blocks (`full_surface`) may clip terrain by design.

const COLLISION_LAYER_TERRAIN := 1
const COLLISION_LAYER_ASSEMBLY := 2
const COLLISION_LAYER_PLAYER := 4

## Every collider half-extent is shrunk by this before the query so a block resting
## flush on terrain, or snapped face-to-face against the neighbour it attaches to,
## is not misread as penetration — only genuine volume overlap trips the guard.
const OVERLAP_MARGIN_M := 0.06
const MAX_QUERY_RESULTS := 16

const REASON_STRUCTURE_OVERLAP := &"structure_overlap"
const REASON_TERRAIN_OVERLAP := &"terrain_overlap"
const REASON_PLAYER_BLOCKED := &"player_blocked"


## A physical element is anything that is not a plain structural block. Structural
## blocks use `full_surface` attachment (frame, beam, foundation, pipe, cockpit);
## everything else — machines, actuators, the drill — is physical and must not be
## buried in terrain.
static func is_physical_element(archetype: ElementArchetype) -> bool:
	if archetype == null:
		return false
	return (
		archetype.resolved_structural_surface_policy()
		!= ElementArchetype.StructuralSurfacePolicy.FULL_SURFACE
	)


## Returns an empty StringName when the placement is clear, otherwise the reason it
## must be rejected. `target_assembly_id` is the assembly the block attaches to
## (`0` for a fresh ground assembly); its bodies are ignored — flush contact with
## the thing you build onto is expected, and same-assembly cell overlap is already
## caught by the kernel.
static func evaluate(
	space_state: PhysicsDirectSpaceState3D,
	archetype: ElementArchetype,
	root_transform: Transform3D,
	origin_cell: Vector3i,
	orientation_index: int,
	target_assembly_id: int,
	terrain: Node3D
) -> StringName:
	if space_state == null or archetype == null:
		return &""
	var physical := is_physical_element(archetype)
	var mask := COLLISION_LAYER_ASSEMBLY | COLLISION_LAYER_PLAYER
	if physical:
		mask |= COLLISION_LAYER_TERRAIN
	for collider: ColliderDefinition in archetype.colliders:
		var collider_transform := GridPoseUtil.collider_world_transform(
			root_transform,
			origin_cell,
			orientation_index,
			collider
		)
		var shape := _shrunk_shape(collider)
		if shape == null:
			continue
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = shape
		params.transform = collider_transform
		params.collide_with_bodies = true
		params.collide_with_areas = false
		# Zero the query margin so the deliberate shape shrink above is the only
		# tolerance; the default 0.04 margin would inflate the shape and partly
		# cancel it, turning flush contact into a false overlap.
		params.margin = 0.0
		params.collision_mask = mask
		for hit: Dictionary in space_state.intersect_shape(
			params,
			MAX_QUERY_RESULTS
		):
			var reason := _classify_hit(
				hit.get("collider"),
				target_assembly_id,
				physical,
				terrain
			)
			if reason != &"":
				return reason
	return &""


static func _classify_hit(
	collider_object: Variant,
	target_assembly_id: int,
	physical: bool,
	terrain: Node3D
) -> StringName:
	if collider_object == null:
		return &""
	if (
		collider_object is Node
		and (collider_object as Node).is_in_group(ImpactResolver.PLAYER_GROUP)
	):
		return REASON_PLAYER_BLOCKED
	if collider_object is CollisionObject3D:
		var body := collider_object as CollisionObject3D
		if body.has_meta("assembly_id"):
			var hit_assembly := int(body.get_meta("assembly_id"))
			# The assembly we attach to is allowed to touch us; the kernel already
			# rejects overlap within it. Any other assembly is a real collision.
			if target_assembly_id != 0 and hit_assembly == target_assembly_id:
				return &""
			return REASON_STRUCTURE_OVERLAP
	if physical and TerrainCompat.is_terrain_collider(collider_object, terrain):
		return REASON_TERRAIN_OVERLAP
	return &""


static func _shrunk_shape(collider: ColliderDefinition) -> Shape3D:
	match collider.shape_kind:
		ColliderDefinition.ShapeKind.CYLINDER:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = maxf(
				collider.size.x * 0.5 - OVERLAP_MARGIN_M,
				0.01
			)
			cylinder.height = maxf(
				collider.size.y - OVERLAP_MARGIN_M * 2.0,
				0.02
			)
			return cylinder
		_:
			var box := BoxShape3D.new()
			box.size = Vector3(
				maxf(collider.size.x - OVERLAP_MARGIN_M * 2.0, 0.02),
				maxf(collider.size.y - OVERLAP_MARGIN_M * 2.0, 0.02),
				maxf(collider.size.z - OVERLAP_MARGIN_M * 2.0, 0.02)
			)
			return box
