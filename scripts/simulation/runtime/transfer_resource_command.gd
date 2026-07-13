class_name TransferResourceCommand
extends RefCounted

var from_store_id: String = ""
var to_store_id: String = ""
var resource_id: String = ""
## Zero means transfer as much as capacity and source allow.
var amount: float = 0.0


func kind() -> StringName:
	return &"transfer_resource"
