class_name DequeueRecipeCommand
extends RefCounted

var element_id: int = 0
## First pending queue slot to remove (0 = front, the next job to start).
var index: int = 0
## How many contiguous slots to remove starting at `index`. Clamped by the
## runner to what the queue actually holds.
var count: int = 1


func kind() -> StringName:
	return &"dequeue_recipe"
