class_name GranularPressSource
extends Node3D
## A load bearing on loose material: a wheel, a landing pad, a block that came
## to rest on a heap. Hang one on anything that should leave the ground pushed
## down where it has been.
##
## Displacement, not compaction — see `GranularVoxelWorld.press_at`, which is
## the whole of the mechanism. This node only decides *when* a press happens and
## *how hard*; it owns no physics of its own.
##
## Deliberately not driven by contact reports. A wheel that asks the physics
## engine who it is touching needs contact monitoring on, and then every caller
## has to rate-limit itself or four wheels press the field sixty times a second
## each. Asking the field how deep this point is standing in it costs one column
## walk, works identically for a wheel and for a dropped crate, and puts the
## rate limit in one place. What it cannot express is impact: a block dropped
## from a height presses exactly as hard as a block set down gently. That is the
## known limit of this version, and the reason to reach for real contacts later
## is force, not correctness.
##
## Costs nothing where there is no loose material, which is nearly everywhere:
## `dust_at` is a handful of bounds checks when no region covers the point.

## Radius of the contact patch. A wheel's is roughly its width, not its
## diameter — what presses is the part actually on the ground.
@export var radius_m := 0.35
## Scales the whole press. One is the world's own `PRESS_SHARE`; lower it for
## something light, raise it for something that should bite.
@export var strength := 1.0
## Share of the loose material under the patch that one press moves. Small: a
## wheel presses many times a second and the rut should deepen over a second of
## driving, not appear under the first touch.
@export var share := 0.12
## Presses per second. Well under the physics rate on purpose: a rut should
## deepen over a second of driving, not appear under the first touch, and the
## field has to be given time to slump between presses or the shoulders of the
## rut never form.
@export var press_hz := 12.0
## How far below this node the bearing surface sits, along local up. Zero means
## the node is already at the contact point, which is the easy way to rig it —
## put the marker where the tyre meets the ground.
@export var contact_offset_m := 0.0
@export var enabled := true

var _granular_world: Node
var _debt := 0.0


func _physics_process(delta: float) -> void:
	if not enabled or radius_m <= 0.0:
		return
	_debt += delta * press_hz
	if _debt < 1.0:
		return
	# Never more than one press per tick however far behind the debt has run:
	# a frame spike must not be paid back as a burst of presses in one place.
	_debt = fmod(_debt, 1.0)
	var world := _world()
	if world == null:
		return
	var up := GravityField.resolve_up(self, global_position)
	var point := global_position - up * contact_offset_m
	var column := Dictionary(world.call(&"dust_at", point))
	if column.is_empty():
		return
	# How far the bearing point stands *below* the surface of the material.
	# Negative means it is clear of it — a wheel in the air over a heap, which
	# is exactly the case a plain "is there dust here" test would get wrong.
	var surface: Vector3 = column["surface"]
	var penetration := (surface - point).dot(up)
	if penetration <= 0.0:
		return
	# Harder the deeper it is in, saturating once the contact patch is buried.
	# There is no impulse here to read, so depth stands in for load: something
	# heavy sinks further before the ground stops it, and presses harder for it.
	var bite := clampf(penetration / radius_m, 0.0, 1.0)
	# A wheel compacts rather than occupies, so it takes a little at a time and
	# leaves the world's own bedding floor in place — see `press_at`.
	world.call(&"press_at", point, radius_m, share * strength * bite)


## The loose-material world, found by group so nothing here depends on it
## existing — scenes without granular material simply never find one. Same
## arrangement as `character_motor`.
func _world() -> Node:
	if _granular_world != null and is_instance_valid(_granular_world):
		return _granular_world
	_granular_world = get_tree().get_first_node_in_group(&"granular_world")
	return _granular_world
