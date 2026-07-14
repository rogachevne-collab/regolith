class_name HudInventoryTransferUtil
extends RefCounted
## Pure presentation helpers for terminal inventory drag/drop and transfer
## commands (INDUSTRY-V1 § Terminal inventory). No UI nodes; headless-testable.

const PAYLOAD_KIND := "hud_item"


static func element_id_for_store(store_id: String) -> int:
	var element_id := IndustryStoreService.parse_element_id_from_store(store_id)
	if element_id > 0:
		return element_id
	return IndustryStoreService.parse_buffer_element_id(store_id)


static func half_transfer_amount(amount: float, discrete: bool) -> float:
	if amount <= ResourceCatalog.EPSILON:
		return 0.0
	if discrete:
		return maxf(1.0, floorf(amount * 0.5))
	return amount * 0.5


static func drag_payload(
	source_store_id: String,
	item_id: String,
	stack_amount: float,
	discrete: bool,
	half: bool,
	instance_id: String = ""
) -> Dictionary:
	var requested := stack_amount
	if half:
		requested = half_transfer_amount(stack_amount, discrete)
	requested = ResourceCatalog.quantize_transfer_amount(item_id, requested)
	return {
		"kind": PAYLOAD_KIND,
		"source_store_id": source_store_id,
		"item_id": item_id,
		"amount": requested,
		"discrete": discrete,
		"half": half,
		"instance_id": instance_id,
	}


static func is_compatible_drop(payload: Variant, destination_store_id: String) -> bool:
	if destination_store_id.is_empty() or not payload is Dictionary:
		return false
	if String(payload.get("kind", "")) != PAYLOAD_KIND:
		return false
	var source_store_id := str(payload.get("source_store_id", ""))
	if source_store_id.is_empty() or source_store_id == destination_store_id:
		return false
	var item_id := str(payload.get("item_id", ""))
	if item_id.is_empty() or not ResourceCatalog.has_resource(item_id):
		return false
	var amount := float(payload.get("amount", 0.0))
	return amount > ResourceCatalog.EPSILON


static func transfer_parameters(
	payload: Dictionary,
	destination_store_id: String
) -> Dictionary:
	return {
		"from_store_id": str(payload.get("source_store_id", "")),
		"to_store_id": destination_store_id,
		"resource_id": str(payload.get("item_id", "")),
		"amount": float(payload.get("amount", 0.0)),
		"instance_id": str(payload.get("instance_id", "")),
	}


static func command_target_for_store(store_id: String) -> Dictionary:
	var element_id := element_id_for_store(store_id)
	if element_id > 0:
		return InteractionHit.create(
			Vector3.ZERO,
			Vector3.UP,
			0.0,
			InteractionHit.KIND_SIMULATION_ELEMENT,
			null,
			&"",
			{"element_id": element_id}
		).snapshot()
	return {
		"valid": true,
		"point": Vector3.ZERO,
		"normal": Vector3.UP,
		"distance": 0.0,
		"target_kind": InteractionHit.KIND_NONE,
		"collider": null,
		"target_id": &"",
		"metadata": {},
	}


static func slot_bind_from_entry(
	source_store_id: String,
	entry: Dictionary
) -> Dictionary:
	return {
		"source_store_id": source_store_id,
		"item_id": str(entry.get("item_id", "")),
		"amount": float(entry.get("amount", 0.0)),
		"discrete": bool(entry.get("discrete", false)),
		"category": str(entry.get("category", "")),
		"instance_id": str(entry.get("instance_id", "")),
	}
