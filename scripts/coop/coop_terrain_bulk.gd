class_name CoopTerrainBulk
extends RefCounted
## Join-time cold dig catch-up: host VoxelStreamSQLite bytes (+ granular
## snapshot) over CH_BULK. Not a second dig_ops format — session ops stay
## `build_dig_op`; this ships the host dig-stream file so pre-host / post-
## restart holes exist for joiners. Terrain stays out of capture_snapshot.

## Inline the whole DB in the join payload when small; otherwise chunk.
const INLINE_SQLITE_MAX_BYTES := 384 * 1024
const CHUNK_SIZE_BYTES := 256 * 1024
## Soft warn — join still proceeds (large explored crust with
## save_generator_output can hit tens of MB).
const WARN_SQLITE_BYTES := 32 * 1024 * 1024
## Client waits this long for all chunks after join payload.
const CHUNK_WAIT_TIMEOUT_SEC := 120.0

## Session replica path — never the joiner's personal gen_vN/moon.sqlite.
const REPLICA_DIR := "user://coop_join_replica"
const REPLICA_DB_NAME := "moon.sqlite"


static func replica_database_path() -> String:
	return "%s/%s" % [REPLICA_DIR, REPLICA_DB_NAME]


static func split_sqlite_chunks(sqlite_bytes: PackedByteArray) -> Array:
	var chunks: Array = []
	if sqlite_bytes.is_empty():
		return chunks
	var offset := 0
	while offset < sqlite_bytes.size():
		var end := mini(offset + CHUNK_SIZE_BYTES, sqlite_bytes.size())
		chunks.append(sqlite_bytes.slice(offset, end))
		offset = end
	return chunks


static func join_sqlite_chunks(chunks: Array, expected_bytes: int) -> PackedByteArray:
	var out := PackedByteArray()
	for chunk_variant: Variant in chunks:
		if not (chunk_variant is PackedByteArray):
			return PackedByteArray()
		out.append_array(chunk_variant as PackedByteArray)
	if expected_bytes > 0 and out.size() != expected_bytes:
		return PackedByteArray()
	return out


## Meta embedded in join payload. `sqlite` is set only when inline.
static func make_bulk_meta(
	sqlite_bytes: PackedByteArray,
	granular: Dictionary,
	chunk_count: int,
	inline_sqlite: PackedByteArray = PackedByteArray()
) -> Dictionary:
	var meta := {
		"sqlite_bytes": sqlite_bytes.size(),
		"chunk_count": chunk_count,
		"granular": granular,
	}
	if not inline_sqlite.is_empty():
		meta["sqlite"] = inline_sqlite
	return meta


static func validate_bulk_meta(meta: Variant) -> StringName:
	if meta == null:
		return &"ok"
	if not (meta is Dictionary):
		return &"bad_terrain_bulk"
	var d: Dictionary = meta
	var nbytes := int(d.get("sqlite_bytes", 0))
	if nbytes < 0:
		return &"bad_terrain_bulk"
	var chunks := int(d.get("chunk_count", 0))
	if chunks < 0:
		return &"bad_terrain_bulk"
	if d.has("sqlite"):
		if not (d["sqlite"] is PackedByteArray):
			return &"bad_terrain_bulk"
		if (d["sqlite"] as PackedByteArray).size() != nbytes:
			return &"bad_terrain_bulk"
		if chunks != 0:
			return &"bad_terrain_bulk"
	elif nbytes > 0 and chunks <= 0:
		return &"bad_terrain_bulk"
	if d.has("granular") and not (d["granular"] is Dictionary):
		return &"bad_terrain_bulk"
	return &"ok"


## After host dig flush: join dig_ops = only ops appended during/after the
## flush when cold SQLite bytes exist (those holes are already in the file).
## Empty sqlite → full session ring (pre-bulk fallback).
static func select_join_dig_ops(
	dig_ops: Array,
	dig_mark: int,
	sqlite_bytes: PackedByteArray
) -> Array:
	if sqlite_bytes.is_empty():
		return dig_ops.duplicate()
	var mark := clampi(dig_mark, 0, dig_ops.size())
	return dig_ops.slice(mark)


## Host join: attach inline (≤ INLINE) or chunked meta. Empty sqlite+granular
## leaves payload unchanged. Warns on huge dig streams.
static func attach_to_join_payload(
	payload: Dictionary,
	sqlite_bytes: PackedByteArray,
	granular: Dictionary
) -> void:
	if sqlite_bytes.is_empty() and granular.is_empty():
		return
	if sqlite_bytes.size() >= WARN_SQLITE_BYTES:
		push_warning(
			(
				"Coop: dig-stream bulk is %.1f MiB — join may hitch (explored crust in SQLite)"
				% (float(sqlite_bytes.size()) / (1024.0 * 1024.0))
			)
		)
	if (
		not sqlite_bytes.is_empty()
		and sqlite_bytes.size() <= INLINE_SQLITE_MAX_BYTES
	):
		payload["terrain_bulk"] = make_bulk_meta(
			sqlite_bytes, granular, 0, sqlite_bytes
		)
		return
	var chunks := split_sqlite_chunks(sqlite_bytes)
	payload["terrain_bulk"] = make_bulk_meta(
		sqlite_bytes, granular, chunks.size()
	)


## Client join: inline `sqlite` or ordered chunks_by_seq → host dig DB bytes.
## Missing/partial chunks → empty (caller treats as timeout/incomplete).
static func resolve_join_sqlite(
	meta: Dictionary,
	chunks_by_seq: Dictionary = {}
) -> PackedByteArray:
	if meta.has("sqlite") and meta["sqlite"] is PackedByteArray:
		return meta["sqlite"] as PackedByteArray
	var nbytes := int(meta.get("sqlite_bytes", 0))
	var chunk_count := int(meta.get("chunk_count", 0))
	if nbytes <= 0 or chunk_count <= 0:
		return PackedByteArray()
	var ordered: Array = []
	for seq: int in range(chunk_count):
		if not chunks_by_seq.has(seq):
			return PackedByteArray()
		var piece: Variant = chunks_by_seq[seq]
		if not (piece is PackedByteArray):
			return PackedByteArray()
		ordered.append(piece)
	return join_sqlite_chunks(ordered, nbytes)
