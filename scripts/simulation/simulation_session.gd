class_name SimulationSession
extends Node

const SLICE01_BASE_MINIMAL := preload(
	"res://resources/blueprints/baked/slice01_base_minimal.tres"
)

@onready var world: SimulationWorld = $SimulationWorld
@onready var projection: SimulationPhysicsProjection = (
	$SimulationPhysicsProjection
)
@onready var visuals: ElementVisualProjection = $ElementVisualProjection


func _ready() -> void:
	projection.bind_world(world)
	visuals.bind(world, projection)


func spawn_blueprint(
	blueprint: Blueprint,
	grid_frame: GridTransform
) -> StructuralCommandResult:
	var command := SpawnBlueprintCommand.new()
	command.blueprint = blueprint
	command.grid_frame = grid_frame
	return world.apply_structural_command_now(command)


func spawn_blueprint_at_transform(
	blueprint: Blueprint,
	spawn_transform: Transform3D
) -> StructuralCommandResult:
	var grid_frame := GridSpawnUtil.grid_frame_from_transform(spawn_transform)
	var result := spawn_blueprint(blueprint, grid_frame)
	if not result.is_ok():
		return result
	var assembly_id: int = int(result.data["assembly_id"])
	var anchored: bool = world.assembly_has_anchor(assembly_id)
	var motion := GridSpawnUtil.motion_from_transform(
		spawn_transform,
		anchored
	)
	projection.project_assembly_now(assembly_id, motion)
	visuals.rebuild_all()
	return result


func spawn_slice01_base_at(transform: Transform3D) -> StructuralCommandResult:
	return spawn_blueprint_at_transform(SLICE01_BASE_MINIMAL, transform)
