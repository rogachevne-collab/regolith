class_name SnapshotCodec
extends RefCounted


static func vector3i_to_array(value: Vector3i) -> Array:
	return [value.x, value.y, value.z]


static func vector3_to_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


static func vector3i_from_variant(
	value: Variant,
	fallback: Vector3i = Vector3i.ZERO
) -> Vector3i:
	if value is Vector3i:
		return value
	if value is Array and value.size() >= 3:
		return Vector3i(int(value[0]), int(value[1]), int(value[2]))
	if value is String:
		var parsed: Variant = _parse_vector_text(value, true)
		if parsed is Vector3i:
			return parsed
	return fallback


static func vector3_from_variant(
	value: Variant,
	fallback: Vector3 = Vector3.ZERO
) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(
			float(value[0]),
			float(value[1]),
			float(value[2]),
		)
	if value is String:
		var parsed: Variant = _parse_vector_text(value, false)
		if parsed is Vector3:
			return parsed
	return fallback


static func packed_vector3_array_from_variant(value: Variant) -> PackedVector3Array:
	var result := PackedVector3Array()
	if value is PackedVector3Array:
		return value.duplicate()
	if not value is Array:
		return result
	for row: Variant in value:
		result.append(vector3_from_variant(row))
	return result


static func packed_vector3_array_to_array(
	value: PackedVector3Array
) -> Array:
	var rows: Array = []
	for point: Vector3 in value:
		rows.append(vector3_to_array(point))
	return rows


static func _parse_vector_text(text: String, as_int: bool) -> Variant:
	var cleaned := text.strip_edges()
	if not cleaned.begins_with("(") or not cleaned.ends_with(")"):
		return Vector3i.ZERO if as_int else Vector3.ZERO
	var inner := cleaned.substr(1, cleaned.length() - 2)
	var parts := inner.split(",")
	if parts.size() < 3:
		return Vector3i.ZERO if as_int else Vector3.ZERO
	if as_int:
		return Vector3i(
			int(parts[0].strip_edges()),
			int(parts[1].strip_edges()),
			int(parts[2].strip_edges()),
		)
	return Vector3(
		float(parts[0].strip_edges()),
		float(parts[1].strip_edges()),
		float(parts[2].strip_edges()),
	)
