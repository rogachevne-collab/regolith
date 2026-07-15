class_name WheelVisualProjection
extends Node

const RoverModuleVisualScript := preload(
	"res://scripts/presentation/rover_module_visual.gd"
)

var _world: SimulationWorld
var _physics_projection: SimulationPhysicsProjection
var _records_by_assembly: Dictionary = {}


func bind(
	world: SimulationWorld,
	physics_projection: SimulationPhysicsProjection
) -> void:
	if (
		_world != null
		and _world.structural_event.is_connected(_on_structural_event)
	):
		_world.structural_event.disconnect(_on_structural_event)
	_world = world
	_physics_projection = physics_projection
	if _world != null:
		_world.structural_event.connect(_on_structural_event)
	rebuild_all()


func rebuild_all() -> void:
	_clear_all()
	if _world == null or _physics_projection == null:
		return
	for assembly: SimulationAssembly in _world.list_assemblies():
		if not assembly.tombstoned:
			_rebuild_assembly(assembly.assembly_id)


func rebuild_assembly(assembly_id: int) -> void:
	_rebuild_assembly(assembly_id)


func _process(delta: float) -> void:
	if _world == null or delta <= 0.0:
		return
	for assembly_id: int in _records_by_assembly.keys():
		_sync_assembly(int(assembly_id), delta)


func _on_structural_event(event: Dictionary) -> void:
	match StringName(event.get("kind", &"")):
		&"world_restored":
			call_deferred("rebuild_all")
		&"assembly_spawned", &"assembly_changed":
			_rebuild_assembly(int(event["assembly_id"]))
		&"assembly_removed":
			_clear_assembly(int(event["assembly_id"]))
		&"assembly_split":
			_rebuild_assembly(int(event["survivor_assembly_id"]))
			for mapping_variant: Variant in event.get("new_assemblies", []):
				if mapping_variant is Dictionary:
					_rebuild_assembly(int(mapping_variant["assembly_id"]))
		&"assembly_merged":
			_clear_assembly(int(event["loser_assembly_id"]))
			_rebuild_assembly(int(event["survivor_assembly_id"]))


func _rebuild_assembly(assembly_id: int) -> void:
	_clear_assembly(assembly_id)
	if _world == null or _physics_projection == null:
		return
	var body := _physics_projection.get_physics_body(assembly_id)
	if body == null:
		return
	var records: Array[Dictionary] = []
	for child: Node in body.get_children():
		if not child.has_meta("rover_module_visual"):
			continue
		var element_id := int(child.get_meta("element_id", 0))
		var element := _world.get_element(element_id)
		if element == null or element.archetype_id != "drive_wheel":
			continue
		var record := {
			"element_id": element_id,
			"root": child,
			"spin_root": child.get_node_or_null("SpinRoot") as Node3D,
			"hub_root": child.get_node_or_null("Hub") as Node3D,
			"hub_base_y": 0.12,
			"spin_base_y": 0.0,
		}
		records.append(record)
	if records.is_empty():
		return
	_records_by_assembly[assembly_id] = records


func _sync_assembly(assembly_id: int, delta: float) -> void:
	var records_variant: Variant = _records_by_assembly.get(assembly_id, [])
	if not records_variant is Array:
		return
	var records: Array = records_variant
	var stale := false
	for record_variant: Variant in records:
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		var root_variant: Variant = record.get("root")
		if root_variant == null or not is_instance_valid(root_variant):
			stale = true
			continue
		var element_id := int(record.get("element_id", 0))
		var runtime := _world.get_wheel_runtime(element_id)
		RoverModuleVisualScript.update_runtime(
			record,
			float(runtime.get("wheel_speed", 0.0)),
			float(runtime.get("compression_m", 0.0)),
			delta
		)
	if stale:
		call_deferred("_rebuild_assembly", assembly_id)


func _clear_assembly(assembly_id: int) -> void:
	_records_by_assembly.erase(assembly_id)


func _clear_all() -> void:
	_records_by_assembly.clear()
