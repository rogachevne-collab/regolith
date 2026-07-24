class_name CoopCommandCodec
extends RefCounted
## Pure serialization boundary for COOP-HOST-V0 stage 3. No scene deps, all
## static — headless-testable (see test_coop_codec.gd).
##
## Two jobs: (1) strip live Objects out of gateway command/result dicts so they
## survive an RPC with allow_object_decoding=false (invariant C2 — commands are
## plain serializable data), and (2) build/validate the join payload.
##
## Wire-position note (deviation from spec T2): world positions ride as plain
## Vector3, not PackedFloat64Array. This moon is Ø~19 km (radius ~9.5 km), not
## the spec's 1737 km; more importantly both peers run the identical custom
## double-precision 4.8 build (the friend gets our export), so Godot's binary
## Variant encoding carries 8-byte reals end to end. The `real_t_bits` handshake
## field hard-rejects any stock-float client before terrain math can diverge.

const PROTOCOL_VERSION := 1

## Command kinds a client may NOT run in coop stage 3. Either they need a live
## collider the wire can't carry, or they mutate terrain/granular state that is
## not replicated yet (stage 4). Refused client-side with `not_in_coop_yet`.
const BLOCKED_KINDS := {
	&"voxel_remove": true,          # carves host terrain — diverges until stage 4
	&"dig_terrain_debris": true,    # needs live target.collider
	&"scoop_spoil": true,           # host-local granular field
	&"dump_scoop": true,
	&"debug_spawn_spoil": true,
	&"place_block": true,           # legacy PlacedBlocks, live source node
	&"toggle_control_seat": true,   # needs collider + reparent (stage 7)
}


static func is_kind_blocked(kind: StringName) -> bool:
	return BLOCKED_KINDS.has(kind)


## True on a real_t=double engine build. 16777217 (2^24 + 1) is the first int
## not representable in float32, so a Vector3 component round-trips it only on a
## double build — a cheap, dependency-free build-precision probe.
static func real_is_double() -> bool:
	var probe := Vector3.ZERO
	probe.x = 16777217.0
	return probe.x == 16777217.0


static func real_t_bits() -> int:
	return 64 if real_is_double() else 32


## Deep-copy a gateway command and remove everything that cannot cross the wire:
## the top-level identity fields the host re-stamps, the live `source` node, the
## live `target.collider`, the client-precomputed `placement_plan` (host rebuilds
## it from archetype_id + target + orientation_index), and — defense in depth —
## any Object left anywhere in the structure.
static func sanitize_command(command: Dictionary) -> Dictionary:
	var clean := command.duplicate(true)
	for key: Variant in ["source", "id", "actor_uid", "store_id"]:
		clean.erase(key)
	var target: Variant = clean.get("target")
	if target is Dictionary:
		(target as Dictionary).erase("collider")
	var parameters: Variant = clean.get("parameters")
	if parameters is Dictionary:
		(parameters as Dictionary).erase("placement_plan")
	_strip_objects_inplace(clean)
	return clean


## Results are serializable today; keep them that way defensively.
static func sanitize_result(result: Dictionary) -> Dictionary:
	var clean := result.duplicate(true)
	_strip_objects_inplace(clean)
	return clean


## Recursively drop any dictionary entry / array element that is an Object.
## Mutates in place; call on a deep copy.
static func _strip_objects_inplace(value: Variant) -> void:
	if value is Dictionary:
		var dict := value as Dictionary
		for key: Variant in dict.keys():
			var entry: Variant = dict[key]
			if typeof(entry) == TYPE_OBJECT:
				dict.erase(key)
			elif entry is Dictionary or entry is Array:
				_strip_objects_inplace(entry)
	elif value is Array:
		var arr := value as Array
		var index := arr.size() - 1
		while index >= 0:
			var entry: Variant = arr[index]
			if typeof(entry) == TYPE_OBJECT:
				arr.remove_at(index)
			elif entry is Dictionary or entry is Array:
				_strip_objects_inplace(entry)
			index -= 1


## Host builds this once per joining peer. `snapshot` is a pure-data dict
## (WorldPersistence proves capture_snapshot() JSON-serializes), so it rides the
## RPC arg safely.
static func make_join_payload(
	snapshot: Dictionary,
	peers: Dictionary,
	host_uid: String,
	host_nick: String,
	host_pose: Dictionary,
	you_peer_id: int
) -> Dictionary:
	return {
		"protocol": PROTOCOL_VERSION,
		"real_t_bits": real_t_bits(),
		"generator_version": MoonTerrainParams.GENERATOR_VERSION,
		"seed": MoonTerrainParams.SEED,
		"snapshot": snapshot,
		"peers": peers,
		"host": {"uid": host_uid, "nick": host_nick, "pose": host_pose},
		"you": you_peer_id,
	}


## Protocol / build-precision / generator compatibility. Shared by the host's
## hello check and the client's join-payload check. `&"ok"` or first mismatch.
static func validate_handshake_fields(fields: Dictionary) -> StringName:
	if int(fields.get("protocol", -1)) != PROTOCOL_VERSION:
		return &"protocol_mismatch"
	if int(fields.get("real_t_bits", 0)) != real_t_bits():
		return &"real_t_mismatch"
	if (
		int(fields.get("generator_version", -1))
		!= MoonTerrainParams.GENERATOR_VERSION
	):
		return &"generator_mismatch"
	return &"ok"


## Client-side full join-payload check: handshake fields plus a real snapshot.
static func validate_join_payload(payload: Dictionary) -> StringName:
	var handshake := validate_handshake_fields(payload)
	if handshake != &"ok":
		return handshake
	if not (payload.get("snapshot") is Dictionary):
		return &"bad_snapshot"
	return &"ok"


## The compatibility fields a client sends in its hello (msg 1).
static func make_hello(uid: String, nick: String) -> Dictionary:
	return {
		"protocol": PROTOCOL_VERSION,
		"real_t_bits": real_t_bits(),
		"generator_version": MoonTerrainParams.GENERATOR_VERSION,
		"uid": uid,
		"nick": nick,
	}
