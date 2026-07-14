extends Node
## Headless pure-logic gate for terminal inventory drag payload and slot mapping
## (INDUSTRY-V1 § Terminal inventory, Phase 2b).

const EPSILON := 0.000001


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _test_half_transfer_amounts():
		_abort()
		return
	if not _test_drag_payload_contract():
		_abort()
		return
	if not _test_drop_compatibility():
		_abort()
		return
	if not _test_slot_bind_mapping():
		_abort()
		return
	if not _test_command_target_for_store():
		_abort()
		return
	print("HUD-INVENTORY-TRANSFER: PASS")
	get_tree().quit(0)


func _test_half_transfer_amounts() -> bool:
	if not is_equal_approx(
		HudInventoryTransferUtil.half_transfer_amount(5.0, false),
		2.5
	):
		return _fail("bulk half of 5 must be 2.5")
	if not is_equal_approx(
		HudInventoryTransferUtil.half_transfer_amount(2.5, false),
		1.25
	):
		return _fail("bulk half of 2.5 must be 1.25")
	if HudInventoryTransferUtil.half_transfer_amount(5.0, true) != 2.0:
		return _fail("discrete half of 5 must be 2")
	if HudInventoryTransferUtil.half_transfer_amount(3.0, true) != 1.0:
		return _fail("discrete half of 3 must be 1")
	if HudInventoryTransferUtil.half_transfer_amount(2.0, true) != 1.0:
		return _fail("discrete half of 2 must be 1")
	if HudInventoryTransferUtil.half_transfer_amount(1.0, true) != 1.0:
		return _fail("discrete half of 1 must stay 1")
	if HudInventoryTransferUtil.half_transfer_amount(0.0, false) != 0.0:
		return _fail("zero stack half must stay zero")
	return true


func _test_drag_payload_contract() -> bool:
	var whole: Dictionary = HudInventoryTransferUtil.drag_payload(
		IndustryStoreService.PLAYER_STORE_ID,
		"raw_regolith",
		4.0,
		false,
		false
	)
	if String(whole.get("kind", "")) != HudInventoryTransferUtil.PAYLOAD_KIND:
		return _fail("payload kind must be hud_item")
	if whole.get("source_store_id", "") != IndustryStoreService.PLAYER_STORE_ID:
		return _fail("payload source_store_id mismatch")
	if whole.get("item_id", "") != "raw_regolith":
		return _fail("payload item_id mismatch")
	if not is_equal_approx(float(whole.get("amount", 0.0)), 4.0):
		return _fail("whole drag amount must equal stack amount")
	if bool(whole.get("discrete", true)):
		return _fail("raw_regolith payload must not be discrete")
	if bool(whole.get("half", true)):
		return _fail("whole drag must not set half flag")

	var half: Dictionary = HudInventoryTransferUtil.drag_payload(
		"buffer:12",
		"construction_component",
		5.0,
		true,
		true
	)
	if half.get("source_store_id", "") != "buffer:12":
		return _fail("half payload source_store_id mismatch")
	if float(half.get("amount", 0.0)) != 2.0:
		return _fail("discrete half payload amount must be 2")
	if not bool(half.get("half", false)):
		return _fail("half payload must record half=true")
	return true


func _test_drop_compatibility() -> bool:
	var payload: Dictionary = HudInventoryTransferUtil.drag_payload(
		IndustryStoreService.PLAYER_STORE_ID,
		"metal_ingot",
		1.0,
		false,
		false
	)
	if HudInventoryTransferUtil.is_compatible_drop(payload, IndustryStoreService.PLAYER_STORE_ID):
		return _fail("drop on same store must be rejected")
	if not HudInventoryTransferUtil.is_compatible_drop(payload, "element:7"):
		return _fail("drop on different store must be accepted")
	if HudInventoryTransferUtil.is_compatible_drop({"kind": "hud_block"}, "element:7"):
		return _fail("non hud_item payload must be rejected")
	var zero_payload: Dictionary = payload.duplicate(true)
	zero_payload["amount"] = 0.0
	if HudInventoryTransferUtil.is_compatible_drop(zero_payload, "element:7"):
		return _fail("zero amount payload must be rejected")

	var params: Dictionary = HudInventoryTransferUtil.transfer_parameters(payload, "element:7")
	if params.get("from_store_id", "") != IndustryStoreService.PLAYER_STORE_ID:
		return _fail("transfer from_store_id mismatch")
	if params.get("to_store_id", "") != "element:7":
		return _fail("transfer to_store_id mismatch")
	if params.get("resource_id", "") != "metal_ingot":
		return _fail("transfer resource_id mismatch")
	if float(params.get("amount", 0.0)) != 1.0:
		return _fail("transfer amount mismatch")
	return true


func _test_slot_bind_mapping() -> bool:
	var entry := {
		"item_id": "sintered_basalt",
		"amount": 3.5,
		"category": "material",
		"discrete": false,
	}
	var bind: Dictionary = HudInventoryTransferUtil.slot_bind_from_entry("element:42", entry)
	if bind.get("source_store_id", "") != "element:42":
		return _fail("slot bind source_store_id mismatch")
	if bind.get("item_id", "") != "sintered_basalt":
		return _fail("slot bind item_id mismatch")
	if not is_equal_approx(float(bind.get("amount", 0.0)), 3.5):
		return _fail("slot bind amount mismatch")
	if bool(bind.get("discrete", true)):
		return _fail("slot bind discrete flag mismatch")
	if bind.get("category", "") != "material":
		return _fail("slot bind category mismatch")
	return true


func _test_command_target_for_store() -> bool:
	if HudInventoryTransferUtil.element_id_for_store("element:15") != 15:
		return _fail("element store id parse failed")
	if HudInventoryTransferUtil.element_id_for_store("buffer:22") != 22:
		return _fail("buffer store id parse failed")
	if HudInventoryTransferUtil.element_id_for_store(IndustryStoreService.PLAYER_STORE_ID) != 0:
		return _fail("player store must not map to element id")

	var machine_target: Dictionary = HudInventoryTransferUtil.command_target_for_store("buffer:22")
	if not bool(machine_target.get("valid", false)):
		return _fail("machine command target must be valid")
	if int(machine_target.get("metadata", {}).get("element_id", 0)) != 22:
		return _fail("machine command target element_id mismatch")

	var player_target: Dictionary = HudInventoryTransferUtil.command_target_for_store(
		IndustryStoreService.PLAYER_STORE_ID
	)
	if not bool(player_target.get("valid", false)):
		return _fail("player transfer target must be valid")
	return true


func _fail(message: String) -> bool:
	push_error(message)
	print("HUD-INVENTORY-TRANSFER: FAIL — %s" % message)
	return false


func _abort() -> void:
	get_tree().quit(1)
