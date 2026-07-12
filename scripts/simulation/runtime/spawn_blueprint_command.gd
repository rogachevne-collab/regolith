class_name SpawnBlueprintCommand
extends StructuralCommand

var blueprint: Blueprint
var grid_frame: GridTransform = GridTransform.identity()


func kind() -> StringName:
	return &"spawn_blueprint"


func execution_copy() -> StructuralCommand:
	var copy := SpawnBlueprintCommand.new()
	copy.blueprint = blueprint
	copy.grid_frame = (
		grid_frame.duplicate_transform()
		if grid_frame != null
		else null
	)
	return copy
