extends Node
## Does reading rock in bulk give the same answers as asking cell by cell?
##
## `prime_rock` replaces the per-cell oracle with one `VoxelTool.copy` and a
## trilinear sample done natively. That is a rewrite of a coordinate chain —
## field cell to region frame to world to terrain-local — folded into a single
## matrix, and getting it wrong by half a cell would not crash anything. It
## would put the ground half a cell off, which is exactly the class of fault
## that once made everything look like it was hovering.
##
## So the slow path is the specification here too, the same arrangement as the
## field and its script twin: every cell is asked both ways and the answers
## have to agree exactly.

const LABEL := "GRANULAR-PRIME-ROCK"
const CELLS := 48
const CELL := 0.25


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var terrain := VoxelTerrain.new()
	terrain.mesher = VoxelMesherTransvoxel.new()
	# Sloped ground rather than flat: a flat generator would agree with almost
	# any transform, including a wrong one.
	var generator := VoxelGeneratorGraph.new()
	var flat := VoxelGeneratorFlat.new()
	flat.channel = VoxelBuffer.CHANNEL_SDF
	flat.height = 12.0
	generator = null
	terrain.generator = flat
	terrain.generate_collisions = false
	var viewer := VoxelViewer.new()
	viewer.view_distance = 128
	terrain.add_child(viewer)
	add_child(terrain)
	# The terrain must be off origin and rotated, or an identity transform would
	# pass this test as readily as the right one.
	terrain.global_transform = Transform3D(
		Basis(Vector3.UP, deg_to_rad(35.0)), Vector3(7.5, -3.25, 11.0)
	)
	for _i in 60:
		await get_tree().process_frame
	var tool := terrain.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF

	var centre := Vector3(4.0, 14.0, 6.0)
	var truth := GranularVoxelRegion.create(
		centre, Vector3.UP, terrain, tool, CELLS, CELL
	)
	var bulk := GranularVoxelRegion.create(
		centre, Vector3.UP, terrain, tool, CELLS, CELL
	)
	# One reads cell by cell through the oracle, the other in one bulk copy.
	var t_bulk := Time.get_ticks_usec()
	bulk.prime_rock(centre, float(CELLS) * CELL * 0.4, 8)
	var bulk_ms := float(Time.get_ticks_usec() - t_bulk) / 1000.0

	# And the layer-at-a-time path the world uses in the background, which
	# covers the whole region rather than a box around a bite.
	var stepped := GranularVoxelRegion.create(
		centre, Vector3.UP, terrain, tool, CELLS, CELL
	)
	var guard := 0
	while not stepped.prime_rock_step(4) and guard < 1000:
		guard += 1

	var disagreements := 0
	var stepped_disagreements := 0
	var checked := 0
	var first := ""
	var oracle_us := 0
	for y in CELLS:
		for z in CELLS:
			for x in CELLS:
				var t_one := Time.get_ticks_usec()
				var a: bool = truth.field.is_solid(x, y, z)
				oracle_us += Time.get_ticks_usec() - t_one
				var b: bool = bulk.field.is_solid(x, y, z)
				var c: bool = stepped.field.is_solid(x, y, z)
				checked += 1
				if a != b:
					disagreements += 1
					if first.is_empty():
						first = "(%d,%d,%d) oracle %s vs bulk %s" % [x, y, z, a, b]
				if a != c:
					stepped_disagreements += 1
					if first.is_empty():
						first = "(%d,%d,%d) oracle %s vs stepped %s" % [x, y, z, a, c]
	print(
		"%s: %d cells checked, %d disagreements%s"
		% [LABEL, checked, disagreements, ("" if first.is_empty() else " — first " + first)]
	)
	print(
		"%s: bulk read %.2f ms for the same box the oracle spent %.1f ms on (%.0fx)"
		% [LABEL, bulk_ms, float(oracle_us) / 1000.0, (float(oracle_us) / 1000.0) / maxf(bulk_ms, 0.001)]
	)
	print(
		"%s: layer-at-a-time priming — %d disagreements"
		% [LABEL, stepped_disagreements]
	)
	if disagreements > 0 or stepped_disagreements > 0:
		print("%s: FAIL" % LABEL)
		get_tree().quit(1)
		return
	print("%s: PASS" % LABEL)
	get_tree().quit(0)
