class_name GranularAnchor
extends RefCounted
## Where a `GranularPatch` sits in the world.
##
## A patch is a flat height field and the world is a sphere, so a patch is
## always a tangent plane: `up` is the radial at its centre and thickness is
## measured along that up. Locally that is exact enough — the sagitta of a
## 16 m patch on a 9.5 km body is about 3 mm, an order under one cell — and it
## is why loose material lives in many small patches instead of one map:
## the spoil heap outside an adit, the floor of a shaft and the lip of a
## crater are three different tangent planes. Spec: `docs/specs/GRANULAR-V0.md`.
##
## Patch-local metres run 0..(width-1) * cell_size on both axes, matching the
## cell indices `GranularPatch` uses, and the patch is centred on
## `center_world`. Heights are metres along `up` from the tangent plane.

const _SCRIPT := preload("res://scripts/simulation/runtime/granular_anchor.gd")

const EPSILON := 1e-6

## World position of the centre of the grid.
var center_world := Vector3.ZERO
## Orthonormal patch frame: Y is local up, X and Z span the tangent plane.
var basis := Basis.IDENTITY
var width: int = 0
var depth: int = 0
var cell_size: float = GranularPatch.DEFAULT_CELL_SIZE_M


static func create(
	new_center_world: Vector3,
	up: Vector3,
	new_width: int,
	new_depth: int,
	new_cell_size: float = GranularPatch.DEFAULT_CELL_SIZE_M,
	hint_forward: Vector3 = Vector3.FORWARD
) -> GranularAnchor:
	var anchor: GranularAnchor = _SCRIPT.new()
	anchor.center_world = new_center_world
	anchor.basis = tangent_basis(up, hint_forward)
	anchor.width = maxi(new_width, 1)
	anchor.depth = maxi(new_depth, 1)
	anchor.cell_size = maxf(new_cell_size, 0.01)
	return anchor


## Right-handed frame with Y along `up`. The tangent axes are arbitrary — no
## gameplay reads them — so they are derived deterministically from `up` alone
## rather than from anything frame-dependent, or two peers would build
## different grids for the same hole.
static func tangent_basis(
	up: Vector3,
	hint_forward: Vector3 = Vector3.FORWARD
) -> Basis:
	var y := up
	if y.length_squared() <= EPSILON:
		y = Vector3.UP
	y = y.normalized()
	var x := hint_forward.slide(y)
	if x.length_squared() <= EPSILON:
		x = Vector3.RIGHT.slide(y)
	if x.length_squared() <= EPSILON:
		x = Vector3.FORWARD.slide(y)
	x = x.normalized()
	return Basis(x, y, x.cross(y))


## Half the grid span in metres, on the two tangent axes.
func half_extent() -> Vector2:
	return Vector2(
		float(width - 1) * cell_size * 0.5,
		float(depth - 1) * cell_size * 0.5
	)


func up() -> Vector3:
	return basis.y


## Node transform that puts patch-local metres (before the half-extent shift)
## into world space — what a view node uses so its mesh can be built in cell
## coordinates.
func world_transform() -> Transform3D:
	return Transform3D(basis, center_world)


## World point to patch-local `(x_m, height_m, z_m)`. X and Z are the grid
## axes, height is along local up from the tangent plane.
func to_patch(world_point: Vector3) -> Vector3:
	# The basis is orthonormal, so its inverse is its transpose.
	var local := basis.transposed() * (world_point - center_world)
	var half := half_extent()
	return Vector3(local.x + half.x, local.y, local.z + half.y)


func to_world(x_m: float, z_m: float, height_m: float) -> Vector3:
	var half := half_extent()
	return center_world + basis * Vector3(x_m - half.x, height_m, z_m - half.y)


## Nearest cell to a patch-local point, clamped into the grid.
func cell_at(x_m: float, z_m: float) -> Vector2i:
	return Vector2i(
		clampi(int(round(x_m / cell_size)), 0, width - 1),
		clampi(int(round(z_m / cell_size)), 0, depth - 1)
	)


## Whether a world point falls on the grid, optionally requiring a margin of
## clear cells around it. Callers use the margin to insist a dig lands well
## inside a patch rather than on its lip, where the spoil ring would be cut in
## half by the border.
func covers(world_point: Vector3, margin_m: float = 0.0) -> bool:
	var local := to_patch(world_point)
	var span_x := float(width - 1) * cell_size
	var span_z := float(depth - 1) * cell_size
	return (
		local.x >= margin_m
		and local.z >= margin_m
		and local.x <= span_x - margin_m
		and local.z <= span_z - margin_m
	)


## How far a point is above (positive) or below the tangent plane. A patch
## whose centre is metres away along the radial is a different patch, even
## when the point projects onto its grid — the floor of a shaft is not the
## surface it was sunk from.
func height_above_plane(world_point: Vector3) -> float:
	return to_patch(world_point).y
