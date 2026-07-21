extends Node
## Spike: is a flowing 0.25 m voxel field affordable in GDScript?
##
## Two questions decide whether loose material can be its own voxel volume
## instead of a height field draped on the terrain:
##   1. does the active set stay small, or does the whole box stay awake?
##   2. does a pour settle into a cone that conserves its volume?
## Everything else (a second VoxelTerrain for meshing and collision, chunking,
## radial down) only matters if these two pass.

const _HeadlessTestHarness := preload(
	"res://scripts/testing/headless_test_harness.gd"
)

const LABEL := "GRANULAR-VOXEL-CA"
const CELL := 0.25
## 24 m box at 0.25 m — comfortably larger than one working face.
const DIMS := Vector3i(96, 64, 96)
const FLOOR_Y := 2
## Big enough that the pile's angle is a measurement rather than a rounding
## artefact: at a few cubic metres the crest is three to five cells, so the
## slope can only land on ~45 or ~27 degrees with nothing in between, and any
## tuning aimed at 33 is guesswork.
const POUR_M3 := 20.0
const POUR_COLUMN_CELLS := 40
const MAX_SWEEPS := 20000
## A sweep costing more than this leaves no room for the rest of the frame.
const BUDGET_MS_PER_SWEEP := 7.0
## Cells one sweep may visit. Settling runs at roughly 10 Hz, so this is the
## knob that trades how fast a collapse resolves against what it costs the
## frame it lands in.
## Matches what `granular_voxel_playground` actually runs, so the measurement
## is of the shipping configuration rather than of a number chosen here.
const CELL_BUDGET_PER_SWEEP := 128
## This suite settles four separate piles to a full stop, which is far more
## work than a logic test. Generous, but still a hang detector.
const WATCHDOG_SEC := 180.0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	# Four settling scenarios, each thousands of sweeps: the default 20 s
	# watchdog kills this suite part way through and reports it as a hang.
	_HeadlessTestHarness.arm_watchdog(self, LABEL, WATCHDOG_SEC)
	var field := GranularVoxelField.create(DIMS, CELL)
	var cells_total := DIMS.x * DIMS.y * DIMS.z
	for z in DIMS.z:
		for x in DIMS.x:
			for y in FLOOR_Y:
				field.set_solid(x, y, z, true)
	var centre_x := DIMS.x / 2
	var centre_z := DIMS.z / 2
	# One cell holds only cell_size^3, so a few cubic metres needs a column
	# with real footprint. Fill it bottom-up until the volume is delivered.
	var poured := 0.0
	var remaining := POUR_M3
	for step in POUR_COLUMN_CELLS:
		for dz in range(-4, 5):
			for dx in range(-4, 5):
				if remaining <= 0.0:
					break
				var accepted := field.deposit(
					centre_x + dx,
					FLOOR_Y + step,
					centre_z + dz,
					remaining
				)
				poured += accepted
				remaining -= accepted
	print(
		"%s: box %d cells (%.1f m3 of grid), poured %.3f m3"
		% [LABEL, cells_total, cells_total * field.cell_volume_m3(), poured]
	)

	var sweeps := 0
	var visited_total := 0
	var peak_active := 0
	var worst_sweep_ms := 0.0
	var started_us := Time.get_ticks_usec()
	while not field.is_settled() and sweeps < MAX_SWEEPS:
		var sweep_started := Time.get_ticks_usec()
		var visited := field.step(CELL_BUDGET_PER_SWEEP)
		var sweep_ms := float(Time.get_ticks_usec() - sweep_started) / 1000.0
		worst_sweep_ms = maxf(worst_sweep_ms, sweep_ms)
		peak_active = maxi(peak_active, visited)
		visited_total += visited
		sweeps += 1
	var elapsed_ms := float(Time.get_ticks_usec() - started_us) / 1000.0

	var settled := field.total_volume_m3()
	var lost := absf(settled - poured)
	print(
		"%s: settled in %d sweeps, %.1f ms total, worst sweep %.2f ms"
		% [LABEL, sweeps, elapsed_ms, worst_sweep_ms]
	)
	print(
		"%s: cells visited %d (peak active %d, %.4f%% of the box)"
		% [
			LABEL,
			visited_total,
			peak_active,
			100.0 * float(peak_active) / float(cells_total),
		]
	)
	print("%s: volume %.4f -> %.4f m3 (drift %.6f)" % [LABEL, poured, settled, lost])
	_report_shape(field, centre_x, centre_z)

	if lost > 0.001:
		_fail("volume drifted by %.6f m3" % lost)
		return
	if sweeps >= MAX_SWEEPS:
		_fail("never came to rest in %d sweeps" % MAX_SWEEPS)
		return
	if worst_sweep_ms > BUDGET_MS_PER_SWEEP:
		_fail(
			"worst sweep %.2f ms over the %.1f ms budget"
			% [worst_sweep_ms, BUDGET_MS_PER_SWEEP]
		)
		return
	if not _test_a_tight_budget_does_not_strand_material():
		return
	if not _test_undermining_rock_drops_the_heap_on_it():
		return
	if not _test_material_falls_toward_the_planet_not_toward_minus_y():
		return
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


