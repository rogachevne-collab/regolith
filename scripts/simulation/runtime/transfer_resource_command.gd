class_name TransferResourceCommand
extends RefCounted

var from_store_id: String = ""
var to_store_id: String = ""
var resource_id: String = ""
## Zero means transfer as much as capacity and source allow.
var amount: float = 0.0
## When set, moves one player-owned tool instance instead of a store stack.
var instance_id: String = ""


func kind() -> StringName:
	return &"transfer_resource"
