class_name CoopPeerRegistry
extends RefCounted
## Host-side session table for COOP-HOST-V0 stage 3: multiplayer peer_id →
## stable player uid + nick + remote-avatar node. Peer ids are per-connection;
## the uid is what stores/suits key on, so everything gameplay touches goes
## through the uid, never the raw peer id.
##
## Pure logic apart from the avatar node ref (excluded from the headless tests).

var _by_peer: Dictionary = {}   # peer_id:int -> {uid, nick, avatar}


## `&"ok"`, `&"already_registered"` (same peer twice) or `&"uid_conflict"`
## (two connections claiming the same uid — the "two instances without a
## sandbox" footgun; caller should deny the join with a clear message).
func register(peer_id: int, uid: String, nick: String) -> StringName:
	if _by_peer.has(peer_id):
		return &"already_registered"
	for existing_peer: int in _by_peer:
		if String(_by_peer[existing_peer].get("uid", "")) == uid:
			return &"uid_conflict"
	_by_peer[peer_id] = {"uid": uid, "nick": nick, "avatar": null}
	return &"ok"


func unregister(peer_id: int) -> void:
	_by_peer.erase(peer_id)


func has_peer(peer_id: int) -> bool:
	return _by_peer.has(peer_id)


func uid_of(peer_id: int) -> String:
	return String(_by_peer.get(peer_id, {}).get("uid", ""))


## Reverse lookup for host → peer RPCs. 0 when the uid is not connected.
func peer_of(uid: String) -> int:
	if uid.is_empty():
		return 0
	for peer_id: int in _by_peer:
		if String(_by_peer[peer_id].get("uid", "")) == uid:
			return peer_id
	return 0


func nick_of(peer_id: int) -> String:
	return String(_by_peer.get(peer_id, {}).get("nick", ""))


func set_nick(peer_id: int, nick: String) -> void:
	if _by_peer.has(peer_id):
		_by_peer[peer_id]["nick"] = nick


func store_id_of(peer_id: int) -> String:
	var uid := uid_of(peer_id)
	return PlayerIdentity.store_id(uid) if not uid.is_empty() else ""


func set_avatar(peer_id: int, avatar: Node) -> void:
	if _by_peer.has(peer_id):
		_by_peer[peer_id]["avatar"] = avatar


func avatar_of(peer_id: int) -> Node:
	return _by_peer.get(peer_id, {}).get("avatar") as Node


func peer_ids() -> Array[int]:
	var ids: Array[int] = []
	for peer_id: int in _by_peer:
		ids.append(peer_id)
	ids.sort()
	return ids


## Serializable {peer_id: {uid, nick}} for the join payload's `peers` field.
func peers_payload() -> Dictionary:
	var out: Dictionary = {}
	for peer_id: int in _by_peer:
		out[peer_id] = {
			"uid": _by_peer[peer_id].get("uid", ""),
			"nick": _by_peer[peer_id].get("nick", ""),
		}
	return out
