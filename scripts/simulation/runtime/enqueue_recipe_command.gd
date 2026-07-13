class_name EnqueueRecipeCommand
extends RefCounted

var element_id: int = 0
var recipe_id: String = ""


func kind() -> StringName:
	return &"enqueue_recipe"
