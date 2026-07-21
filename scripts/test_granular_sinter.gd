extends Node
## Sintering moves loose material out of the field exactly — the field-side of
## the transfer that turns a settled heap into rock (`GRANULAR-V2.md`).
##
## The SDF write itself needs a world and is verified in the running game; here
## the region is built with no terrain, where `sinter_into_terrain` takes the
## headless branch: it empties the field and reports the volume, which is the
## invariant the dwell timer and the region-eviction path both lean on. What
## this pins:
##
##   * G1 (field side) — the volume reported out equals the volume that was in;
##   * G2 — after a sinter the field holds nothing;
##   * an empty region sinters to zero, so the dwell loop's "nothing to give"
##     case (which parks the region dormant) is real.

const LABEL := "GRANULAR-SINTER"
const CELLS := 16
const CELL := 0.25
const EPS := 1e-5


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var region := GranularVoxelRegion.create(
		Vector3.ZERO, Vector3.UP, null, null, CELLS, CELL
	)
	var cell_vol := region.field.cell_volume_m3()

	# A known, fully-packed 4x4x4 block: 64 cells, each brim full.
	var placed := 0.0
	for y in range(2, 6):
		for z in range(2, 6):
			for x in range(2, 6):
				placed += region.field.deposit(x, y, z, cell_vol)
	var before := region.field.total_volume_m3()
	if absf(before - placed) > EPS:
		return _fail("deposit disagrees with field volume: %f vs %f" % [placed, before])
	if absf(before - 64.0 * cell_vol) > EPS:
		return _fail("expected 64 full cells, field holds %f m3" % before)

	# Sinter (no terrain → field-only transfer).
	var moved := region.sinter_into_terrain()
	var after := region.field.total_volume_m3()
	if absf(moved - before) > EPS:
		return _fail("sinter reported %f m3 out of %f held (G1)" % [moved, before])
	if after > EPS:
		return _fail("field not empty after sinter: %f m3 (G2)" % after)
	print("%s: transferred %.4f m3, field cleared to %.6f" % [LABEL, moved, after])

	# Nothing left to give: an empty region sinters to zero, which is what parks
	# it dormant instead of re-scanning every dwell period.
	var again := region.sinter_into_terrain()
	if absf(again) > EPS:
		return _fail("empty region sintered %f m3" % again)
	print("%s: empty region sinters to zero" % LABEL)

	print("%s: PASS" % LABEL)
	get_tree().quit(0)


func _fail(message: String) -> void:
	print("%s: %s" % [LABEL, message])
	print("%s: FAIL" % LABEL)
	get_tree().quit(1)
