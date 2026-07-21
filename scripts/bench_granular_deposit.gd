extends Node
## What does the *moment of extraction* cost, as opposed to the settling after?
##
## The report this exists for: a big bite with the drill hitches hard right as
## the spoil is placed, then settles fine. That is a different phase from the
## one `bench_granular_flush` measures, and it has its own candidates —
## `deposit_at`'s per-column ground search, and the rock oracle, which is a
## GDScript callback the field fires once per cell it has never seen before. A
## fresh bite touches thousands of such cells at once.

const LABEL := "GRANULAR-DEPOSIT"
const CELLS := 96
const CELL := 0.25
## What a powerful drill takes in one bite.
const BITE_M3 := 3.0

var _queries := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await _measure("no rock oracle (field self-contained)", false)
	await _measure("with rock oracle (a callback per unseen cell)", true)
	get_tree().quit(0)


func _measure(what: String, with_query: bool) -> void:
	var half := float(CELLS) * CELL * 0.5
	var region := GranularVoxelRegion.create(
		Vector3(0.0, half, 0.0), Vector3.UP, null, null, CELLS, CELL
	)
	_queries = 0
	if with_query:
		# Deliberately cheap — the real one walks the world's voxel tool, so
		# whatever this costs, the real one costs more. The number that matters
		# here is how many times it is called, not how long this takes.
		region.field.solid_query = func(cell: Vector3i) -> bool:
			_queries += 1
			return cell.y < 2
	else:
		for z in CELLS:
			for x in CELLS:
				for y in 2:
					region.field.set_solid(x, y, z, true)

	var view := GranularVoxelRegionView.new()
	add_child(view)
	view.setup(region)
	for _i in 40:
		await get_tree().process_frame

	var queries_before := _queries
	var t0 := Time.get_ticks_usec()
	var placed := region.deposit_at(Vector3(0.0, half + 1.0, 0.0), BITE_M3)
	var t1 := Time.get_ticks_usec()
	var queries_deposit := _queries - queries_before
	view.flush()
	var t2 := Time.get_ticks_usec()
	var queries_flush := _queries - queries_before - queries_deposit

	print(
		"%s: %s — placed %.2f m3, deposit %.2f ms (%d oracle calls), first flush %.2f ms (%d calls)"
		% [
			LABEL,
			what,
			placed,
			float(t1 - t0) / 1000.0,
			queries_deposit,
			float(t2 - t1) / 1000.0,
			queries_flush,
		]
	)
	# And the frames right after, which is where the hitch is reported.
	var worst := 0.0
	var total := 0.0
	for _f in 20:
		var s := Time.get_ticks_usec()
		for _i in 2:
			region.field.step(GranularVoxelWorld.CELL_BUDGET_PER_SWEEP)
		view.flush()
		var ms := float(Time.get_ticks_usec() - s) / 1000.0
		worst = maxf(worst, ms)
		total += ms
		await get_tree().process_frame
	print(
		"%s: %s — next 20 frames: worst %.2f ms, mean %.2f ms"
		% [LABEL, what, worst, total / 20.0]
	)
	view.queue_free()
