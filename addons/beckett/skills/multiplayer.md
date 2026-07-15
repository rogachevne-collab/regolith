# High-level multiplayer — RPCs + scene replication over the network

> SceneMultiplayer + ENetMultiplayerPeer + @rpc + MultiplayerSpawner/Synchronizer. Authority gates everything.

Networking is accessed through the `multiplayer` property on any Node (a `MultiplayerAPI`, concretely `SceneMultiplayer` in 4.x). Nothing happens until you assign a working `MultiplayerPeer`.

## Version note
- **@rpc annotation + `set_multiplayer_authority` + `SceneMultiplayer` + `MultiplayerSpawner`/`MultiplayerSynchronizer`/`SceneReplicationConfig`** — Godot **4.0** (replaced 3.x `remote`/`master`/`puppet` keywords; `NetworkedMultiplayerENet` → `ENetMultiplayerPeer`).
- **`SceneReplicationConfig.property_set_replication_mode` / `property_get_replication_mode` + `ReplicationMode` enum** — Godot **4.2**. The older `property_set_sync`/`property_set_watch` are deprecated since 4.2 (ALWAYS replaces sync, ON_CHANGE replaces watch).

Server runs 4.6.2 (baseline 4.3+). Confirm with `get_godot_version` / `describe_class class=SceneReplicationConfig`.

## Required setup
- Start networking: build an `ENetMultiplayerPeer`, call `create_server(port, max_clients=32)` or `create_client(address, port)`, check the return is `OK` (0), then `multiplayer.multiplayer_peer = peer`. Stop with `multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()`.
- The standard "good path" is a **Network/GameManager autoload** that creates the peer and connects the `MultiplayerAPI` signals (Project Settings > Autoload). Not engine-required, but expected.
- **Node identity:** an `@rpc` method or replicated node must exist at the **same NodePath with the same name on every peer**. Declare every `@rpc` method identically on all builds even where unused.
- `MultiplayerSpawner`: set `spawn_path` to the container node, register scenes via `add_spawnable_scene(path)`. Spawn only on the authority.
- `MultiplayerSynchronizer`: set `root_path`, assign a `SceneReplicationConfig` to `replication_config`, add properties (`:position`, `:health`). Only the authority sends.

## Transport — ENetMultiplayerPeer (extends MultiplayerPeer)
- `create_server(port: int, max_clients: int = 32, ...) -> Error` (up to 4095 clients; ports <1024 need elevation).
- `create_client(address: String, port: int, ...) -> Error`, `create_mesh(unique_id: int) -> Error`, `set_bind_ip(ip: String)`.
- `WebSocketMultiplayerPeer` / `WebRTCMultiplayerPeer` are drop-in alternatives.

## MultiplayerAPI / SceneMultiplayer
- `get_unique_id() -> int` (server/offline = 1), `is_server() -> bool`, `get_peers() -> PackedInt32Array`, `get_remote_sender_id() -> int` (valid **only inside an RPC body**; 0 otherwise).
- Signals: `peer_connected(id)` / `peer_disconnected(id)` fire on **all** peers; `connected_to_server()` / `connection_failed()` / `server_disconnected()` fire on **clients only**.
- `SceneMultiplayer` extras: `root_path` (NodePath), `refuse_new_connections` (bool), `allow_object_decoding` (bool, keep **false**), `server_relay` (bool, default true), `auth_callback` (Callable), `auth_timeout` (float, 3.0); `send_bytes(bytes, id=0, mode=2, channel=0)`, `disconnect_peer(id)`, `complete_auth(id)`; signal `peer_packet(id, packet)`.

