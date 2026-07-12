class_name Blueprint
extends Resource

@export var blueprint_id: String = ""
@export var version: int = 1
@export var allow_disconnected: bool = false
@export var placements: Array[BlueprintElementPlacement] = []
