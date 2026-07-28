class_name CoopDigRelayUtil
extends RefCounted


static func should_soft_retry_guest_dig(
	session,
	result: Dictionary,
	attempts: int
) -> bool:
	if attempts >= session.GUEST_DIG_RETRY_MAX:
		return false
	if not CoopSession.DIG_OP_KINDS.has(StringName(result.get("command_kind", &""))):
		return false
	return StringName(result.get("reason", &"")) == &"terrain_unavailable"


## Host: re-run guest digs that failed while Clipbox loaded the proxy shell.
## Interval backoff — not every physics tick (R9); no extra client RPCs.
static func tick_guest_dig_retries(session, delta: float) -> void:
	var guest_dig_retries: Array = session._guest_dig_retries
	if guest_dig_retries.is_empty():
		return
	var registry: CoopPeerRegistry = session._registry
	var remaining: Array = []
	for entry_variant: Variant in guest_dig_retries:
		if not (entry_variant is Dictionary):
			continue
		var entry: Dictionary = entry_variant
		var wait := float(entry.get("wait", 0.0)) - delta
		if wait > 0.0:
			entry["wait"] = wait
			remaining.append(entry)
			continue
		var peer := int(entry.get("peer", 0))
		if not registry.has_peer(peer):
			continue
		session._route_guest_submit(
			peer,
			int(entry.get("local_id", 0)),
			entry.get("command", {}),
			int(entry.get("attempts", 0))
		)
	session._guest_dig_retries = remaining


## Retry join dig_ops that failed while the local chunk was not editable.
## Light interval — not every physics tick (R9).
static func tick_pending_dig_reapply(session, delta: float) -> void:
	var pending_dig_ops: Array = session._pending_dig_ops
	var gateway: WorldCommandGateway = session._gateway
	if pending_dig_ops.is_empty() or gateway == null:
		return
	var pending_dig_accum: float = session._pending_dig_accum
	pending_dig_accum += delta
	if pending_dig_accum < session.PENDING_DIG_RETRY_INTERVAL:
		session._pending_dig_accum = pending_dig_accum
		return
	session._pending_dig_accum = 0.0
	var remaining: Array = []
	var recovered := 0
	for op_variant: Variant in pending_dig_ops:
		if op_variant is Dictionary and gateway.replay_remote_dig(op_variant):
			recovered += 1
		else:
			remaining.append(op_variant)
	session._pending_dig_ops = remaining
	if recovered > 0 and remaining.is_empty():
		session._info("join dig replay: recovered %d pending op(s)" % recovered)
	elif recovered > 0:
		push_warning(
			"join dig replay: recovered %d, %d still pending"
			% [recovered, remaining.size()]
		)


## Ring cap for host session dig log (join catch-up + live relay). Drop-oldest
## beyond MAX_DIG_OPS — late joiners miss terrain carved before the window.
static func append_dig_op(session, op: Dictionary) -> void:
	var dig_ops: Array = session._dig_ops
	dig_ops.append(op)
	var truncated := 0
	while dig_ops.size() > session.MAX_DIG_OPS:
		dig_ops.pop_front()
		truncated += 1
	if truncated > 0:
		push_warning(
			"Coop: dig_ops ring truncated — dropped %d oldest (cap %d); late joiners miss early digs"
			% [truncated, session.MAX_DIG_OPS]
		)
