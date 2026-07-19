class_name SuitState
extends Node
## Presentation-side VIEW of one player's suit. The authoritative state lives in
## `SimulationWorld` as `SimulationSuitState`, keyed by player id
## (COOP-HOST-V0 "Per-peer player state"); this node only mirrors it and
## re-emits `changed` so the HUD Vitals widget keeps its existing contract
## (see docs/PHYSICAL-LANGUAGE.md "Состояние скафандра" and
## docs/specs/HUD-UI-01.md).
##
## It owns no values: every read forwards to the world. If the world is not
## bound yet (headless scenes without a SimulationSession), the getters report
## a full suit rather than dividing by zero.

## Emitted whenever any current value of THIS player's suit actually changes.
signal changed

## Which suit in the world this view mirrors. Empty resolves to the owning
## player body's uid, so the scene file carries no identity of its own.
@export var player_id := ""

var _world: SimulationWorld


func _ready() -> void:
	# The gateway registers itself in _ready too, and the player scene may be
	# instanced before it, so keep retrying instead of binding once and
	# silently showing full bars forever.
	set_process(true)


## Explicit binding for scenes that build the world themselves (tests).
func bind_world(world: SimulationWorld) -> void:
	if _world == world:
		return
	if _world != null and _world.suit_changed.is_connected(_on_suit_changed):
		_world.suit_changed.disconnect(_on_suit_changed)
	_world = world
	if _world == null:
		return
	_world.suit_changed.connect(_on_suit_changed)
	_resolve_player_id()
	_world.ensure_suit_state(player_id)
	changed.emit()


## Resolved at bind time, not in _ready: children are ready before their
## parent, so the player body has not stamped its uid yet when this node runs.
func _resolve_player_id() -> void:
	if not player_id.is_empty():
		return
	var owner_body := get_parent()
	if owner_body != null and owner_body.has_meta("player_id"):
		player_id = str(owner_body.get_meta("player_id"))
	else:
		player_id = PlayerIdentity.local_uid()


func world() -> SimulationWorld:
	return _world


func fill() -> void:
	if _world != null:
		_world.fill_suit_state(player_id)


func apply_damage(amount: float, source: StringName = &"") -> void:
	if _world != null:
		_world.apply_suit_damage(player_id, amount, source)


func health_fraction() -> float:
	var suit := _suit()
	return 1.0 if suit == null else suit.health_fraction()


func oxygen_fraction() -> float:
	var suit := _suit()
	return 1.0 if suit == null else suit.oxygen_fraction()


func hydrogen_fraction() -> float:
	var suit := _suit()
	return 1.0 if suit == null else suit.hydrogen_fraction()


func is_dead() -> bool:
	var suit := _suit()
	return suit != null and suit.is_dead()


func _suit() -> SimulationSuitState:
	if _world == null:
		return null
	return _world.get_suit_state(player_id)


func _process(_delta: float) -> void:
	var gateway := get_tree().get_first_node_in_group(
		&"world_command_gateway"
	) as WorldCommandGateway
	if gateway == null:
		return
	var world_node := gateway.get_world()
	if world_node == null:
		return
	bind_world(world_node)
	set_process(false)


func _on_suit_changed(changed_player_id: String) -> void:
	if changed_player_id == player_id:
		changed.emit()