## @rpc annotation (4 optional args)
`@rpc(mode, sync, transfer_mode, transfer_channel)`
- **mode:** `"authority"` (default — only the node's authority may invoke) | `"any_peer"` (any peer; needed for client→server input).
- **sync:** `"call_remote"` (default — runs on remote peers, NOT the caller) | `"call_local"` (also runs locally).
- **transfer_mode:** `"reliable"` (default) | `"unreliable"` (positions) | `"unreliable_ordered"`.
- **transfer_channel:** int, default 0.
- Call: `method.rpc(args)` broadcasts; `method.rpc_id(1, args)` targets the server; `rpc_id(peer_id, ...)` one peer; `rpc_id(0, ...)` all; a **negative** id targets all EXCEPT that peer.

## Replication — SceneReplicationConfig
- `add_property(path: NodePath, index: int = -1)` (e.g. `":position"`), `remove_property(path)`, `has_property(path) -> bool`, `get_properties() -> Array[NodePath]`.
- `property_set_replication_mode(path, mode: ReplicationMode)` / `property_get_replication_mode(path)`.
- `ReplicationMode`: `REPLICATION_MODE_NEVER=0`, `REPLICATION_MODE_ALWAYS=1` (per-tick, **unreliable** — positions), `REPLICATION_MODE_ON_CHANGE=2` (**reliable**, only on change — health/state).
- `property_set_spawn(path, enabled: bool)` — copy value once at spawn (seed state).
- `MultiplayerSynchronizer`: `replication_config`, `root_path` (default `..`), `replication_interval`/`delta_interval` (float, 0 = every frame), `public_visibility` (bool), `add_visibility_filter(Callable)`, `set_visibility_for(peer, visible)`.

## Recipe — host/join autoload (MCP-driven)
```
write_script path=res://net.gd content="""
extends Node
const PORT := 7777
func host() -> Error:
	var p := ENetMultiplayerPeer.new()
	var e := p.create_server(PORT, 32)
	if e != OK: return e
	multiplayer.multiplayer_peer = p
	return OK
func join(ip: String) -> Error:
	var p := ENetMultiplayerPeer.new()
	var e := p.create_client(ip, PORT)
	if e != OK: return e
	multiplayer.multiplayer_peer = p
	return OK
func _ready() -> void:
	multiplayer.peer_connected.connect(func(id): print("joined ", id))
	multiplayer.server_disconnected.connect(func(): print("server gone"))
"""
```
Register `net.gd` as an autoload; call `host()` on the server build, `join(ip)` on clients. `play_scene`, then `assert_node_state` that `multiplayer.get_unique_id()==1` on the server.

## Recipe — client input → server, applied everywhere
```
write_script path=res://player.gd content="""
extends CharacterBody2D
const SPEED := 220.0
@rpc(\"any_peer\", \"call_local\", \"unreliable\")
func apply_move(dir: Vector2) -> void:
	var sender := multiplayer.get_remote_sender_id()   # validate ownership server-side
	position += dir * SPEED * get_physics_process_delta_time()
"""
```
Client sends to the server: `apply_move.rpc_id(1, input_dir)`. Declare the method identically on every build.

## Recipe — spawn + sync players
```
create_node type=MultiplayerSpawner name=PlayerSpawner parent=Main
set_property target=Main/PlayerSpawner property=spawn_path value="../Players"
call_method target=Main/PlayerSpawner method=add_spawnable_scene args=["res://player.tscn"]
# inside player.tscn:
create_node type=MultiplayerSynchronizer name=Sync parent=Player
set_resource target=Player/Sync property=replication_config class=SceneReplicationConfig
call_method target=<the SceneReplicationConfig> method=add_property args=[":position"]
call_method target=<the SceneReplicationConfig> method=property_set_replication_mode args=[":position", 1]
# on the server, right after spawning: player.set_multiplayer_authority(peer_id)
```
On the authority, add the player instance as a child of `Players` (auto-replicates, including to late joiners), or use `spawn_function` + `spawn(data)`. Guard input with `is_multiplayer_authority()`.

## Common traps
- A plain `@rpc` defaults to `"authority"` + `"call_remote"`: it does **not** run on the caller and cannot be invoked by clients. For input you almost always need `"any_peer"` (+ `"call_local"` to apply it locally too).
- `get_remote_sender_id()` is 0 outside an RPC body — always validate it server-side so clients can't spoof actions on nodes they don't own.
- Only the **authority** sends for a `MultiplayerSynchronizer` and may spawn via `MultiplayerSpawner`. Set ownership with `set_multiplayer_authority(id, recursive=true)`, consistently (usually server, right after spawn) so all peers agree.
- `spawn_function` must return an **unparented** node — the spawner adds it to the tree; don't add it yourself (double-parent error).
- `MultiplayerSynchronizer` cannot replicate Object-typed properties or peer-unique ids. Use `property_set_spawn` for one-time seed values, a replication mode for ongoing state.
- `REPLICATION_MODE_ALWAYS` is unreliable per-tick (positions); `REPLICATION_MODE_ON_CHANGE` is reliable-on-change (health). Don't expect cheap reliability from ALWAYS.
- `create_server`/`create_client` return an `Error` — check `OK` (0) before assigning the peer.
- Keep `allow_object_decoding=false`; gate joins with `refuse_new_connections` / `auth_callback`.

Confirm exact names, signatures, and enum values with `describe_class` (e.g. `MultiplayerSynchronizer`, `SceneReplicationConfig`) before relying on them.
