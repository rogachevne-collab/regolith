class_name SimulationElement
extends RefCounted

const _SCRIPT := preload("res://scripts/simulation/runtime/simulation_element.gd")
const _CODEC := preload("res://scripts/simulation/snapshot_codec.gd")

var element_id: int = 0
var assembly_id: int = 0
var archetype_id: String = ""
var origin_cell: Vector3i = Vector3i.ZERO
var orientation_index: int = 0
var build_progress: float = 1.0
var integrity: float = 0.0
var condition: float = 1.0
var state_revision: int = 0
var installed_materials: Dictionary = {}
## Structural integrity at placement (1% of max_integrity).
const PLACEMENT_STRUCTURAL_FRACTION := 0.01
## Integrity restored per plate_metal when BOM is already complete.
## Authoritative value: Game Balance `construction.weld_repair_integrity_fraction`.
static func weld_repair_integrity_fraction() -> float:
	return GameBalance.construction_float("weld_repair_integrity_fraction", 0.25)
# Persistent record of whether this block was found resting on / embedded in the
# voxel terrain. Set at placement and re-verified on structural split/dismantle
# (terrain is destructible). Drives ground anchoring so a construction keeps every
# ground-touching block anchored, not just the first-placed one.
var terrain_contact: bool = false
var industry_buffer: ElementIndustryBuffer = null
var industry_functional_reason: StringName = &"ok"

var _archetype: ElementArchetype


static func from_placement(
	new_element_id: int,
	new_assembly_id: int,
	placement: BlueprintElementPlacement
) -> SimulationElement:
	var element: SimulationElement = _SCRIPT.new()
	element.element_id = new_element_id
	element.assembly_id = new_assembly_id
	element.archetype_id = placement.archetype.archetype_id
	element.origin_cell = placement.origin_cell
	element.orientation_index = placement.orientation_index
	element._archetype = placement.archetype
	element.install_all_required_materials()
	element.integrity = placement.archetype.max_integrity
	element.sync_build_progress_from_integrity()
	element.condition = 1.0
	return element


static func frame(
	new_element_id: int,
	new_assembly_id: int,
	archetype: ElementArchetype,
	new_origin_cell: Vector3i,
	new_orientation_index: int,
	initial_materials: Dictionary
) -> SimulationElement:
	var element: SimulationElement = _SCRIPT.new()
	element.element_id = new_element_id
	element.assembly_id = new_assembly_id
	element.archetype_id = archetype.archetype_id
	element.origin_cell = new_origin_cell
	element.orientation_index = new_orientation_index
	element._archetype = archetype
	element.installed_materials = initial_materials.duplicate(true)
	element.apply_placement_integrity()
	element.condition = 1.0
	return element


func get_archetype() -> ElementArchetype:
	return _archetype


func bind_archetype(archetype: ElementArchetype) -> bool:
	if archetype == null or archetype.archetype_id != archetype_id:
		return false
	_archetype = archetype
	return true


func dry_mass_kg() -> float:
	var archetype: ElementArchetype = get_archetype()
	if archetype == null:
		return 0.0
	return archetype.mass_kg


func industry_buffer_amount(resource_id: String) -> float:
	if industry_buffer == null:
		return 0.0
	return industry_buffer.amount(resource_id)


func set_industry_buffer(amounts: Dictionary) -> void:
	if industry_buffer == null:
		industry_buffer = ElementIndustryBuffer.new()
	for resource_id: Variant in amounts.keys():
		var amount := float(amounts[resource_id])
		if amount <= 0.000001:
			continue
		industry_buffer.remove(resource_id, INF)
		var capacity := IndustryArchetypeProfile.internal_buffer_capacity_l(
			archetype_id
		)
		if capacity <= 0.0:
			capacity = INF
		industry_buffer.add(str(resource_id), amount, capacity)


func content_mass_kg(world: SimulationWorld = null) -> float:
	if world != null:
		return IndustryStoreService.content_mass_kg(world, self)
	if industry_buffer != null:
		return industry_buffer.mass_kg()
	return 0.0


func total_mass_kg(world: SimulationWorld = null) -> float:
	return dry_mass_kg() + content_mass_kg(world)


func bump_state_revision() -> void:
	state_revision += 1


func required_material_amount(resource_id: String) -> float:
	var archetype := get_archetype()
	if archetype == null:
		return 0.0
	var total := 0.0
	for requirement: BuildRequirement in archetype.build_requirements:
		if requirement.resource_id == resource_id:
			total += requirement.amount
	return total


func installed_material_amount(resource_id: String) -> float:
	return float(installed_materials.get(resource_id, 0.0))


func total_required_material_amount() -> float:
	var archetype := get_archetype()
	if archetype == null:
		return 0.0
	var total := 0.0
	for requirement: BuildRequirement in archetype.build_requirements:
		total += requirement.amount
	return total


func total_installed_material_amount() -> float:
	var total := 0.0
	for resource_id: Variant in installed_materials.keys():
		total += float(installed_materials[resource_id])
	return total


