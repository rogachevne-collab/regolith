class_name GranularSpoilBody
extends StaticBody3D
## Collider for one `GranularFieldView`, and the thing an aim ray reports when
## it lands on a heap of loose material.
##
## The body exists so players, wheels and dropped crates rest on spoil like any
## other ground. `InteractionQuery` duck-types these two methods, which is what
## makes a pile a target the drill understands — without them the heap reads as
## a generic body, and every tool that requires terrain would refuse to work
## wherever spoil happens to be lying.

const GROUP_NAME := &"granular_spoil"


func _ready() -> void:
	add_to_group(GROUP_NAME)


func interaction_target_kind() -> StringName:
	return InteractionHit.KIND_GRANULAR


func interaction_metadata() -> Dictionary:
	return {"granular": true}
