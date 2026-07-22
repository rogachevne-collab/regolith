@tool
class_name Rope3D
extends Node3D
## A simulated rope hanging between two anchors.
##
## Endpoints follow [member anchor_a] and [member anchor_b]; an empty anchor
## path leaves that end free. Simulation state is read back with
## [method get_particles] and [method get_segment_tension].
##
## STATUS: API draft. There is no simulation behind this node yet.

## Rest length in meters. May be changed at runtime: the rope pays out and
## reels in at anchor A (the winch end), smoothly re-segmenting.
@export_range(0.1, 1000.0, 0.1, "or_greater", "suffix:m") var length: float = 5.0

## Simulated particles per meter. Higher = smoother bends, more CPU.
@export_range(1.0, 16.0, 0.5) var segments_per_meter: float = 4.0

## Linear density, kg per meter.
@export_range(0.01, 100.0, 0.01, "or_greater", "suffix:kg/m") var mass_per_meter: float = 0.5

## Visual and collision radius in meters.
@export_range(0.005, 0.5, 0.005, "suffix:m") var radius: float = 0.02

@export_group("Anchors")
## Node3D the first particle is pinned to. A PhysicsBody3D also receives
## reaction impulses (two-way coupling). Empty = free end.
@export var anchor_a: NodePath
## Node3D the last particle is pinned to. Same rules as [member anchor_a].
@export var anchor_b: NodePath

@export_group("Collision")
## Whether the rope collides with the world.
@export var collision_enabled: bool = true
## Physics layers the rope collides with.
@export_flags_3d_physics var collision_mask: int = 1


## Number of simulated particles (segment count + 1).
func get_particle_count() -> int:
	return 0


## Particle positions in global space; index 0 is at anchor A.
func get_particles() -> PackedVector3Array:
	return PackedVector3Array()


## Tension in Newtons of the segment between particles i and i + 1.
func get_segment_tension(_i: int) -> float:
	return 0.0
