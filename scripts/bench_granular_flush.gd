extends Node
## Where does the frame go while a big excavation settles?
##
## The symptom this exists for: cut a large bite with the drill and the frame
## rate falls from two hundred to twenty while the spoil finds its rest. Three
## candidates — the field's own sweeps, the reconstruction that turns occupancy
## into a surface, and the paste that hands it to the plugin — and only one of
## them is native. Guessing which is the expensive one is how two earlier
## estimates in this system came out wrong by factors of three and eight, so
## this measures them apart instead.

const LABEL := "GRANULAR-FLUSH"
const CELLS := 96
const CELL := 0.25
## A bite worth about a cubic metre and a half of spoil, which is the case the
## report is about: not a trickle, a collapse.
const BITE_M3 := 1.5
const FRAMES := 90

var _region: GranularVoxelRegion
var _view: GranularVoxelRegionView


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var half := float(CELLS) * CELL * 0.5
	_region = GranularVoxelRegion.create(
		Vector3(0.0, half, 0.0), Vector3.UP, null, null, CELLS, CELL
	)
	# Flat rock to land on, two cells deep.
	for z in CELLS:
		for x in CELLS:
			for y in 2:
				_region.field.set_solid(x, y, z, true)
	_view = GranularVoxelRegionView.new()
	add_child(_view)
	_view.setup(_region)
	# Let the terrain stream its blocks in, or the first flushes measure nothing.
	for _i in 40:
		await get_tree().process_frame
	var poured := _region.deposit_at(Vector3(0.0, half + 1.0, 0.0), BITE_M3)
	print("%s: poured %.3f m3" % [LABEL, poured])

	var sweep_ms_total := 0.0
	var flush_ms_total := 0.0
	var worst_frame_ms := 0.0
	var frames_with_work := 0
	for _f in FRAMES:
		var t0 := Time.get_ticks_usec()
		# What the world does per frame at the current settings: two sweeps,
		# because SETTLE_HZ is 120 and frames are 60 a second.
		for _s in 2:
			_region.field.step(GranularVoxelWorld.CELL_BUDGET_PER_SWEEP)
		var t1 := Time.get_ticks_usec()
		_view.flush()
		var t2 := Time.get_ticks_usec()
		var sweep_ms := float(t1 - t0) / 1000.0
		var flush_ms := float(t2 - t1) / 1000.0
		sweep_ms_total += sweep_ms
		flush_ms_total += flush_ms
		if flush_ms > 0.01:
			frames_with_work += 1
		worst_frame_ms = maxf(worst_frame_ms, sweep_ms + flush_ms)
		await get_tree().process_frame

	print(
		"%s: over %d frames — sweeps %.1f ms total (%.3f/frame), flush %.1f ms total (%.3f/frame)"
		% [
			LABEL,
			FRAMES,
			sweep_ms_total,
			sweep_ms_total / float(FRAMES),
			flush_ms_total,
			flush_ms_total / float(FRAMES),
		]
	)
	print(
		"%s: worst single frame %.2f ms, %d frames had flush work"
		% [LABEL, worst_frame_ms, frames_with_work]
	)
	var share := (
		100.0 * flush_ms_total / maxf(sweep_ms_total + flush_ms_total, 0.001)
	)
	print("%s: flush is %.1f%% of the granular frame cost" % [LABEL, share])
	print("%s: last report — %s" % [LABEL, _view.flush_report()])
	get_tree().quit(0)
