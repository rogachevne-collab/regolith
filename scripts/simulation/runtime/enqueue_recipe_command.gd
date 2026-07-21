class_name EnqueueRecipeCommand
extends RefCounted

var element_id: int = 0
var recipe_id: String = ""
## How many copies of the recipe to append. Clamped to at least 1 by the
## runner; the append is capped by remaining queue capacity.
var count: int = 1


func kind() -> StringName:
	return &"enqueue_recipe"
