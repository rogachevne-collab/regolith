class_name CoopSnapshotBroadcastUtil
extends RefCounted


static func mark_snapshot_dirty(session) -> void:
	# Same-frame structural_event + command_completed for one mutate: keep a
	# single debounce start. Later frames still refresh debounce (burst coalesce).
	var frame := Engine.get_process_frames()
	var snapshot_dirty: bool = session._snapshot_dirty
	var snapshot_dirty_frame: int = session._snapshot_dirty_frame
	if snapshot_dirty and snapshot_dirty_frame == frame:
		return
	session._snapshot_dirty = true
	session._snapshot_dirty_frame = frame
	session._snapshot_debounce = session.SNAPSHOT_DEBOUNCE


static func tick_snapshot_broadcast(session, delta: float) -> void:
	var snapshot_dirty: bool = session._snapshot_dirty
	if not snapshot_dirty:
		return
	var snapshot_debounce: float = session._snapshot_debounce
	snapshot_debounce -= delta
	session._snapshot_debounce = snapshot_debounce
	if snapshot_debounce > 0.0:
		return
	var last_broadcast_ms: int = session._last_broadcast_ms
	if Time.get_ticks_msec() - last_broadcast_ms < session.SNAPSHOT_FLOOR_MS:
		return
	session._snapshot_dirty = false
	var registry: CoopPeerRegistry = session._registry
	if registry.peer_ids().is_empty():
		return
	session._last_broadcast_ms = Time.get_ticks_msec()
	var world: SimulationWorld = session._world()
	session.rpc("_cli_apply_snapshot", world.capture_snapshot())
