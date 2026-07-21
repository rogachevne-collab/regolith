extends Node
## Round-trips the live granular field through the save format: a heap written
## sparse, serialised, read back and re-deposited must be the same heap, cell
## for cell (`GRANULAR-V2.md`, G4).
##
## Exercises the parts that persistence can get wrong on its own — the sparse
## index encode/decode arithmetic and the `store_var`/`get_var` file round-trip —
## on bare fields, mirroring exactly what `GranularVoxelWorld.capture_field_
## snapshot` / `restore_field_snapshot` do. The full path through the region view
## needs a world and is verified in the running game.

const LABEL := "GRANULAR-PERSIST"
const CELLS := 24
const CELL := 0.25
const EPS := 1e-5
const TMP_PATH := "user://test_granular_persist_roundtrip.dat"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var source := GranularVoxelField.create(Vector3i(CELLS, CELLS, CELLS), CELL)
	var cell_vol := source.cell_volume_m3()
	# An irregular heap, part-full cells and all, so a flattening bug in the
	# index maths cannot hide behind a symmetric block.
	var placed := 0.0
	for y in range(1, 5):
		for z in range(6, 12):
			for x in range(4, 10):
				var frac := 0.3 + 0.1 * float((x + y + z) % 6)
				placed += source.deposit(x, y, z, frac * cell_vol)
	var before := source.total_volume_m3()
	if absf(before - placed) > EPS:
		return _fail("source deposit lost volume: %f vs %f" % [placed, before])

	# Encode exactly as capture does: one bulk read, keep only occupied cells.
	var mass := source.copy_mass_box(Vector3i.ZERO, source.size)
	var idx := PackedInt32Array()
	var val := PackedFloat32Array()
	for i in mass.size():
		if mass[i] > 0.0:
			idx.append(i)
			val.append(mass[i])
	var snap := {
		"version": 1,
		"regions": [{
			"center": Vector3(3.0, -1.0, 7.0),
			"up": Vector3.UP,
			"cells": CELLS,
			"cell_size": CELL,
			"idx": idx,
			"val": val,
		}],
	}

	# Through a real file, the way a quit persists it.
	var writer := FileAccess.open(TMP_PATH, FileAccess.WRITE)
	if writer == null:
		return _fail("cannot open %s for write" % TMP_PATH)
	writer.store_var(snap, false)
	writer.close()
	var reader := FileAccess.open(TMP_PATH, FileAccess.READ)
	if reader == null:
		return _fail("cannot reopen %s" % TMP_PATH)
	var data: Variant = reader.get_var(false)
	reader.close()
	DirAccess.remove_absolute(TMP_PATH)
	if not (data is Dictionary):
		return _fail("save did not read back as a Dictionary")

	var regions: Array = (data as Dictionary).get("regions", [])
	if regions.size() != 1:
		return _fail("expected 1 region, got %d" % regions.size())
	var rd: Dictionary = regions[0]
	var cells := int(rd["cells"])
	var plane := cells * cells
	var r_idx: PackedInt32Array = rd["idx"]
	var r_val: PackedFloat32Array = rd["val"]

	# Decode exactly as restore does, into a fresh field.
	var restored := GranularVoxelField.create(Vector3i(cells, cells, cells), CELL)
	var r_cell_vol := restored.cell_volume_m3()
	for k in r_idx.size():
		var flat := r_idx[k]
		var y := flat / plane
		var rem := flat - y * plane
		var z := rem / cells
		var x := rem - z * cells
		restored.deposit(x, y, z, r_val[k] * r_cell_vol)

	if absf(restored.total_volume_m3() - before) > EPS:
		return _fail(
			"volume drifted: %f vs %f (G4)"
			% [restored.total_volume_m3(), before]
		)
	var mismatches := 0
	for y in CELLS:
		for z in CELLS:
			for x in CELLS:
				if absf(restored.mass_at(x, y, z) - source.mass_at(x, y, z)) > EPS:
					mismatches += 1
	if mismatches > 0:
		return _fail("%d cells differ after round-trip" % mismatches)

	print("%s: %d cells round-tripped, volume %.4f m3 held" % [LABEL, r_idx.size(), before])
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


func _fail(message: String) -> void:
	print("%s: %s" % [LABEL, message])
	print("%s: FAIL" % LABEL)
	get_tree().quit(1)
