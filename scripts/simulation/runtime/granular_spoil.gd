class_name GranularSpoil
extends RefCounted
## Rock removed from the SDF, turned into loose material on a `GranularPatch`.
##
## This is the join the granular layer existed for: `terrain_carve` deletes
## solid ground and reports the volume, and that volume has to land somewhere
## instead of vanishing. Spec: `docs/specs/GRANULAR-V0.md`.

## Bulking of solid rock broken into spoil. Real regolith swells 10-25% when
## it is dug, so a hole never refills with its own cuttings. v0 keeps this at
## 1.0 — conversion is deliberately volume-neutral until the excavation
## accounting downstream is calibrated — and the number lives here so raising
## it is one edit, not a hunt.
const SWELL_FACTOR := 1.0

## Cuttings land around the mouth of the cut, not in it: material dropped into
## the hole it came out of just falls back down the bore. The ring starts at
## the cut radius and is this many radii wide.
const SPOIL_RING_WIDTH_FACTOR := 1.4
## Narrow cuts still have to throw their spoil somewhere, so the ring is never
## thinner than this many cells.
const SPOIL_RING_MIN_WIDTH_CELLS := 2.0
## Weight left at the outer edge of the ring. Cuttings heap against the mouth,
## so the inner edge takes most of it, but a hard zero at the rim makes the
## heap a knife edge that the relax sweep then has to undo.
const SPOIL_RING_OUTER_WEIGHT := 0.25


static func spoil_volume_m3(removed_volume_m3: float) -> float:
	if removed_volume_m3 <= 0.0:
		return 0.0
	return removed_volume_m3 * SWELL_FACTOR


## Pile `volume_m3` of cuttings in a ring around a cut, in patch-local metres.
## Returns the volume the patch accepted — less than asked when part of the
## ring is off the grid or on rock, and zero when none of it fits, which the
## caller must treat as spoil it still owes rather than spoil it delivered.
##
## The ring is mobilised on the way in, so a heap dropped on a slope runs
## instead of standing at the steeper stability angle it was never packed to.
static func deposit_ring(
	patch: GranularPatch,
	x_m: float,
	z_m: float,
	cut_radius_m: float,
	volume_m3: float
) -> float:
	if patch == null or volume_m3 <= 0.0:
		return 0.0
	var cell := patch.cell_size
	var inner := maxf(cut_radius_m, 0.0)
	var outer := maxf(
		inner + cut_radius_m * SPOIL_RING_WIDTH_FACTOR,
		inner + SPOIL_RING_MIN_WIDTH_CELLS * cell
	)
	var center_x := x_m / cell
	var center_z := z_m / cell
	var inner_cells := inner / cell
	var outer_cells := outer / cell
	var reach := int(ceil(outer_cells)) + 1
	var cells := PackedInt32Array()
	var weights := PackedFloat32Array()
	var weight_total := 0.0
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var x := int(round(center_x)) + dx
			var z := int(round(center_z)) + dz
			if not patch.in_bounds(x, z) or patch.is_blocked(x, z):
				continue
			var offset_x := float(x) - center_x
			var offset_z := float(z) - center_z
			var distance := sqrt(offset_x * offset_x + offset_z * offset_z)
			if distance < inner_cells or distance > outer_cells:
				continue
			var span := maxf(outer_cells - inner_cells, 0.001)
			var weight: float = lerpf(
				1.0,
				SPOIL_RING_OUTER_WEIGHT,
				clampf((distance - inner_cells) / span, 0.0, 1.0)
			)
			cells.append(patch.index(x, z))
			weights.append(weight)
			weight_total += weight
	if cells.is_empty() or weight_total <= 0.0:
		return 0.0
	var accepted := 0.0
	for k in cells.size():
		var i: int = cells[k]
		accepted += patch.deposit(
			i % patch.width,
			i / patch.width,
			volume_m3 * weights[k] / weight_total
		)
	if accepted > 0.0:
		patch.mobilize(x_m, z_m, outer)
	return accepted
