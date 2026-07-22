class_name SimulationSession
extends Node

const SLICE01_BASE_MINIMAL := preload(
	"res://resources/blueprints/baked/slice01_base_minimal.tres"
)

@export var gateway_path: NodePath

@onready var world: SimulationWorld = $SimulationWorld
@onready var projection: SimulationPhysicsProjection = (
	$SimulationPhysicsProjection
)
@onready var visuals: ElementVisualProjection = $ElementVisualProjection
@onready var piston_visuals: PistonVisualProjection = $PistonVisualProjection
@onready var wheel_visuals: WheelVisualProjection = $WheelVisualProjection
@onready var impact_service: ImpactResolverService = $ImpactResolverService
@onready var industry_network: IndustryNetworkProjection = $IndustryNetworkProjection
@onready var industry_ports: IndustryPortProjection = $IndustryPortProjection
@onready var world_loot: WorldLootProjection = $WorldLootProjection

var _industry_simulation := IndustrySimulation.new()


func _ready() -> void:
	projection.bind_world(world)
	visuals.bind(world, projection)
	piston_visuals.bind(world, projection)
	wheel_visuals.bind(world, projection)
	industry_network.bind(world, projection)
	industry_ports.bind(world, projection)
	world_loot.bind(world)
	_industry_simulation.bind_world(world)
	call_deferred("_bind_impact_service")
	call_deferred("_bind_stationary_drill_gateway")


func _physics_process(delta: float) -> void:
	_industry_simulation.tick(world, delta)
	world.tick_suits(delta)
	var gateway: WorldCommandGateway = null
	if not gateway_path.is_empty():
		gateway = get_node_or_null(gateway_path) as WorldCommandGateway
	if gateway != null:
		gateway.tick_rover_locomotion_input()


func get_industry_simulation() -> IndustrySimulation:
	return _industry_simulation


func apply_transfer_resource(command: TransferResourceCommand) -> Dictionary:
	return _industry_simulation.apply_transfer_command(command)


func apply_set_machine_enabled(command: SetMachineEnabledCommand) -> Dictionary:
	return world.apply_set_machine_enabled(command)


func apply_set_element_name(command: SetElementNameCommand) -> Dictionary:
	return world.apply_set_element_name(command)


func apply_enqueue_recipe(command: EnqueueRecipeCommand) -> Dictionary:
	return world.apply_enqueue_recipe(command)


func apply_dequeue_recipe(command: DequeueRecipeCommand) -> Dictionary:
	return world.apply_dequeue_recipe(command)


func apply_set_actuator_target(command: SetActuatorTargetCommand) -> Dictionary:
	return world.apply_set_actuator_target(command)


func apply_configure_actuator(command: ConfigureActuatorCommand) -> Dictionary:
	return world.apply_configure_actuator(command)


func apply_configure_wheel(command: ConfigureWheelCommand) -> Dictionary:
	return world.apply_configure_wheel(command)


func apply_configure_suspension(
	command: ConfigureSuspensionCommand
) -> Dictionary:
	return world.apply_configure_suspension(command)


func _bind_impact_service() -> void:
	var gateway: WorldCommandGateway = null
	if not gateway_path.is_empty():
		gateway = get_node_or_null(gateway_path) as WorldCommandGateway
	impact_service.bind(world, gateway)
	projection.bind_impact_service(impact_service)
	ProjectedAssemblyBody.impact_service = impact_service


func _bind_stationary_drill_gateway() -> void:
	var gateway: WorldCommandGateway = null
	if not gateway_path.is_empty():
		gateway = get_node_or_null(gateway_path) as WorldCommandGateway
	if gateway == null:
		return
	_industry_simulation.set_drill_terrain_hooks(
		gateway.stationary_drill_has_terrain_contact,
		gateway.carve_stationary_drill,
		gateway.stationary_drill_carve_point
	)
	_industry_simulation.set_dozer_blade_hooks(
		gateway.dozer_blade_has_terrain_contact,
		gateway.dozer_blade_load,
		gateway.dozer_blade_plow,
		gateway.dozer_blade_contact_point
	)


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
	visuals.rebuild_assembly(assembly_id)
	piston_visuals.rebuild_assembly(assembly_id)
	wheel_visuals.rebuild_assembly(assembly_id)
	return result


func spawn_slice01_base_at(transform: Transform3D) -> StructuralCommandResult:
	return spawn_blueprint_at_transform(SLICE01_BASE_MINIMAL, transform)
