class_name PlayerIdentity
extends RefCounted
## Who a player is, independently of how they connected.
##
## A player owns a resource store (`player:<uid>`) and a suit state (keyed by
## the bare uid). Before COOP-HOST-V0 both were the single literal "player",
## which means every peer would share one rucksack; the id is now explicit so
## N players get N stores.
##
## `uid` is stable across sessions and generated once per machine, because the
## save keys player state by uid — a peer id would change on every reconnect
## (COOP-HOST-V0 "Per-peer store"). Under coop the host maps peer id → uid on
## join; until then only the local uid exists.

const STORE_PREFIX := "player:"
const LOCAL_UID_PATH := "user://player_uid.txt"

static var _local_uid := ""


## The store id owned by `player_uid`. Never build this string by hand.
static func store_id(player_uid: String) -> String:
	return "%s%s" % [STORE_PREFIX, player_uid]


static func is_player_store(candidate_store_id: String) -> bool:
	return candidate_store_id.begins_with(STORE_PREFIX)


## Empty when the store belongs to a machine rather than a player.
static func uid_from_store(candidate_store_id: String) -> String:
	if not is_player_store(candidate_store_id):
		return ""
	return candidate_store_id.substr(STORE_PREFIX.length())


## This machine's player. Generated once and persisted, so a save written
## today still matches its owner tomorrow.
static func local_uid() -> String:
	if not _local_uid.is_empty():
		return _local_uid
	_local_uid = _read_local_uid()
	if _local_uid.is_empty():
		_local_uid = _generate_uid()
		_write_local_uid(_local_uid)
	return _local_uid


static func local_store_id() -> String:
	return store_id(local_uid())


## Tests and headless fixtures pin the uid instead of touching user://.
static func override_local_uid(player_uid: String) -> void:
	_local_uid = player_uid


static func _generate_uid() -> String:
	# Uniqueness only has to hold across the players of one session, so a
	# random 64-bit value is plenty and needs no coordination.
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%08x%08x" % [rng.randi(), rng.randi()]


static func _read_local_uid() -> String:
	if not FileAccess.file_exists(LOCAL_UID_PATH):
		return ""
	var file := FileAccess.open(LOCAL_UID_PATH, FileAccess.READ)
	if file == null:
		return ""
	var stored := file.get_as_text().strip_edges()
	file.close()
	return stored


static func _write_local_uid(player_uid: String) -> void:
	var file := FileAccess.open(LOCAL_UID_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("PlayerIdentity: cannot persist local uid")
		return
	file.store_string(player_uid)
	file.close()