## The world is a sphere, so "down" is the radial and only at one point on the
## planet does it agree with -Y. The field keeps -Y internally and the region's
## frame is what turns; this checks that the two together actually drop
## material toward the centre of the planet on the side of it, where a naive
## -Y would send material sideways along the ground.
func _test_material_falls_toward_the_planet_not_toward_minus_y() -> bool:
	var started := Time.get_ticks_msec()
	var planet_radius := 9500.0
	# On the equator: local up is +X here, and global -Y is a horizontal
	# direction — the worst case for getting this wrong.
	var centre := Vector3(planet_radius, 0.0, 0.0)
	var up := centre.normalized()
	var span := 32
	var region := GranularVoxelRegion.create(centre, up, null, null, span, CELL)
	if region.up().dot(up) < 0.9999:
		_fail("region up is not the radial: %s" % str(region.up()))
		return false
	# Rock floor: a slab perpendicular to the radial, i.e. one field layer.
	for z in span:
		for y in 4:
			for x in span:
				region.field.set_solid(x, y, z, true)
	var drop_point := centre + up * 2.0
	var poured := region.deposit_at(drop_point, 0.6)
	if poured <= 0.0:
		_fail("nothing was deposited into the region")
		return false
	var start_radius := drop_point.length()
	var sweeps := 0
	while not region.field.is_settled() and sweeps < 20000:
		region.field.step()
		sweeps += 1
	if sweeps >= 20000:
		_fail("material on the planet's side never came to rest")
		return false
	if absf(region.field.total_volume_m3() - poured) > 1e-4:
		_fail("radial region lost volume")
		return false
	# Where did the mass end up, in world terms? It has to be closer to the
	# planet's centre than it started, and still above the rock floor.
	var mass_total := 0.0
	var radius_total := 0.0
	for y in span:
		for z in span:
			for x in span:
				var mass := region.field.mass_at(x, y, z)
				if mass <= 0.0:
					continue
				mass_total += mass
				radius_total += mass * region.cell_to_world(
					Vector3i(x, y, z)
				).length()
	if mass_total <= 0.0:
		_fail("no material left in the radial region")
		return false
	var settled_radius := radius_total / mass_total
	if settled_radius >= start_radius:
		_fail(
			"material did not fall toward the planet: r %.2f -> %.2f"
			% [start_radius, settled_radius]
		)
		return false
	print(
		"%s: on the planet's side, material fell radially r %.2f -> %.2f m (down is %s) [%d ms]"
		% [
			LABEL,
			start_radius,
			settled_radius,
			str(-region.up().round()),
			Time.get_ticks_msec() - started,
		]
	)
	return true


## Rock comes from the world's own voxel field, so the granular field learns it
## by asking and remembering. Carving under a heap has to invalidate what was
## remembered and wake the heap — otherwise the material goes on resting on
## rock that is no longer there, which is exactly the "pile left hanging in the
## air over my excavation" the height-field version could never fix.
func _test_undermining_rock_drops_the_heap_on_it() -> bool:
	var started := Time.get_ticks_msec()
	var pillar_top := 20
	# A lambda captures a local by *value* in GDScript, so a plain bool here
	# would freeze at `false` and the carve would never reach the query. An
	# array is a reference, so the closure sees the change.
	var carved := [false]
	var field := GranularVoxelField.create(Vector3i(32, 48, 32), CELL)
	# Rock is a floor plus a pillar, answered on demand rather than stored.
	field.solid_query = func(cell: Vector3i) -> bool:
		if cell.y < 2:
			return true
		if bool(carved[0]):
			return false
		return (
			cell.y < pillar_top
			and absi(cell.x - 16) <= 2
			and absi(cell.z - 16) <= 2
		)
	var poured := 0.0
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			for dy in range(0, 6):
				poured += field.deposit(16 + dx, pillar_top + dy, 16 + dz, 1.0)
	var sweeps := 0
	while not field.is_settled() and sweeps < 20000:
		field.step()
		sweeps += 1
	var resting := 0.0
	for y in range(pillar_top - 2, 48):
		for z in 32:
			for x in 32:
				resting += field.mass_at(x, y, z)
	if resting <= 0.0:
		_fail("the heap never came to rest on the pillar")
		return false

	# Take the pillar away and tell the field the rock there changed.
	carved[0] = true
	field.invalidate_solid(Vector3i(10, 2, 10), Vector3i(22, pillar_top, 22))
	sweeps = 0
	while not field.is_settled() and sweeps < 40000:
		field.step()
		sweeps += 1
	if sweeps >= 40000:
		_fail("the undermined heap never came to rest")
		return false
	if absf(field.total_volume_m3() - poured) > 1e-4:
		_fail("undermining lost volume")
		return false
	var left_high := 0.0
	for y in range(pillar_top - 2, 48):
		for z in 32:
			for x in 32:
				left_high += field.mass_at(x, y, z)
	if left_high > 0.0:
		_fail(
			"%.3f cells still standing where the pillar used to be" % left_high
		)
		return false
	print(
		"%s: undermined heap fell %d cells to the floor, volume intact [%d ms]"
		% [LABEL, pillar_top, Time.get_ticks_msec() - started]
	)
	return true


