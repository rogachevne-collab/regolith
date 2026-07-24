class_name InteractionHit
extends RefCounted

const KIND_NONE := &"none"
const KIND_VOXEL := &"voxel"
const KIND_BODY := &"body"
const KIND_PLACED_BLOCK := &"placed_block"
const KIND_CONTROL_SEAT := &"control_seat"
const KIND_SIMULATION_ELEMENT := &"simulation_element"
const KIND_WORLD_LOOT := &"world_loot"
const KIND_ELECTRIC_CABLE := &"electric_cable"
const KIND_TERRAIN_DEBRIS := &"terrain_debris"
## Loose material lying on the ground (`GranularPatch`). A separate kind from
## KIND_VOXEL because it is not the SDF: digging it moves thickness on a patch
## rather than carving rock, and it is the one target the drill can clear
## faster than stone.
const KIND_GRANULAR := &"granular"

var valid := false
var point := Vector3.ZERO
var normal := Vector3.UP
var distance := 0.0
var target_kind: StringName = KIND_NONE
var collider: Object
var target_id := StringName()

## Ray / bypass identity — sim card keys live on InteractionCard, not here.
var element_id := 0
var assembly_id := 0
var aim_direction := Vector3.FORWARD
var collider_local_cell := Vector3i.ZERO
## True only when collider_local_cell was authored / projected (cell ZERO is valid).
var has_collider_local_cell := false
var snap_cell := Vector3i.ZERO
var snap_dir := Vector3i.ZERO
var locked_snap_dir := Vector3i.ZERO
var locked_target_port_cell := Vector3i.ZERO
## True when attach face was locked for rotate/re-aim (port cell ZERO is valid).
var has_locked_attach := false
var electric_link_id := 0
var loot_pile_id := 0
var loot_resource_id := ""
var loot_amount_kg := 0.0
var placed_block_cell := Vector3i.ZERO
var granular := false
var control_seat := false


static func empty() -> InteractionHit:
	return InteractionHit.new()


static func create(
	hit_point: Vector3,
	hit_normal: Vector3,
	hit_distance: float,
	kind: StringName,
	hit_collider: Object = null,
	id := StringName(),
	extra: Dictionary = {}
) -> InteractionHit:
	var result := InteractionHit.new()
	result.valid = true
	result.point = hit_point
	result.normal = hit_normal.normalized()
	result.distance = hit_distance
	result.target_kind = kind
	result.collider = hit_collider
	result.target_id = id
	result.apply_fields(extra)
	return result


func apply_fields(data: Dictionary) -> void:
	if data.is_empty():
		return
	if data.has("element_id"):
		element_id = int(data["element_id"])
	if data.has("assembly_id"):
		assembly_id = int(data["assembly_id"])
	if data.has("aim_direction"):
		aim_direction = Vector3(data["aim_direction"])
	if data.has("collider_local_cell"):
		collider_local_cell = Vector3i(data["collider_local_cell"])
		has_collider_local_cell = true
	if data.has("has_collider_local_cell"):
		has_collider_local_cell = bool(data["has_collider_local_cell"])
	if data.has("snap_cell"):
		snap_cell = Vector3i(data["snap_cell"])
	if data.has("snap_dir"):
		snap_dir = Vector3i(data["snap_dir"])
	if data.has("locked_snap_dir"):
		locked_snap_dir = Vector3i(data["locked_snap_dir"])
		has_locked_attach = true
	if data.has("locked_target_port_cell"):
		locked_target_port_cell = Vector3i(data["locked_target_port_cell"])
		has_locked_attach = true
	if data.has("has_locked_attach"):
		has_locked_attach = bool(data["has_locked_attach"])
	if data.has("electric_link_id"):
		electric_link_id = int(data["electric_link_id"])
	if data.has("loot_pile_id"):
		loot_pile_id = int(data["loot_pile_id"])
	if data.has("resource_id"):
		loot_resource_id = str(data["resource_id"])
	if data.has("amount_kg"):
		loot_amount_kg = float(data["amount_kg"])
	if data.has("cell"):
		placed_block_cell = Vector3i(data["cell"])
	if data.has("granular"):
		granular = bool(data["granular"])
	if data.has("control_seat"):
		control_seat = bool(data["control_seat"])


func card(world: SimulationWorld) -> InteractionCard:
	if element_id <= 0 or world == null:
		return null
	return world.get_interaction_card(element_id)


func card_keys(world: SimulationWorld) -> Dictionary:
	var card_ref := card(world)
	if card_ref == null:
		return {}
	return card_ref.keys


func snapshot() -> Dictionary:
	var data := {
		"valid": valid,
		"point": point,
		"normal": normal,
		"distance": distance,
		"target_kind": target_kind,
		"collider": collider,
		"target_id": target_id,
		"element_id": element_id,
		"assembly_id": assembly_id,
		"aim_direction": aim_direction,
		"snap_cell": snap_cell,
		"snap_dir": snap_dir,
		"electric_link_id": electric_link_id,
		"loot_pile_id": loot_pile_id,
		"loot_resource_id": loot_resource_id,
		"loot_amount_kg": loot_amount_kg,
		"placed_block_cell": placed_block_cell,
		"granular": granular,
		"control_seat": control_seat,
	}
	# Optional geometry: omit when unset so ZERO is not mistaken for absence.
	if has_collider_local_cell:
		data["collider_local_cell"] = collider_local_cell
		data["has_collider_local_cell"] = true
	if has_locked_attach:
		data["locked_target_port_cell"] = locked_target_port_cell
		data["locked_snap_dir"] = locked_snap_dir
		data["has_locked_attach"] = true
	return data


static func from_snapshot(data: Dictionary) -> InteractionHit:
	if not bool(data.get("valid", false)):
		return empty()
	var result := InteractionHit.new()
	result.valid = true
	result.point = data.get("point", Vector3.ZERO)
	result.normal = Vector3(data.get("normal", Vector3.UP)).normalized()
	result.distance = float(data.get("distance", 0.0))
	result.target_kind = StringName(data.get("target_kind", KIND_NONE))
	result.collider = data.get("collider")
	result.target_id = StringName(data.get("target_id", &""))
	result.apply_fields(data)
	return result


static func element_id_from(target: Dictionary) -> int:
	return int(target.get("element_id", 0))


static func assembly_id_from(target: Dictionary) -> int:
	return int(target.get("assembly_id", 0))


static func aim_direction_from(target: Dictionary) -> Vector3:
	return Vector3(target.get("aim_direction", Vector3.FORWARD))


static func electric_link_id_from(target: Dictionary) -> int:
	return int(target.get("electric_link_id", 0))


static func loot_pile_id_from(target: Dictionary) -> int:
	return int(target.get("loot_pile_id", 0))


static func has_collider_local_cell_in(target: Dictionary) -> bool:
	return (
		bool(target.get("has_collider_local_cell", false))
		or target.has("collider_local_cell")
	)


static func has_locked_attach_in(target: Dictionary) -> bool:
	return (
		bool(target.get("has_locked_attach", false))
		or (
			target.has("locked_target_port_cell")
			and target.has("locked_snap_dir")
		)
	)
