class_name RopeBenchVerletAdapter
extends RefCounted
## Bench adapter for Regolith's current verlet rope (CableRopeSolver).
##
## Lives on the game side of the fence, not in addons/ropes: the bench is meant
## to outlive this implementation and must not know it exists. Everything
## implementation-specific — how a rope is created, what counts as asleep, which
## number a tension model would act on — is answered here.

var _space: PhysicsDirectSpaceState3D


func create(
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_m: float,
	space: PhysicsDirectSpaceState3D
) -> Variant:
	_space = space
	return CableRopeSolver.create_state(
		anchor_a,
		anchor_b,
		rest_m,
		Vector3.UP,
		space
	)


func step(
	handle: Variant,
	anchor_a: Vector3,
	anchor_b: Vector3,
	rest_m: float,
	gravity: Vector3,
	delta: float
) -> void:
	CableRopeSolver.step(
		handle,
		anchor_a,
		anchor_b,
		rest_m,
		gravity,
		delta,
		_space
	)


func points(handle: Variant) -> PackedVector3Array:
	return CableRopeSolver.path(handle)


## The length the tension model acts on. For this solver that is the solved
## length, deliberately not the drawn polyline — the difference between those
## two is what used to destroy machines.
func reported_length(handle: Variant) -> float:
	return CableRopeSolver.routed_length_m(handle)


func is_asleep(handle: Variant) -> bool:
	if not handle is Dictionary:
		return false
	var state: Dictionary = handle
	return (
		int(state.get("quiescent_ticks", 0)) > CableRopeSolver.SLEEP_AFTER_TICKS
	)