func install_material(resource_id: String, amount: float) -> bool:
	var missing := maxf(
		required_material_amount(resource_id)
		- installed_material_amount(resource_id),
		0.0
	)
	if resource_id.is_empty() or amount <= 0.0 or amount > missing + 0.000001:
		return false
	installed_materials[resource_id] = (
		installed_material_amount(resource_id) + amount
	)
	recalculate_integrity_from_materials()
	return true


func install_all_required_materials() -> void:
	installed_materials.clear()
	var archetype := get_archetype()
	if archetype == null:
		build_progress = 0.0
		return
	for requirement: BuildRequirement in archetype.build_requirements:
		installed_materials[requirement.resource_id] = (
			installed_material_amount(requirement.resource_id)
			+ requirement.amount
		)
	recalculate_integrity_from_materials()


func structural_fraction() -> float:
	var archetype := get_archetype()
	if archetype == null or archetype.max_integrity <= 0.0:
		return 0.0
	return clampf(integrity / archetype.max_integrity, 0.0, 1.0)


func sync_build_progress_from_integrity() -> void:
	build_progress = structural_fraction()


func apply_placement_integrity() -> void:
	var archetype := get_archetype()
	if archetype == null:
		return
	integrity = archetype.max_integrity * PLACEMENT_STRUCTURAL_FRACTION
	sync_build_progress_from_integrity()


func recalculate_integrity_from_materials() -> void:
	var archetype := get_archetype()
	if archetype == null:
		return
	var required := total_required_material_amount()
	var material_fraction := (
		1.0
		if required <= 0.0
		else clampf(total_installed_material_amount() / required, 0.0, 1.0)
	)
	integrity = archetype.max_integrity * (
		PLACEMENT_STRUCTURAL_FRACTION
		+ (1.0 - PLACEMENT_STRUCTURAL_FRACTION) * material_fraction
	)
	sync_build_progress_from_integrity()


func recalculate_build_progress() -> void:
	sync_build_progress_from_integrity()


func is_complete() -> bool:
	return structural_fraction() >= 1.0 - 0.000001


func is_broken() -> bool:
	return integrity <= 0.000001


func is_operational() -> bool:
	return is_complete() and not is_broken()


func status_reason() -> StringName:
	if is_broken():
		return &"element_broken"
	if not is_complete():
		return &"element_incomplete"
	return &"ok"


func industry_status_reason() -> StringName:
	var construction := status_reason()
	if construction != &"ok":
		return construction
	return industry_functional_reason


func occupied_cells() -> Array[Vector3i]:
	var archetype: ElementArchetype = get_archetype()
	if archetype == null:
		return []
	return archetype.get_occupied_cells(origin_cell, orientation_index)


func to_dict() -> Dictionary:
	var row := {
		"element_id": element_id,
		"assembly_id": assembly_id,
		"archetype_id": archetype_id,
		"origin_cell": _CODEC.vector3i_to_array(origin_cell),
		"orientation_index": orientation_index,
		"build_progress": build_progress,
		"integrity": integrity,
		"condition": condition,
		"state_revision": state_revision,
		"terrain_contact": terrain_contact,
		"installed_materials": installed_materials.duplicate(true),
	}
	if industry_functional_reason != &"ok":
		row["industry_functional_reason"] = industry_functional_reason
	if industry_buffer != null and not industry_buffer.resource_ids().is_empty():
		var capacity_l := IndustryArchetypeProfile.internal_buffer_capacity_l(
			archetype_id
		)
		row["industry_buffer"] = industry_buffer.to_dict(capacity_l)
	return row


static func from_dict(data: Dictionary) -> SimulationElement:
	var element: SimulationElement = _SCRIPT.new()
	element.element_id = int(data.get("element_id", 0))
	element.assembly_id = int(data.get("assembly_id", 0))
	element.archetype_id = str(data.get("archetype_id", ""))
	element.origin_cell = _CODEC.vector3i_from_variant(
		data.get("origin_cell", Vector3i.ZERO)
	)
	element.orientation_index = int(data.get("orientation_index", 0))
	element.build_progress = float(data.get("build_progress", 1.0))
	element.integrity = float(data.get("integrity", 0.0))
	element.condition = float(data.get("condition", 1.0))
	element.state_revision = int(data.get("state_revision", 0))
	element.terrain_contact = bool(data.get("terrain_contact", false))
	var functional_reason: Variant = data.get("industry_functional_reason", &"ok")
	if functional_reason is StringName:
		element.industry_functional_reason = functional_reason
	elif str(functional_reason) != "":
		element.industry_functional_reason = StringName(str(functional_reason))
	var materials: Variant = data.get("installed_materials", {})
	if materials is Dictionary:
		element.installed_materials = materials.duplicate(true)
	var buffer_data: Variant = data.get("industry_buffer", {})
	if buffer_data is Dictionary and not buffer_data.is_empty():
		element.industry_buffer = ElementIndustryBuffer.from_dict(buffer_data)
	return element
