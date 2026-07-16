class_name RoverValidator
extends RefCounted

## Functional oracles for composed rovers. Failures are machine-readable.


static func validate(
	world: SimulationWorld,
	assembly_id: int,
	intent: RoverIntent = null
) -> Dictionary:
	var failures: Array[String] = []
	if world == null or assembly_id <= 0:
		return {"ok": false, "failures": ["no_assembly"]}
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return {"ok": false, "failures": ["missing_assembly"]}
	if intent == null:
		intent = RoverIntent.defaults()

	var pairs := WheelSimulationService.discover_pairs(world, assembly_id)
	var complete := 0
	var suspension_points: Array[Vector2] = []
	for pair: Dictionary in pairs:
		if WheelSimulationService.is_complete_pair(pair):
			complete += 1
		var suspension: SimulationElement = pair.get("suspension_element")
		if suspension != null:
			var cell := suspension.origin_cell
			suspension_points.append(
				Vector2(float(cell.x), float(cell.z)) * GridMetric.CELL_SIZE_M
			)

	if complete != intent.wheel_count:
		failures.append(
			"wheel_count_mismatch:%d!=%d" % [complete, intent.wheel_count]
		)
	if complete < 4:
		failures.append("too_few_wheels:%d" % complete)

	if not _has_archetype(world, assembly, "cockpit"):
		failures.append("missing_cockpit")
	if not _has_archetype(world, assembly, "power_battery_small"):
		failures.append("missing_battery")
	if not _has_archetype(world, assembly, "power_distributor_small"):
		failures.append("missing_distributor")

	if not _wheels_symmetric(suspension_points):
		failures.append("asymmetric_wheels")

	var com := ColliderProjectionUtil.assembly_center_of_mass_local(
		world,
		assembly
	)
	if suspension_points.size() >= 3:
		if not _point_in_support_polygon(Vector2(com.x, com.z), suspension_points, 0.15):
			failures.append("com_outside_wheelbase")
		var track := _track_width_m(suspension_points)
		var tip_ratio := absf(com.y) / maxf(track, 0.01)
		var tip_limit := 1.35 if intent.height != "tall" else 1.8
		if tip_ratio > tip_limit:
			failures.append("tipping_risk:%.2f" % tip_ratio)

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"complete_wheel_pairs": complete,
		"com_local": com,
	}


static func _has_archetype(
	world: SimulationWorld,
	assembly: SimulationAssembly,
	archetype_id: String
) -> bool:
	for element_id: int in assembly.element_ids:
		var element := world.get_element(element_id)
		if element != null and element.archetype_id == archetype_id:
			return true
	return false


static func _wheels_symmetric(points: Array[Vector2]) -> bool:
	if points.size() < 2:
		return false
	var left := 0
	var right := 0
	var mid_x := 0.0
	for point: Vector2 in points:
		mid_x += point.x
	mid_x /= float(points.size())
	for point: Vector2 in points:
		if point.x < mid_x - 0.01:
			left += 1
		elif point.x > mid_x + 0.01:
			right += 1
	return left == right and left > 0


static func _track_width_m(points: Array[Vector2]) -> float:
	var min_x := INF
	var max_x := -INF
	for point: Vector2 in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
	return max_x - min_x


static func _point_in_support_polygon(
	point: Vector2,
	hull_points: Array[Vector2],
	margin_m: float
) -> bool:
	# Axis-aligned bbox with margin — enough for symmetric rectangular layouts.
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p: Vector2 in hull_points:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	return (
		point.x >= min_x + margin_m
		and point.x <= max_x - margin_m
		and point.y >= min_z + margin_m
		and point.y <= max_z - margin_m
	)
