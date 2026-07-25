class_name GatewayReadModelService
extends RefCounted

## Archetypes shown on the moon map overlay (MAP-UI-01).
const MAP_STRUCTURE_ARCHETYPES := {
	"power_source": true,
	"power_distributor": true,
	"power_battery": true,
	"power_battery_small": true,
	"power_distributor_small": true,
	"stationary_drill": true,
	"cargo_store": true,
	"processor": true,
	"fabricator": true,
	"foundation": true,
	"cockpit": true,
	"passenger_seat": true,
}


## Player carry load for the toolbar fill bar: the same volume the terminal
## panel shows (stacks + tool instances), without building the entry list.
static func player_carry_load(gateway) -> Dictionary:
	var capacity_l: float = IndustryStoreService.player_carry_capacity_l()
	if gateway._session == null or gateway._session.world == null:
		return {"used_l": 0.0, "capacity_l": capacity_l, "valid": false}
	var store: SimulationResourceStore = gateway._session.world.get_resource_store(
		PlayerIdentity.store_id(gateway.actor_uid)
	)
	var used_l: float = store.volume_l() if store != null else 0.0
	var registry: PlayerInventoryRegistry = gateway._session.world.ensure_player_inventory(
		gateway.actor_uid
	)
	if registry != null:
		used_l += registry.volume_l()
	return {"used_l": used_l, "capacity_l": capacity_l, "valid": true}


## Read-only accessor for presentation (HUD Inventory / StoreView). Returns the
## authoritative store so the HUD can render its amounts; the HUD only reads it
## and never mutates simulation state (see docs/specs/HUD-UI-01.md).
static func resource_store(gateway, store_id: String) -> SimulationResourceStore:
	if gateway._session == null:
		return null
	return gateway._session.world.get_resource_store(store_id)


## Authoritative terminal inventory snapshot (INDUSTRY-V1 § Terminal inventory).
## Resolves player store, keyed element stores, and internal buffers. Unknown or
## unresolved ids return `{"valid": false, "reason": ...}` without mutating state.
static func store_snapshot(gateway, store_id: String) -> Dictionary:
	if gateway._session == null or gateway._session.world == null:
		return StoreSnapshotBuilder.failure(&"not_ready")
	return StoreSnapshotBuilder.build(gateway._session.world, store_id)


## Cabin power read model for seated transport HUD (charge + trip ETA).
## `assembly_id` 0 → currently seated rover assembly when available.
static func vehicle_power_snapshot(gateway, assembly_id: int = 0) -> Dictionary:
	if gateway._session == null or gateway._session.world == null:
		return VehiclePowerSnapshotBuilder.failure(&"not_ready")
	var resolved_id: int = assembly_id
	if resolved_id <= 0:
		resolved_id = int(gateway._resolve_active_rover_assembly_id())
	if resolved_id <= 0:
		return VehiclePowerSnapshotBuilder.failure(&"not_seated")
	return VehiclePowerSnapshotBuilder.build(gateway._session.world, resolved_id)


## Снапшот сборки для терминала управления (CONTROL-ACTIONS-V0).
## Резолв цели: сидя — своя сборка; иначе — сборка наведённого элемента
## (panel передаёт element_id из InteractionQuery).
static func control_terminal_snapshot(
	gateway,
	assembly_id: int = 0,
	hint_element_id: int = 0
) -> Dictionary:
	if gateway._session == null or gateway._session.world == null:
		return ControlTerminalSnapshotBuilder.failure(&"not_ready")
	# host_hint — сиденье / pin / прицел. Явный ControlSeat всегда побеждает.
	# Non-seat hint на той же сборке (K с рамы) билдер резолвит в детерминированный
	# ControlSeat той же сборки; без hint / вне сборки — host=0 (не silent
	# lowest-seat). Резолвится ВСЕГДА: hud кэширует assembly_id после первого
	# тика, и если hint гасить под `resolved_id <= 0`, со 2-го тика host=0.
	var resolved: Dictionary = _resolve_control_terminal_target(
		gateway, assembly_id, hint_element_id
	)
	if int(resolved["assembly_id"]) <= 0:
		return ControlTerminalSnapshotBuilder.failure(&"no_target")
	return ControlTerminalSnapshotBuilder.build(
		gateway._session.world,
		int(resolved["assembly_id"]),
		int(resolved["host_hint"])
	)


