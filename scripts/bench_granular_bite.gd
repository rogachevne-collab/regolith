extends Node
## What one bite of the drill costs, broken into its parts.
##
## The report: with the rock oracle batched it is better, but fast heavy
## drilling still hitches "as the columns spawn". Fast drilling is not one big
## deposit — it is a bite every few frames, and each bite pays for the whole
## chain again: the bulk rock read, then eight cone samples each draping a disc
## of columns, each column searching down for its own ground, then the flush.
##
## Every one of those is GDScript reaching into the field a cell at a time, and
## this measures them apart rather than assuming which one dominates. Two
## earlier guesses in this system were wrong by factors of three and eight.

const LABEL := "GRANULAR-BITE"
const CELLS := 96
const CELL := 0.25
## What a heavy bit takes per bite, and how many bites a burst is.
const BITE_M3 := 1.2
const BITE_RADIUS_M := 0.9
const BITES := 12

var _region: GranularVoxelRegion
var _view: GranularVoxelRegionView


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var terrain := VoxelTerrain.new()
	terrain.mesher = VoxelMesherTransvoxel.new()
	var flat := VoxelGeneratorFlat.new()
	flat.channel = VoxelBuffer.CHANNEL_SDF
	flat.height = 12.0
	terrain.generator = flat
	terrain.generate_collisions = false
	var viewer := VoxelViewer.new()
	viewer.view_distance = 160
	terrain.add_child(viewer)
	add_child(terrain)
	for _i in 60:
		await get_tree().process_frame
	var tool := terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF

	var centre := Vector3(0.0, 12.0, 0.0)
	_region = GranularVoxelRegion.create(
		centre, Vector3.UP, terrain, tool, CELLS, CELL
	)
	_view = GranularVoxelRegionView.new()
	add_child(_view)
	_view.setup(_region)
	# The view holds its first thirty flushes back while the terrain streams.
	for _i in 40:
		_view.flush()
		await get_tree().process_frame

	var prime_ms := 0.0
	var scatter_ms := 0.0
	var flush_ms := 0.0
	var worst_bite := 0.0
	for b in BITES:
		# A moving face, so every bite lands on ground it has not seen.
		var at := centre + Vector3(float(b) * 0.35 - 2.0, 0.6, float(b % 3) * 0.3)
		var t0 := Time.get_ticks_usec()
		_region.prime_rock(at, BITE_RADIUS_M + 1.0 + 2.0, 14)
		var t1 := Time.get_ticks_usec()
		_region.deposit_landing_at(at, BITE_M3, 6)
		var t2 := Time.get_ticks_usec()
		_view.flush()
		var t3 := Time.get_ticks_usec()
		prime_ms += float(t1 - t0) / 1000.0
		scatter_ms += float(t2 - t1) / 1000.0
		flush_ms += float(t3 - t2) / 1000.0
		worst_bite = maxf(worst_bite, float(t3 - t0) / 1000.0)
		await get_tree().process_frame

	print(
		"%s: %d bites — prime %.2f ms/bite, deposit %.2f ms/bite, flush %.2f ms/bite"
		% [
			LABEL,
			BITES,
			prime_ms / float(BITES),
			scatter_ms / float(BITES),
			flush_ms / float(BITES),
		]
	)
	print("%s: worst single bite %.2f ms" % [LABEL, worst_bite])
	print(
		"%s: total per bite %.2f ms"
		% [LABEL, (prime_ms + scatter_ms + flush_ms) / float(BITES)]
	)
	get_tree().quit(0)
