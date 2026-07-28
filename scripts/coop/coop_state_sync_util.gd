class_name CoopStateSyncUtil
extends RefCounted


static func broadcast_suits(session) -> void:
	var registry: CoopPeerRegistry = session._registry
	if registry.peer_ids().is_empty():
		return
	var world: SimulationWorld = session._world()
	if world == null:
		return
	var suits: Dictionary = {}
	for uid: String in world.list_suit_state_ids():
		var suit := world.get_suit_state(uid)
		if suit != null:
			suits[uid] = suit.to_dict()
	session.rpc("_cli_suits", suits)


static func cli_suits(session, suits: Dictionary) -> void:
	var world: SimulationWorld = session._world()
	if world == null:
		return
	for uid: Variant in suits:
		world.sync_suit_state(String(uid), suits[uid])


## Stage-5 interim (not a full delta system): 1 Hz like suits. Only stores /
## buffers / inventories whose content changed since the last send. Topology
## still rides the existing full-snapshot path. Dig ops stay on NO_BROADCAST +
## their own channel — store credits from dig reach clients here.
static func broadcast_stores(session) -> void:
	var registry: CoopPeerRegistry = session._registry
	if registry.peer_ids().is_empty():
		return
	var world: SimulationWorld = session._world()
	if world == null:
		return
	var payload: Dictionary = compute_store_broadcast_payload(session, world)
	var stores_out: Dictionary = payload["resource_stores"]
	var buffers_out: Dictionary = payload["buffers"]
	var inventories_out: Dictionary = payload["player_inventories"]
	var industry_runtimes_out: Dictionary = payload.get(
		"industry_runtimes",
		{}
	)
	if (
		stores_out.is_empty()
		and buffers_out.is_empty()
		and inventories_out.is_empty()
		and (
			not industry_runtimes_out is Dictionary
			or (industry_runtimes_out as Dictionary).is_empty()
		)
	):
		return
	session.rpc("_cli_stores", payload)


## Diffs stores/buffers/inventories against the last-sent cache and stamps the
## cache for whatever it finds changed. Extracted from `_broadcast_stores`
## (unchanged order/logic) so a headless test can call it without a live
## multiplayer peer — see test_coop_bug_regressions.gd (COOP-05). Stores diff
## on `revision`, not wire content: content-equality would wrongly treat a
## value that churned back to an earlier, unacked-send's content as
## "unchanged" and never resend it over the `unreliable_ordered` CH_STREAM.
static func compute_store_broadcast_payload(
	session,
	world: SimulationWorld
) -> Dictionary:
	var last_store_revision: Dictionary = session._last_store_revision
	var last_buffer_wire: Dictionary = session._last_buffer_wire
	var last_industry_runtime_wire: Dictionary = session._last_industry_runtime_wire
	var last_inventory_revision_sent: int = session._last_inventory_revision_sent
	var stores_out: Dictionary = {}
	for store: SimulationResourceStore in world.list_resource_stores():
		var prev_rev: Variant = last_store_revision.get(store.store_id, -1)
		if store.revision != prev_rev:
			stores_out[store.store_id] = store.to_dict()
			last_store_revision[store.store_id] = store.revision
	var buffers_out: Dictionary = {}
	for element: SimulationElement in world.list_elements_unsorted():
		if (
			element == null
			or element.industry_buffer == null
			or not IndustryArchetypeProfile.has_internal_buffer(
				element.archetype_id
			)
		):
			continue
		var wire: Dictionary = element.industry_buffer.to_dict()
		var prev: Variant = last_buffer_wire.get(element.element_id)
		if prev != wire:
			buffers_out[element.element_id] = wire
			last_buffer_wire[element.element_id] = wire
	var inventories_out: Dictionary = {}
	var inv_rev := world.get_player_inventory_revision()
	if inv_rev != last_inventory_revision_sent:
		session._last_inventory_revision_sent = inv_rev
		for player_uid: String in world.list_player_inventory_uids():
			var registry := world.get_player_inventory(player_uid)
			if registry != null:
				inventories_out[player_uid] = registry.to_dict()
	var industry_runtimes_out: Dictionary = {}
	for row: Dictionary in world.list_industry_element_runtimes():
		var element_id := int(row.get("element_id", 0))
		if element_id <= 0:
			continue
		var runtime_wire: Dictionary = row.get("runtime", {})
		if runtime_wire.is_empty():
			continue
		var slim := {
			"machine_enabled": bool(runtime_wire.get("machine_enabled", true)),
			"battery_kwh": float(runtime_wire.get("battery_kwh", 0.0)),
			"battery_initialized": bool(
				runtime_wire.get("battery_initialized", false)
			),
			"active_recipe_power_w": float(
				runtime_wire.get("active_recipe_power_w", 0.0)
			),
			"powered": bool(runtime_wire.get("powered", false)),
			"power_reason": str(runtime_wire.get("power_reason", "ok")),
		}
		var prev: Variant = last_industry_runtime_wire.get(element_id)
		if prev != slim:
			industry_runtimes_out[element_id] = slim
			last_industry_runtime_wire[element_id] = slim
	return {
		"resource_stores": stores_out,
		"buffers": buffers_out,
		"player_inventories": inventories_out,
		"industry_runtimes": industry_runtimes_out,
	}


static func cli_stores(session, payload: Dictionary) -> void:
	var mode: int = session._mode
	if mode != CoopSession.Mode.CLIENT:
		return
	var world: SimulationWorld = session._world()
	if world == null:
		return
	var stores: Variant = payload.get("resource_stores", {})
	if stores is Dictionary and not (stores as Dictionary).is_empty():
		world.sync_resource_stores(stores)
	var buffers: Variant = payload.get("buffers", {})
	if buffers is Dictionary and not (buffers as Dictionary).is_empty():
		world.sync_element_industry_buffers(buffers)
	var inventories: Variant = payload.get("player_inventories", {})
	if (
		inventories is Dictionary
		and not (inventories as Dictionary).is_empty()
	):
		world.sync_player_inventories(inventories)
	var industry_runtimes: Variant = payload.get("industry_runtimes", {})
	if (
		industry_runtimes is Dictionary
		and not (industry_runtimes as Dictionary).is_empty()
	):
		world.sync_industry_element_runtimes(industry_runtimes)


static func clear_store_wire_cache(session) -> void:
	var last_store_revision: Dictionary = session._last_store_revision
	var last_buffer_wire: Dictionary = session._last_buffer_wire
	var last_industry_runtime_wire: Dictionary = session._last_industry_runtime_wire
	last_store_revision.clear()
	last_buffer_wire.clear()
	last_industry_runtime_wire.clear()
	session._last_inventory_revision_sent = -1
	session._store_accum = 0.0
