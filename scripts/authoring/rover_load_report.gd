class_name RoverLoadReport
extends RefCounted

## Quasi-static load oracle for composed rovers (CoM, axle loads, pitch margins).
## Not a Jolt substitute — for composer feedback and agent loops.

const MOON_GRAVITY_MPS2 := 1.62
const REF_ACCEL_HALF_G := 0.5 * MOON_GRAVITY_MPS2
const REF_ACCEL_ONE_G := MOON_GRAVITY_MPS2


static func analyze(
	world: SimulationWorld,
	assembly_id: int,
	intent: RoverIntent = null
) -> Dictionary:
	if world == null or assembly_id <= 0:
		return {"ok": false, "error": "no_assembly"}
	var assembly := world.get_assembly_raw(assembly_id)
	if assembly == null or assembly.tombstoned:
		return {"ok": false, "error": "missing_assembly"}
	if intent == null:
		intent = RoverIntent.defaults()

	var suspension_points := _suspension_points_m(world, assembly_id)
	var axles_z := _unique_axle_z_m(suspension_points)
	var com := ColliderProjectionUtil.assembly_center_of_mass_local(world, assembly)
	var mass_kg := ColliderProjectionUtil.assembly_dry_mass(world, assembly)
	var weight_n := mass_kg * MOON_GRAVITY_MPS2
	var wheelbase_m := _wheelbase_m(axles_z)
	var track_m := _track_width_m(suspension_points)
	var tip_ratio := 0.0
	if suspension_points.size() >= 3 and track_m > 0.01:
		tip_ratio = absf(com.y) / track_m

	var static_loads := _static_axle_loads_n(weight_n, com.z, axles_z)
	var h_m := maxf(com.y, 0.0)
	var accel_05 := _longitudinal_margin(
		static_loads, axles_z, mass_kg, h_m, wheelbase_m, REF_ACCEL_HALF_G, true
	)
	var accel_10 := _longitudinal_margin(
		static_loads, axles_z, mass_kg, h_m, wheelbase_m, REF_ACCEL_ONE_G, true
	)
	var brake_05 := _longitudinal_margin(
		static_loads, axles_z, mass_kg, h_m, wheelbase_m, REF_ACCEL_HALF_G, false
	)
	var brake_10 := _longitudinal_margin(
		static_loads, axles_z, mass_kg, h_m, wheelbase_m, REF_ACCEL_ONE_G, false
	)

	return {
		"ok": true,
		"mass_kg": mass_kg,
		"weight_n": weight_n,
		"com_local": com,
		"axles_z_m": axles_z,
		"wheelbase_m": wheelbase_m,
		"track_m": track_m,
		"tip_ratio": tip_ratio,
		"static_axle_load_n": static_loads,
		"accel_05g": accel_05,
		"accel_10g": accel_10,
		"brake_05g": brake_05,
		"brake_10g": brake_10,
		"intent": intent.to_dict(),
	}


static func format_text(report: Dictionary) -> String:
	if not bool(report.get("ok", false)):
		return "ROVER-LOAD error=%s" % report.get("error", "?")
	var com: Vector3 = report.get("com_local", Vector3.ZERO)
	var lines: PackedStringArray = []
	lines.append("ROVER LOAD REPORT")
	lines.append(
		"mass %.0f kg  weight %.0f N  wheelbase %.2f m  track %.2f m"
		% [
			float(report.get("mass_kg", 0.0)),
			float(report.get("weight_n", 0.0)),
			float(report.get("wheelbase_m", 0.0)),
			float(report.get("track_m", 0.0)),
		]
	)
	lines.append(
		"CoM (%.2f, %.2f, %.2f) m  tip_ratio %.2f"
		% [com.x, com.y, com.z, float(report.get("tip_ratio", 0.0))]
	)
	var axles: Array = report.get("axles_z_m", [])
	var static_loads: Array = report.get("static_axle_load_n", [])
	for i: int in range(mini(axles.size(), static_loads.size())):
		lines.append(
			"  axle z=%.2f m  static %.0f N"
			% [float(axles[i]), float(static_loads[i])]
		)
	lines.append(_margin_line("accel 0.5g", report.get("accel_05g", {})))
	lines.append(_margin_line("accel 1.0g", report.get("accel_10g", {})))
	lines.append(_margin_line("brake 0.5g", report.get("brake_05g", {})))
	lines.append(_margin_line("brake 1.0g", report.get("brake_10g", {})))
	return "\n".join(lines)


static func print_lines(report: Dictionary) -> void:
	for line: String in format_text(report).split("\n"):
		print("ROVER-LOAD %s" % line)


