class_name InteractionHit
extends RefCounted

const KIND_NONE := &"none"
const KIND_VOXEL := &"voxel"
const KIND_BODY := &"body"
const KIND_PLACED_BLOCK := &"placed_block"
const KIND_CONTROL_SEAT := &"control_seat"

var valid := false
var point := Vector3.ZERO
var normal := Vector3.UP
var distance := 0.0
var target_kind: StringName = KIND_NONE
var collider: Object
var target_id := StringName()
var metadata: Dictionary = {}


static func empty() -> InteractionHit:
	return InteractionHit.new()


static func create(
	hit_point: Vector3,
	hit_normal: Vector3,
	hit_distance: float,
	kind: StringName,
	hit_collider: Object = null,
	id := StringName(),
	extra: Dictionary = {}
) -> InteractionHit:
	var result := InteractionHit.new()
	result.valid = true
	result.point = hit_point
	result.normal = hit_normal.normalized()
	result.distance = hit_distance
	result.target_kind = kind
	result.collider = hit_collider
	result.target_id = id
	result.metadata = extra.duplicate(true)
	return result


func snapshot() -> Dictionary:
	return {
		"valid": valid,
		"point": point,
		"normal": normal,
		"distance": distance,
		"target_kind": target_kind,
		"collider": collider,
		"target_id": target_id,
		"metadata": metadata.duplicate(true),
	}
