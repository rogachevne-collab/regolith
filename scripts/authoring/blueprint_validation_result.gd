class_name BlueprintValidationResult
extends RefCounted

var ok: bool = true
var errors: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()


func add_error(message: String) -> void:
	ok = false
	errors.append(message)


func add_warning(message: String) -> void:
	warnings.append(message)
