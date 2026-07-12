class_name StructuralCommandResult
extends RefCounted

const STATUS_OK := &"ok"
const STATUS_FAILED := &"failed"

const REASON_OK := &"ok"
const REASON_STALE_REVISION := &"stale_revision"
const REASON_INVALID_REFERENCE := &"invalid_reference"
const REASON_INVALID_TARGET := &"invalid_target"
const REASON_OVERLAP := &"overlap"
const REASON_INCOMPATIBLE_CONNECTION := &"incompatible_connection"
const REASON_MISALIGNED_CONNECTION := &"misaligned_connection"
const REASON_INVALID_TRANSFORM := &"invalid_transform"
const REASON_INVALID_BLUEPRINT := &"invalid_blueprint"
const REASON_ARCHETYPE_CONFLICT := &"archetype_conflict"
const REASON_INVALID_COMMAND_ID := &"invalid_command_id"

var status: StringName = STATUS_FAILED
var reason: StringName = REASON_INVALID_TARGET
var data: Dictionary = {}


static func ok(result_data: Dictionary = {}) -> StructuralCommandResult:
	var result := StructuralCommandResult.new()
	result.status = STATUS_OK
	result.reason = REASON_OK
	result.data = result_data
	return result


static func failed(
	result_reason: StringName,
	result_data: Dictionary = {}
) -> StructuralCommandResult:
	var result := StructuralCommandResult.new()
	result.status = STATUS_FAILED
	result.reason = result_reason
	result.data = result_data
	return result


func is_ok() -> bool:
	return status == STATUS_OK