## Nothing may be left hanging in the air because the per-sweep budget never
## reached it. Cell indices are y-major, so taking the first N of a sorted
## active list always means the lowest cells: with a backlog larger than the
## budget the top of a falling column was never visited at all and simply
## stayed floating. The budget window has to rotate.
func _test_a_tight_budget_does_not_strand_material() -> bool:
	var started := Time.get_ticks_msec()
	var field := GranularVoxelField.create(Vector3i(24, 40, 24), CELL)
	for z in 24:
		for x in 24:
			field.set_solid(x, 0, z, true)
	# A column well clear of the floor, and a budget far smaller than the cells
	# it wakes. Height is what makes this catch starvation, not volume, so it
	# is kept just tall enough to matter.
	var poured := 0.0
	for y in range(20, 36):
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				poured += field.deposit(12 + dx, y, 12 + dz, 1.0)
	var sweeps := 0
	while not field.is_settled() and sweeps < 20000:
		field.step(16)
		sweeps += 1
	if sweeps >= 20000:
		_fail("a tight budget never let the column come to rest")
		return false
	if absf(field.total_volume_m3() - poured) > 1e-4:
		_fail("a tight budget lost volume")
		return false
	# Everything must have reached the floor: nothing left up where it started.
	var stranded := 0.0
	for y in range(20, 40):
		for z in 24:
			for x in 24:
				stranded += field.mass_at(x, y, z)
	if stranded > 0.0:
		# Say where it is and what is under it, or "stranded" is just a number.
		var report := PackedStringArray()
		for y in range(39, 19, -1):
			var layer := 0.0
			for z in 24:
				for x in 24:
					layer += field.mass_at(x, y, z)
			if layer <= 0.0:
				continue
			var supported := 0
			var floating := 0
			for z in 24:
				for x in 24:
					if field.mass_at(x, y, z) <= 0.0:
						continue
					if (
						field.is_solid(x, y - 1, z)
						or field.mass_at(x, y - 1, z) >= 1.0
					):
						supported += 1
					else:
						floating += 1
			report.append(
				"y=%d mass %.3f (%d supported, %d floating)"
				% [y, layer, supported, floating]
			)
			if report.size() >= 8:
				break
		print("%s: stranded layers — %s" % [LABEL, "; ".join(report)])
		_fail(
			"%.3f cells of material stranded in mid-air after %d sweeps"
			% [stranded, sweeps]
		)
		return false
	print(
		"%s: tight budget (16 cells/sweep) drained the column in %d sweeps, nothing stranded [%d ms]"
		% [LABEL, sweeps, Time.get_ticks_msec() - started]
	)
	return true


## Height at the crest against how far the skirt reaches, which is the pile's
## angle. A cone means the rules produced granular behaviour; a puddle or a
## tower means they did not.
func _report_shape(
	field: GranularVoxelField,
	centre_x: int,
	centre_z: int
) -> void:
	var crest := 0
	for y in range(DIMS.y - 1, FLOOR_Y - 1, -1):
		if field.mass_at(centre_x, y, centre_z) >= 0.5:
			crest = y - FLOOR_Y + 1
			break
	var radius := 0
	for dx in range(0, DIMS.x / 2):
		if field.mass_at(centre_x + dx, FLOOR_Y, centre_z) >= 0.5:
			radius = dx + 1
	var angle_deg := (
		rad_to_deg(atan2(float(crest), float(radius))) if radius > 0 else 90.0
	)
	print(
		"%s: pile crest %d cells (%.2f m), radius %d cells (%.2f m), slope %.1f deg"
		% [LABEL, crest, crest * CELL, radius, radius * CELL, angle_deg]
	)


func _fail(message: String) -> void:
	push_error(message)
	print("%s: FAIL - %s" % [LABEL, message])
	get_tree().quit(1)
