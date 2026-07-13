class_name WorldLootPile
extends RefCounted

const _SCRIPT := preload(
	"res://scripts/simulation/runtime/world_loot_pile.gd"
)
const _CODEC := preload("res://scripts/simulation/snapshot_codec.gd")

var pile_id: int = 0
var position: Vector3 = Vector3.ZERO
var resource_id: String = ""
var amount_kg: float = 0.0
var despawn_at_s: float = 0.0


static func create(
	new_pile_id: int,
	new_position: Vector3,
	new_resource_id: String,
	new_amount_kg: float,
	new_despawn_at_s: float
) -> WorldLootPile:
	var pile: WorldLootPile = _SCRIPT.new()
	pile.pile_id = new_pile_id
	pile.position = new_position
	pile.resource_id = new_resource_id
	pile.amount_kg = maxf(new_amount_kg, 0.0)
	pile.despawn_at_s = new_despawn_at_s
	return pile


func to_dict() -> Dictionary:
	return {
		"pile_id": pile_id,
		"position": _CODEC.vector3_to_array(position),
		"resource_id": resource_id,
		"amount_kg": amount_kg,
		"despawn_at_s": despawn_at_s,
	}


static func from_dict(data: Dictionary) -> WorldLootPile:
	return create(
		int(data.get("pile_id", 0)),
		_CODEC.vector3_from_variant(data.get("position", Vector3.ZERO)),
		str(data.get("resource_id", "")),
		float(data.get("amount_kg", 0.0)),
		float(data.get("despawn_at_s", 0.0))
	)
