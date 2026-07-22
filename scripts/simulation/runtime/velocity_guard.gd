class_name VelocityGuard
extends RefCounted

## Last-resort fence on body velocity, and the log that says it fired.
##
## This is NOT a fix for anything. Solver blow-ups, mass-ratio fights in
## actuator chains and rope snaps all still happen; the fence only stops their
## aftermath from becoming unrecoverable — a rover flung past the horizon, or a
## body whose velocity went NaN and can never come back on its own.
##
## Every trip is a bug that has already happened. The log exists to be read
## afterwards, not watched live, so nothing here prints per tick: trips are
## folded into one record per body per episode and written to
## `user://velocity_guard.log` in batches.
##
## Thresholds sit well clear of anything legitimate, deliberately:
## the moon is Ø19 km at g=1.62, so circular orbit is ~124 m/s and escape
## ~175 m/s, and the fastest authored rotor (rotor_base_large) tops out at
## 15.7 rad/s. A fence that clips real play is worse than no fence, because
## it teaches you to ignore the log.
##
## Jolt fences too, and did so before any of this existed:
## `physics/jolt_physics_3d/limits/max_linear_velocity` (500 m/s) and
## `.../max_angular_velocity` (2700°/s = 47.12 rad/s). Two consequences.
##
## One: tightening the numbers needs no code at all — those settings do it.
## What this class adds is the record of what tripped, and NaN, which Jolt
## passes through untouched (measured, not assumed). A body at NaN never
## recovers, so that path is the one that actually saves a session.
##
## Two: peaks in the log are read AFTER Jolt has already saturated them, so
## `peak_linear=500.0` and `peak_angular=47.1` mean "hit the engine ceiling,
## true magnitude unknown and higher" — not "reached exactly 500". Treat those
## two values as `>=`.

const MAX_LINEAR_M_S := 300.0
const MAX_ANGULAR_RAD_S := 40.0

const LOG_PATH := "user://velocity_guard.log"

## An episode is one continuous blow-up. It closes once the body has been back
## under the fence for this long, so a body that trips for 200 ticks straight
## costs one line, not 200.
const EPISODE_GAP_MS := 1000

## How often the static path bothers to look at the clock, close aged-out
## episodes and touch the disk. Nothing here runs every tick.
const SWEEP_INTERVAL_MS := 2000

const REASON_LINEAR := 1
const REASON_ANGULAR := 2
const REASON_NAN_LINEAR := 4
const REASON_NAN_ANGULAR := 8

## Off switches for tests and for bisecting a physics bug: with the fence up
## you cannot tell a solver explosion from a clamped one.
static var enabled := true
static var logging_enabled := true

static var max_linear_m_s := MAX_LINEAR_M_S
static var max_angular_rad_s := MAX_ANGULAR_RAD_S

## Live counters, for a console readout without opening the file.
static var trip_count := 0
static var episode_count := 0

static var _episodes: Dictionary = {}
static var _pending: PackedStringArray = PackedStringArray()
static var _last_sweep_ms := 0
static var _header_written := false


## Call last in `_integrate_forces`: `state.linear_velocity` set here is the
## velocity the engine integrates, so the fence gets the final word after the
## solver, contacts and any custom integration have had theirs.
static func clamp_state(
	body: RigidBody3D,
	state: PhysicsDirectBodyState3D
) -> void:
	if not enabled or body == null or state == null:
		return
	var linear := state.linear_velocity
	var angular := state.angular_velocity
	var reasons := 0
	# NaN first: it poisons every comparison below, and unlike an overspeed it
	# never recovers — a body that reaches NaN is gone until something zeroes
	# it. Zeroing loses the body's momentum, which is already meaningless.
	if not linear.is_finite():
		linear = Vector3.ZERO
		reasons |= REASON_NAN_LINEAR
	if not angular.is_finite():
		angular = Vector3.ZERO
		reasons |= REASON_NAN_ANGULAR
	var linear_speed := linear.length()
	var angular_speed := angular.length()
	if linear_speed > max_linear_m_s:
		linear *= max_linear_m_s / linear_speed
		reasons |= REASON_LINEAR
	if angular_speed > max_angular_rad_s:
		angular *= max_angular_rad_s / angular_speed
		reasons |= REASON_ANGULAR
	if reasons == 0:
		# The common path writes nothing back: a body inside the fence must not
		# have its velocity reassigned, or the fence itself becomes a force.
		_sweep()
		return
	trip_count += 1
	state.linear_velocity = linear
	state.angular_velocity = angular
	if logging_enabled:
		_record(body, state, reasons, linear_speed, angular_speed)
	_sweep()


