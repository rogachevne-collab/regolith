class_name ConstructionPerf
extends RefCounted
## Wall-clock buckets for construction preview hot path.
## Flip ENABLED to false when the answer is in (same pattern as granular).
##
## Printed once a second while the build tool is resolving. Numbers are
## accumulated ms over the period, not per-frame averages — quiet aim (cache
## hits only) stays silent. Use to split GDScript packing vs native call vs
## plan/validate vs seat/collision.

const ENABLED := false
const PERIOD_S := 1.0

static var update_us := 0
static var resolve_us := 0
static var snap_us := 0
static var snapshot_us := 0
static var scan_us := 0
static var scan_kernel_us := 0
static var prefilter_us := 0
static var plan_us := 0
static var plan_validate_us := 0
static var plan_autoface_us := 0
static var pack_attach_us := 0
static var body_groups_us := 0
static var validate_native_us := 0
static var validate_kernel_us := 0
static var seat_us := 0
static var collision_us := 0
static var sync_us := 0

static var resolves := 0
static var cache_hits := 0
static var heartbeats := 0
static var plans := 0
static var native_scans := 0
static var native_validates := 0

static var worst_resolve_us := 0
static var _report_left := PERIOD_S
static var _active := false


static func begin() -> int:
	return Time.get_ticks_usec() if ENABLED else 0


static func add(bucket: StringName, us: int) -> void:
	if not ENABLED or not _active or us <= 0:
		return
	match bucket:
		&"update_us":
			update_us += us
		&"resolve_us":
			resolve_us += us
			worst_resolve_us = maxi(worst_resolve_us, us)
		&"snap_us":
			snap_us += us
		&"snapshot_us":
			snapshot_us += us
		&"scan_us":
			scan_us += us
		&"scan_kernel_us":
			scan_kernel_us += us
		&"prefilter_us":
			prefilter_us += us
		&"plan_us":
			plan_us += us
		&"plan_validate_us":
			plan_validate_us += us
		&"plan_autoface_us":
			plan_autoface_us += us
		&"pack_attach_us":
			pack_attach_us += us
		&"body_groups_us":
			body_groups_us += us
		&"validate_native_us":
			validate_native_us += us
		&"validate_kernel_us":
			validate_kernel_us += us
		&"seat_us":
			seat_us += us
		&"collision_us":
			collision_us += us
		&"sync_us":
			sync_us += us


static func end(bucket: StringName, t0: int) -> int:
	if not ENABLED or t0 <= 0:
		return 0
	var us := Time.get_ticks_usec() - t0
	add(bucket, us)
	return us


static func count(counter: StringName, amount: int = 1) -> void:
	if not ENABLED or not _active or amount == 0:
		return
	match counter:
		&"resolves":
			resolves += amount
		&"cache_hits":
			cache_hits += amount
		&"heartbeats":
			heartbeats += amount
		&"plans":
			plans += amount
		&"native_scans":
			native_scans += amount
		&"native_validates":
			native_validates += amount


static func note_kernel_us(op: StringName, us: int) -> void:
	if not ENABLED or us <= 0:
		return
	match op:
		&"scan_magnetic_faces":
			add(&"scan_kernel_us", us)
		&"validate_attach_preview":
			add(&"validate_kernel_us", us)


static func set_active(active: bool) -> void:
	_active = active
	if not active:
		_report_left = PERIOD_S


## Call once per physics frame while the build tool is out.
static func tick(delta: float) -> void:
	if not ENABLED or not _active:
		return
	_report_left -= delta
	if _report_left > 0.0:
		return
	_report_left = PERIOD_S
	_print_report()
	_reset()


static func last_stats_timings() -> Dictionary:
	## Per-period snapshot for gateway/tests; zeros when profiling off.
	return {
		"resolve_us": resolve_us,
		"snap_us": snap_us,
		"snapshot_us": snapshot_us,
		"scan_us": scan_us,
		"scan_kernel_us": scan_kernel_us,
		"prefilter_us": prefilter_us,
		"plan_us": plan_us,
		"plan_validate_us": plan_validate_us,
		"plan_autoface_us": plan_autoface_us,
		"pack_attach_us": pack_attach_us,
		"body_groups_us": body_groups_us,
		"validate_native_us": validate_native_us,
		"validate_kernel_us": validate_kernel_us,
		"seat_us": seat_us,
		"collision_us": collision_us,
		"worst_resolve_us": worst_resolve_us,
	}


static func _print_report() -> void:
	var work_us := (
		resolve_us + sync_us + snapshot_us + scan_us + plan_us
		+ pack_attach_us + validate_native_us + seat_us + collision_us
	)
	if resolves == 0 and cache_hits + heartbeats == 0 and work_us < 500:
		return
	var marshall_scan_us := maxi(0, scan_us - scan_kernel_us)
	var marshall_validate_us := maxi(0, validate_native_us - validate_kernel_us)
	print(
		(
			"[construction] resolves %d  cache %d  hb %d  plans %d | "
			+ "update %.1f  resolve %.1f (worst %.1f)  snap %.1f  sync %.1f ms/s"
		)
		% [
			resolves,
			cache_hits,
			heartbeats,
			plans,
			update_us / 1000.0,
			resolve_us / 1000.0,
			worst_resolve_us / 1000.0,
			snap_us / 1000.0,
			sync_us / 1000.0,
		]
	)
	print(
		(
			"[construction]   snapshot %.1f  scan %.1f (kernel %.1f / marshal~%.1f)  "
			+ "prefilter %.1f  plan %.1f (validate %.1f / autoface %.1f) ms/s"
		)
		% [
			snapshot_us / 1000.0,
			scan_us / 1000.0,
			scan_kernel_us / 1000.0,
			marshall_scan_us / 1000.0,
			prefilter_us / 1000.0,
			plan_us / 1000.0,
			plan_validate_us / 1000.0,
			plan_autoface_us / 1000.0,
		]
	)
	print(
		(
			"[construction]   pack %.1f  body_groups %.1f  validate %.1f "
			+ "(kernel %.1f / marshal~%.1f)  seat %.1f  collision %.1f ms/s  "
			+ "native_scan %d  native_val %d"
		)
		% [
			pack_attach_us / 1000.0,
			body_groups_us / 1000.0,
			validate_native_us / 1000.0,
			validate_kernel_us / 1000.0,
			marshall_validate_us / 1000.0,
			seat_us / 1000.0,
			collision_us / 1000.0,
			native_scans,
			native_validates,
		]
	)


static func _reset() -> void:
	update_us = 0
	resolve_us = 0
	snap_us = 0
	snapshot_us = 0
	scan_us = 0
	scan_kernel_us = 0
	prefilter_us = 0
	plan_us = 0
	plan_validate_us = 0
	plan_autoface_us = 0
	pack_attach_us = 0
	body_groups_us = 0
	validate_native_us = 0
	validate_kernel_us = 0
	seat_us = 0
	collision_us = 0
	sync_us = 0
	resolves = 0
	cache_hits = 0
	heartbeats = 0
	plans = 0
	native_scans = 0
	native_validates = 0
	worst_resolve_us = 0