static func _margin_line(label: String, margin: Dictionary) -> String:
	if margin.is_empty():
		return "%s: n/a" % label
	var loads: Array = margin.get("axle_load_n", [])
	var risk := ""
	if bool(margin.get("wheelie_risk", false)):
		risk = " WHEELIE"
	elif bool(margin.get("nose_dive_risk", false)):
		risk = " NOSE-DIVE"
	var parts: PackedStringArray = []
	for v: Variant in loads:
		parts.append("%.0fN" % float(v))
	return "%s: [%s]%s" % [label, ", ".join(parts), risk]


static func _suspension_points_m(
	world: SimulationWorld,
	assembly_id: int
) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for pair: Dictionary in WheelSimulationService.discover_pairs(world, assembly_id):
		if not WheelSimulationService.is_complete_pair(pair):
			continue
		var suspension: SimulationElement = pair.get("suspension_element")
		if suspension == null:
			continue
		var cell := suspension.origin_cell
		points.append(
			Vector2(float(cell.x), float(cell.z)) * GridMetric.CELL_SIZE_M
		)
	return points


static func _unique_axle_z_m(points: Array[Vector2]) -> Array[float]:
	var seen: Dictionary = {}
	for point: Vector2 in points:
		seen[point.y] = true
	var axles: Array[float] = []
	for z_key: Variant in seen.keys():
		axles.append(float(z_key))
	axles.sort()
	return axles


static func _wheelbase_m(axles_z: Array[float]) -> float:
	if axles_z.size() < 2:
		return 0.0
	return axles_z[axles_z.size() - 1] - axles_z[0]


static func _track_width_m(points: Array[Vector2]) -> float:
	if points.is_empty():
		return 0.0
	var min_x := INF
	var max_x := -INF
	for point: Vector2 in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
	return max_x - min_x


## Linear F(z)=A+Bz across axle contacts; clamp and renormalize if needed.
static func _static_axle_loads_n(
	weight_n: float,
	com_z: float,
	axles_z: Array[float]
) -> Array[float]:
	var count := axles_z.size()
	if count <= 0:
		return []
	if count == 1:
		return [weight_n]
	var sum_z := 0.0
	var sum_z2 := 0.0
	for z: float in axles_z:
		sum_z += z
		sum_z2 += z * z
	var n_f := float(count)
	var denom := sum_z2 - sum_z * sum_z / n_f
	if absf(denom) < 0.0001:
		var equal := weight_n / n_f
		var equal_loads: Array[float] = []
		for _i: int in count:
			equal_loads.append(equal)
		return equal_loads
	var z_mean := sum_z / n_f
	var b := weight_n * (com_z - z_mean) / denom
	var a := (weight_n - b * sum_z) / n_f
	var loads: Array[float] = []
	for z: float in axles_z:
		loads.append(maxf(0.0, a + b * z))
	var total := 0.0
	for load: float in loads:
		total += load
	if total > 0.0 and absf(total - weight_n) > 0.01:
		var scale := weight_n / total
		for i: int in loads.size():
			loads[i] *= scale
	return loads


static func _longitudinal_margin(
	static_loads: Array[float],
	axles_z: Array[float],
	mass_kg: float,
	com_height_m: float,
	wheelbase_m: float,
	accel_mps2: float,
	is_accel: bool
) -> Dictionary:
	var loads: Array[float] = static_loads.duplicate()
	if (
		loads.is_empty()
		or wheelbase_m <= 0.01
		or mass_kg <= 0.0
		or com_height_m <= 0.0
	):
		return {
			"axle_load_n": loads,
			"wheelie_risk": false,
			"nose_dive_risk": false,
		}
	var delta := mass_kg * accel_mps2 * com_height_m / wheelbase_m
	var z_min := axles_z[0]
	var z_max := axles_z[axles_z.size() - 1]
	for i: int in loads.size():
		var z := axles_z[i]
		var factor := 0.0
		if z_max > z_min + 0.0001:
			factor = 2.0 * (z - z_min) / (z_max - z_min) - 1.0
		var shift := delta * factor
		if is_accel:
			loads[i] += shift
		else:
			loads[i] -= shift
	var front_load := loads[0]
	var rear_load := loads[loads.size() - 1]
	return {
		"axle_load_n": loads,
		"wheelie_risk": is_accel and front_load <= 0.0,
		"nose_dive_risk": (not is_accel) and rear_load <= 0.0,
		"front_load_n": front_load,
		"rear_load_n": rear_load,
	}