## Дешёвый снапшот пульта для ЗАКРЫТОГО окна: только хост + привязки бара, без
## обхода всей сборки/тревог/энергоблока. Полный control_terminal_snapshot нужен
## лишь открытому окну; закрытый пульт кормит компактную ленту этим.
static func control_terminal_bar_snapshot(
	gateway,
	assembly_id: int = 0,
	hint_element_id: int = 0
) -> Dictionary:
	if gateway._session == null or gateway._session.world == null:
		return ControlTerminalSnapshotBuilder.failure(&"not_ready")
	var resolved: Dictionary = _resolve_control_terminal_target(
		gateway, assembly_id, hint_element_id
	)
	if int(resolved["assembly_id"]) <= 0:
		return ControlTerminalSnapshotBuilder.failure(&"no_target")
	return ControlTerminalSnapshotBuilder.build_bar_only(
		gateway._session.world,
		int(resolved["assembly_id"]),
		int(resolved["host_hint"])
	)


## Резолв цели пульта: сидя — своя сборка/сиденье; иначе — сборка наведённого
## элемента (seat или non-seat). Occupied seat / pin остаётся host_hint;
## non-seat hint передаётся билдеру как есть — он выберет детерминированный
## ControlSeat той же сборки. host_hint резолвится всегда (кэш assembly_id).
static func _resolve_control_terminal_target(
	gateway,
	assembly_id: int,
	hint_element_id: int
) -> Dictionary:
	var resolved_id: int = assembly_id
	var host_hint: int = gateway._rover_seat_element_id
	if resolved_id <= 0:
		if host_hint > 0:
			resolved_id = int(gateway._resolve_active_rover_assembly_id())
		if resolved_id <= 0 and hint_element_id > 0:
			var element: SimulationElement = gateway._session.world.get_element(
				hint_element_id
			)
			if element != null:
				resolved_id = element.assembly_id
	if host_hint <= 0:
		host_hint = hint_element_id
	return {"assembly_id": resolved_id, "host_hint": host_hint}


static func player_inventory(gateway) -> PlayerInventoryRegistry:
	if gateway._session == null or gateway._session.world == null or gateway.actor_uid.is_empty():
		return null
	return gateway._session.world.ensure_player_inventory(gateway.actor_uid)


static func player_inventory_revision(gateway) -> int:
	if gateway._session == null or gateway._session.world == null:
		return 0
	return gateway._session.world.get_player_inventory_revision()


static func construction_archetype(
	gateway,
	archetype_id: String
) -> ElementArchetype:
	return gateway._get_archetype(archetype_id)


static func archetype_display_name(gateway, archetype_id: String) -> String:
	var archetype: ElementArchetype = gateway._get_archetype(archetype_id)
	var gateway_name: String = ""
	if archetype != null and not archetype.display_name.is_empty():
		gateway_name = archetype.display_name
	return HudTokens.archetype_label(archetype_id, gateway_name)


## Read-only map overlay rows for MapPanel (docs/specs/MAP-UI-01.md).
## Presentation only: never mutates simulation state.
static func map_overlay_entries(gateway) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if gateway._session == null or gateway._session.world == null:
		return rows
	var world: SimulationWorld = gateway._session.world
	for pile: Dictionary in world.list_world_loot_piles():
		var pile_pos: Vector3 = SnapshotCodec.vector3_from_variant(
			pile.get("position", Vector3.ZERO)
		)
		if not pile_pos.is_finite():
			continue
		var resource_id: String = str(pile.get("resource_id", ""))
		rows.append({
			"kind": "loot",
			"id": "loot:%d" % int(pile.get("pile_id", 0)),
			"resource_id": resource_id,
			"amount_kg": float(pile.get("amount_kg", 0.0)),
			"position": pile_pos,
		})
	for element: SimulationElement in world.list_elements():
		if element == null:
			continue
		if not MAP_STRUCTURE_ARCHETYPES.has(element.archetype_id):
			continue
		var pos: Vector3 = IndustryElectricBudget.element_world_position(
			world, element
		)
		if not pos.is_finite():
			continue
		rows.append({
			"kind": "structure",
			"id": "el:%d" % element.element_id,
			"archetype_id": element.archetype_id,
			"element_id": element.element_id,
			"position": pos,
		})
	return rows