## Close every open episode and write everything out. For shutdown, and for
## reading the log while the game is still running.
static func flush() -> void:
	var now := Time.get_ticks_msec()
	for id_variant: Variant in _episodes.keys():
		_pending.append(_format(_episodes[id_variant], now))
	_episodes.clear()
	_write_pending()


## Where the log actually landed. `user://` is
## `%APPDATA%\Godot\app_userdata\<project>\` on Windows, which is not obvious.
static func log_path_absolute() -> String:
	return ProjectSettings.globalize_path(LOG_PATH)


## Start a fresh log. Called by nothing automatically — sessions append, so a
## crash never costs you the record of what led to it.
static func reset_log() -> void:
	_episodes.clear()
	_pending.clear()
	_header_written = false
	trip_count = 0
	episode_count = 0
	if FileAccess.file_exists(LOG_PATH):
		DirAccess.remove_absolute(log_path_absolute())


static func _record(
	body: RigidBody3D,
	state: PhysicsDirectBodyState3D,
	reasons: int,
	linear_speed: float,
	angular_speed: float
) -> void:
	var id := body.get_instance_id()
	var now := Time.get_ticks_msec()
	var episode: Dictionary = _episodes.get(id, {})
	if episode.is_empty():
		episode = {
			"name": String(body.name),
			"assembly": int(body.get_meta("assembly_id", 0)),
			"mass": body.mass,
			"origin": state.transform.origin,
			"stamp": Time.get_datetime_string_from_system(false, true),
			"first_ms": now,
			"ticks": 0,
			"reasons": 0,
			"peak_linear": 0.0,
			"peak_angular": 0.0,
		}
		_episodes[id] = episode
		episode_count += 1
	# Dictionaries are references, so this mutates the stored episode.
	episode["last_ms"] = now
	episode["ticks"] = int(episode["ticks"]) + 1
	episode["reasons"] = int(episode["reasons"]) | reasons
	episode["peak_linear"] = maxf(float(episode["peak_linear"]), linear_speed)
	episode["peak_angular"] = maxf(float(episode["peak_angular"]), angular_speed)


static func _sweep() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_sweep_ms < SWEEP_INTERVAL_MS:
		return
	_last_sweep_ms = now
	for id_variant: Variant in _episodes.keys():
		var episode: Dictionary = _episodes[id_variant]
		# A body freed mid-blow-up stops reporting; age closes its episode the
		# same way calming down would, so nothing is lost silently.
		if now - int(episode["last_ms"]) < EPISODE_GAP_MS:
			continue
		_pending.append(_format(episode, now))
		_episodes.erase(id_variant)
	_write_pending()


static func _format(episode: Dictionary, now: int) -> String:
	var first_ms := int(episode["first_ms"])
	var last_ms := int(episode["last_ms"])
	var origin: Vector3 = episode["origin"]
	return (
		"%s  t=+%.1fs  %s  body=%s assembly=%d mass=%.0fkg"
		+ "  peak_linear=%.1f m/s  peak_angular=%.1f rad/s"
		+ "  ticks=%d over %.2fs  at (%.1f, %.1f, %.1f)"
	) % [
		episode["stamp"],
		first_ms / 1000.0,
		_reason_text(int(episode["reasons"])),
		episode["name"],
		int(episode["assembly"]),
		float(episode["mass"]),
		float(episode["peak_linear"]),
		float(episode["peak_angular"]),
		int(episode["ticks"]),
		maxf(last_ms - first_ms, 0) / 1000.0,
		origin.x,
		origin.y,
		origin.z,
	]


static func _reason_text(reasons: int) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if reasons & REASON_NAN_LINEAR:
		parts.append("NAN_LINEAR")
	if reasons & REASON_NAN_ANGULAR:
		parts.append("NAN_ANGULAR")
	if reasons & REASON_LINEAR:
		parts.append("LINEAR")
	if reasons & REASON_ANGULAR:
		parts.append("ANGULAR")
	if parts.is_empty():
		return "NONE"
	return "|".join(parts)


static func _write_pending() -> void:
	if _pending.is_empty():
		return
	# Append: a session that ends in a crash is exactly the one worth reading,
	# so the file outlives the run that produced it.
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		push_warning(
			"VelocityGuard: cannot write %s (%d)"
			% [LOG_PATH, FileAccess.get_open_error()]
		)
		_pending.clear()
		return
	file.seek_end()
	if not _header_written:
		_header_written = true
		file.store_line(
			"=== session %s  fence: %.0f m/s, %.0f rad/s ==="
			% [
				Time.get_datetime_string_from_system(false, true),
				max_linear_m_s,
				max_angular_rad_s,
			]
		)
		print("VelocityGuard: logging to %s" % log_path_absolute())
	for line: String in _pending:
		file.store_line(line)
	file.close()
	_pending.clear()
