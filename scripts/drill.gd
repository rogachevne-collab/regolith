extends Node

class CrossfadeBed:
	const SILENCE_DB := -80.0
	## How early the next clip starts (silent) before the audible fade.
	const PREROLL_S := 0.45
	## Skip this much of the next clip so its attack transient is already gone.
	const SKIP_ATTACK_S := 0.4
	const ATTACK_S := 0.28
	const RELEASE_S := 0.16

	var a: AudioStreamPlayer
	var b: AudioStreamPlayer
	var streams: Array[AudioStream] = []
	var volume_db := -5.0
	var crossfade_s := 1.4
	var pitch_jitter := 0.0
	var lead_is_a := true
	var last_stream_i := -1
	var xfading := false
	var xfade_t := 0.0
	var xfade_dur := 0.9
	var lag_primed := false
	var attacking := false
	var attack_t := 0.0
	var releasing := false
	var release_t := 0.0
	var active := false

	func setup(
		player_a: AudioStreamPlayer,
		player_b: AudioStreamPlayer,
		bed_streams: Array[AudioStream],
		bed_volume_db: float,
		bed_crossfade_s: float,
		bed_pitch_jitter: float
	) -> void:
		a = player_a
		b = player_b
		streams = bed_streams
		volume_db = bed_volume_db
		crossfade_s = bed_crossfade_s
		pitch_jitter = bed_pitch_jitter
		a.bus = &"Master"
		b.bus = &"Master"
		_set_volume(a, SILENCE_DB)
		_set_volume(b, SILENCE_DB)

	func start() -> void:
		active = true
		releasing = false
		xfading = false
		xfade_t = 0.0
		lag_primed = false
		lead_is_a = true
		b.stop()
		_set_volume(b, SILENCE_DB)
		# First bed start: soft attack from 0 (keep the opening).
		_play_on(a, 0.0)
		attacking = true
		attack_t = 0.0
		_set_volume(a, SILENCE_DB)

	func stop() -> void:
		if not active and not a.playing and not b.playing:
			return
		active = false
		xfading = false
		lag_primed = false
		attacking = false
		releasing = true
		release_t = 0.0

	func update(delta: float) -> void:
		if releasing:
			_update_release(delta)
			return
		if not active:
			return
		var lead := a if lead_is_a else b
		var lag := b if lead_is_a else a
		if attacking:
			attack_t = minf(1.0, attack_t + delta / maxf(ATTACK_S, 0.05))
			# Ease-in attack so the first hit isn't a slap.
			var ease := attack_t * attack_t
			_set_linear_volume(lead, db_to_linear(volume_db) * ease)
			if attack_t >= 1.0:
				attacking = false
				_set_volume(lead, volume_db)
		if xfading:
			xfade_t = minf(1.0, xfade_t + delta / maxf(xfade_dur, 0.05))
			var peak := db_to_linear(volume_db)
			var t := xfade_t
			# Lead fades out normally; lag eases in late (pow) so its entry
			# stays quiet until the outgoing bed has already dropped.
			var lead_g := cos(t * PI * 0.5)
			var lag_g := sin(pow(t, 2.2) * PI * 0.5)
			_set_linear_volume(lead, peak * lead_g)
			_set_linear_volume(lag, peak * lag_g)
			if xfade_t >= 1.0:
				lead.stop()
				_set_volume(lead, SILENCE_DB)
				_set_volume(lag, volume_db)
				lead_is_a = not lead_is_a
				xfading = false
				lag_primed = false
			return
		if not lead.playing:
			_play_on(lead, 0.0)
			_set_volume(lead, volume_db)
			lag_primed = false
			return
		var length := 0.0
		if lead.stream != null:
			length = lead.stream.get_length()
		if length <= 0.4:
			return
		# Scale windows to clip length so short mining (~3s) still crossfades.
		var xfade := maxf(0.45, minf(crossfade_s, length * 0.42))
		var preroll := minf(PREROLL_S, length * 0.14)
		var skip := minf(SKIP_ATTACK_S, length * 0.18)
		var pos := lead.get_playback_position()
		if not lag_primed and pos >= length - xfade - preroll:
			_play_on(lag, skip)
			_set_volume(lag, SILENCE_DB)
			lag_primed = true
		if lag_primed and not xfading and pos >= length - xfade:
			xfade_dur = xfade
			xfading = true
			xfade_t = 0.0

	func _update_release(delta: float) -> void:
		release_t = minf(1.0, release_t + delta / maxf(RELEASE_S, 0.05))
		var peak := db_to_linear(volume_db)
		var gain := 1.0 - release_t
		gain *= gain
		if a.playing:
			_set_linear_volume(a, peak * gain)
		if b.playing:
			_set_linear_volume(b, peak * gain)
		if release_t >= 1.0:
			a.stop()
			b.stop()
			_set_volume(a, SILENCE_DB)
			_set_volume(b, SILENCE_DB)
			releasing = false

	func _play_on(player: AudioStreamPlayer, from_s: float) -> void:
		var stream := _pick_stream()
		if stream == null:
			push_warning("Drill CrossfadeBed: stream is null")
			return
		player.stream = stream
		player.pitch_scale = (
			randf_range(1.0 - pitch_jitter, 1.0 + pitch_jitter)
			if pitch_jitter > 0.0
			else 1.0
		)
		var length := stream.get_length()
		var start_at := from_s
		if length > 0.0:
			start_at = clampf(from_s, 0.0, maxf(0.0, length - 0.05))
		player.play(start_at)

	func _pick_stream() -> AudioStream:
		if streams.is_empty():
			return null
		var i := randi() % streams.size()
		if streams.size() > 1 and i == last_stream_i:
			i = (i + 1) % streams.size()
		last_stream_i = i
		return streams[i]

	func _set_volume(player: AudioStreamPlayer, db: float) -> void:
		player.volume_db = db

	func _set_linear_volume(player: AudioStreamPlayer, linear: float) -> void:
		player.volume_db = linear_to_db(maxf(0.0001, linear))


@export var head_path: NodePath = NodePath("../Camera")
@export var query_path: NodePath = NodePath("../InteractionQuery")
@export var tool_controller_path: NodePath = NodePath("../ToolController")
@export var drill_visual_path: NodePath = NodePath("../Camera/DrillVisual")
@export var welder_visual_path: NodePath = NodePath("../Camera/WelderVisual")
@export var drill_bit_path: NodePath = NodePath(
	"ShakePivot/Mount/Model/Sketchfab_model/Drill_Low_fbx/RootNode/Body_Low/Cone"
)
@export var impact_vfx_path: NodePath = NodePath("../Camera/ImpactVfx")
@export var mine_audio_a_path: NodePath = NodePath("DrillMineAudioA")
@export var mine_audio_b_path: NodePath = NodePath("DrillMineAudioB")
@export var debris_audio_a_path: NodePath = NodePath("DrillDebrisAudioA")
@export var debris_audio_b_path: NodePath = NodePath("DrillDebrisAudioB")
@export var drill_spin_speed := 28.0
## Local offset under Camera. Double-precision Godot keeps this stable at ~9.5 km.
@export var rest_offset := Vector3(0.28, -0.22, -0.45)
## Mild screen shake while contacting.
@export var mining_camera_shake := 0.28
## Separate hand-drill buzz while contacting (along bit axis).
@export var mining_drill_shake := 0.85
@export var drill_shake_lateral_m := 0.008
@export var drill_shake_forward_m := 0.02
@export var drill_shake_roll_deg := 1.2
@export var work_volume_db := -16.0
@export var work_mining_volume_db := -28.0
@export var work_duck_s := 0.35
@export var mine_volume_db := -4.0
@export var debris_volume_db := -2.0
@export var mine_crossfade_s := 1.5
@export var debris_crossfade_s := 1.6
@export var mine_pitch_jitter := 0.0

var _head: Camera3D
var _query: InteractionQuery
var _tool_controller: ToolController
var _drill_visual: Node3D
var _shake_pivot: Node3D
var _welder_visual: Node3D
var _drill_bit: Node3D
var _impact_vfx: DrillImpactVfx
var _work_audio: AudioStreamPlayer
var _mine_bed := CrossfadeBed.new()
var _debris_bed := CrossfadeBed.new()
var _spinning := false
var _contacting := false
var _bit_rest_local := Transform3D.IDENTITY
var _bit_spin := 0.0
var _hold_lmb := false
var _work_volume_current_db := -16.0
var _drill_shake_amp := 0.0
var _fp_visuals_allowed := true


func _ready() -> void:
	_head = get_node(head_path)
	_query = get_node(query_path)
	_tool_controller = get_node(tool_controller_path)
	_drill_visual = get_node(drill_visual_path)
	_welder_visual = get_node_or_null(welder_visual_path)
	_impact_vfx = get_node(impact_vfx_path)
	_bind_weapon_visuals_local()
	_drill_bit = _drill_visual.get_node(drill_bit_path)
	_bit_rest_local = _drill_bit.transform
	_setup_work_audio()
	var mine_streams: Array[AudioStream] = [
		load("res://resources/audio/drill_mining_1.wav") as AudioStream,
		load("res://resources/audio/drill_mining_2.wav") as AudioStream,
	]
	var debris_streams: Array[AudioStream] = [
		load("res://resources/audio/drill_rock_debris.wav") as AudioStream,
	]
	_mine_bed.setup(
		get_node(mine_audio_a_path) as AudioStreamPlayer,
		get_node(mine_audio_b_path) as AudioStreamPlayer,
		mine_streams,
		mine_volume_db,
		mine_crossfade_s,
		mine_pitch_jitter
	)
	_debris_bed.setup(
		get_node(debris_audio_a_path) as AudioStreamPlayer,
		get_node(debris_audio_b_path) as AudioStreamPlayer,
		debris_streams,
		debris_volume_db,
		debris_crossfade_s,
		0.0
	)
	_tool_controller.active_tool_changed.connect(_on_active_tool_changed)
	_on_active_tool_changed(_tool_controller.active_tool)
	_impact_vfx.set_active(false)
	# Idle audio must keep ticking even if something disables physics on Drill.
	set_process(true)
	set_physics_process(true)
	# Scene leftover player — force mute so it cannot steal/conflict.
	var legacy_idle := get_node_or_null("DrillIdleAudio") as AudioStreamPlayer
	if legacy_idle != null:
		legacy_idle.stop()
		legacy_idle.volume_db = -80.0
		legacy_idle.stream = null


func _physics_process(_delta: float) -> void:
	if _tool_controller == null or _query == null:
		return
	if _tool_controller.active_tool == &"weld":
		_clear_drill_feedback()
		return
	if _tool_controller.active_tool != &"drill":
		_clear_drill_feedback()
		return
	var aim: Transform3D = _head.call("aim_transform")
	var direction := -aim.basis.z.normalized()
	var reach := IndustryArchetypeProfile.hand_drill_reach_m()
	var hit: InteractionHit = _query.current_hit
	var has_hit := (
		hit.valid
		and hit.distance <= reach
		and (
			hit.target_kind == InteractionHit.KIND_VOXEL
			or hit.target_kind == InteractionHit.KIND_SIMULATION_ELEMENT
		)
	)
	_set_contacting(_hold_lmb and has_hit)
	if _contacting:
		var contact := hit.point
		_impact_vfx.global_position = contact
		var up := GravityField.resolve_up(_impact_vfx, contact)
		if absf(direction.dot(up)) > 0.99:
			up = _head.global_transform.basis.x
		_impact_vfx.look_at(contact + direction, up)
	_sync_camera_shake()


func _process(delta: float) -> void:
	_hold_lmb = _compute_hold_lmb()
	var was_spinning := _spinning
	_set_spinning(_hold_lmb)
	if _spinning:
		_bit_spin = fposmod(_bit_spin + drill_spin_speed * delta, TAU)
		_apply_bit_spin()
	elif was_spinning:
		_apply_bit_spin()
	_sync_work_audio(delta)
	_mine_bed.update(delta)
	_debris_bed.update(delta)
	_sync_camera_shake()
	_update_drill_shake(delta)


func _compute_hold_lmb() -> bool:
	if _tool_controller == null:
		return false
	if _tool_controller.active_tool != &"drill":
		return false
	if not _gameplay_input_enabled():
		return false
	return (
		Input.is_action_pressed(&"tool_primary")
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	)


func _bind_weapon_visuals_local() -> void:
	## Camera child under double-precision Godot (viewmodel SubViewport removed).
	_drill_visual.top_level = false
	_drill_visual.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_drill_visual.transform = Transform3D(Basis.IDENTITY, rest_offset)
	_shake_pivot = _drill_visual.get_node("ShakePivot") as Node3D
	_shake_pivot.transform = Transform3D.IDENTITY
	if _welder_visual != null:
		_welder_visual.top_level = false
		_welder_visual.physics_interpolation_mode = (
			Node.PHYSICS_INTERPOLATION_MODE_OFF
		)
		_welder_visual.transform = Transform3D(Basis.IDENTITY, rest_offset)
	if _impact_vfx != null:
		_impact_vfx.top_level = true
		_impact_vfx.physics_interpolation_mode = (
			Node.PHYSICS_INTERPOLATION_MODE_OFF
		)


func set_first_person_visuals_visible(visible: bool) -> void:
	_fp_visuals_allowed = visible
	## Seat: stop drill _process (audio/spin) — was still running in cockpit.
	set_process(visible)
	if not visible:
		if _drill_visual != null:
			_drill_visual.visible = false
		if _welder_visual != null:
			_welder_visual.visible = false
		_clear_drill_feedback()
		return
	if _tool_controller != null:
		_on_active_tool_changed(_tool_controller.active_tool)


func _on_active_tool_changed(active_tool: StringName) -> void:
	if not _fp_visuals_allowed:
		if _drill_visual != null:
			_drill_visual.visible = false
		if _welder_visual != null:
			_welder_visual.visible = false
		_clear_drill_feedback()
		return
	_drill_visual.visible = active_tool == &"drill"
	if _welder_visual != null:
		_welder_visual.visible = active_tool == &"weld"
	if active_tool != &"drill":
		_clear_drill_feedback()


func _clear_drill_feedback() -> void:
	_set_spinning(false)
	_set_contacting(false)
	_drill_shake_amp = 0.0
	_sync_camera_shake()
	_apply_shake_pivot(0.0)


func _sync_camera_shake() -> void:
	if _head == null or not _head.has_method("set_camera_shake_hold"):
		return
	_head.call(
		"set_camera_shake_hold",
		mining_camera_shake if _contacting else 0.0
	)


func _update_drill_shake(delta: float) -> void:
	if not _contacting:
		if _drill_shake_amp != 0.0:
			_drill_shake_amp = 0.0
			_apply_shake_pivot(0.0)
		return
	var step := clampf(delta / 0.1, 0.0, 1.0)
	_drill_shake_amp = lerpf(_drill_shake_amp, mining_drill_shake, step)
	_apply_shake_pivot(_drill_shake_amp)


func _apply_shake_pivot(amp: float) -> void:
	if _shake_pivot == null:
		return
	if amp <= 0.001:
		_shake_pivot.transform = Transform3D.IDENTITY
		return
	var t := Time.get_ticks_msec() * 0.001
	var ox := (
		(sin(t * 97.0) * 0.55 + sin(t * 173.0) * 0.45)
		* drill_shake_lateral_m
		* amp
	)
	var oy := (
		(cos(t * 113.0) * 0.5 + sin(t * 151.0) * 0.5)
		* drill_shake_lateral_m
		* amp
	)
	var oz := (
		(sin(t * 131.0) * 0.65 + cos(t * 199.0) * 0.35)
		* drill_shake_forward_m
		* amp
	)
	var roll := sin(t * 167.0) * deg_to_rad(drill_shake_roll_deg) * amp
	var yaw := cos(t * 139.0) * deg_to_rad(drill_shake_roll_deg * 0.45) * amp
	var basis := (
		Basis(Vector3.UP, yaw) * Basis(Vector3.FORWARD, roll)
	).orthonormalized()
	_shake_pivot.transform = Transform3D(basis, Vector3(ox, oy, -oz))


func _gameplay_input_enabled() -> bool:
	var player := get_parent()
	if player != null and player.has_method("is_gameplay_input_enabled"):
		return bool(player.call("is_gameplay_input_enabled"))
	return true


func _setup_work_audio() -> void:
	if _work_audio != null and is_instance_valid(_work_audio):
		return
	_work_audio = AudioStreamPlayer.new()
	_work_audio.name = "DrillIdleRuntime"
	_work_audio.bus = &"Master"
	_work_audio.volume_db = work_volume_db
	_work_audio.process_mode = Node.PROCESS_MODE_ALWAYS
	var stream := _load_wav_pcm("res://resources/audio/drill_idle.wav")
	if stream == null:
		stream = _load_wav_pcm("res://resources/drill_loop.wav")
	if stream == null:
		push_error("Drill: failed to decode idle WAV from disk")
		_work_audio.queue_free()
		_work_audio = null
		return
	_work_audio.stream = stream
	if not _work_audio.finished.is_connected(_on_work_audio_finished):
		_work_audio.finished.connect(_on_work_audio_finished)
	# _ready() cannot add_child while parent is still setting up children.
	add_child.call_deferred(_work_audio)


func _load_wav_pcm(res_path: String) -> AudioStreamWAV:
	## Decode WAV bytes ourselves — Godot .sample import can report length but play silence.
	if not FileAccess.file_exists(res_path):
		return null
	var file := FileAccess.open(res_path, FileAccess.READ)
	if file == null:
		return null
	var bytes := file.get_buffer(file.get_length())
	file.close()
	if bytes.size() < 44:
		return null
	if bytes[0] != 0x52 or bytes[1] != 0x49 or bytes[2] != 0x46 or bytes[3] != 0x46:
		return null
	var offset := 12
	var channels := 1
	var rate := 44100
	var bits := 16
	var audio := PackedByteArray()
	while offset + 8 <= bytes.size():
		var chunk_id := (
			String.chr(bytes[offset])
			+ String.chr(bytes[offset + 1])
			+ String.chr(bytes[offset + 2])
			+ String.chr(bytes[offset + 3])
		)
		var chunk_size: int = (
			bytes[offset + 4]
			| (bytes[offset + 5] << 8)
			| (bytes[offset + 6] << 16)
			| (bytes[offset + 7] << 24)
		)
		offset += 8
		if offset + chunk_size > bytes.size():
			break
		if chunk_id == "fmt ":
			var audio_format: int = bytes[offset] | (bytes[offset + 1] << 8)
			channels = bytes[offset + 2] | (bytes[offset + 3] << 8)
			rate = (
				bytes[offset + 4]
				| (bytes[offset + 5] << 8)
				| (bytes[offset + 6] << 16)
				| (bytes[offset + 7] << 24)
			)
			bits = bytes[offset + 14] | (bytes[offset + 15] << 8)
			if audio_format != 1:
				push_error("Drill: idle WAV is not PCM (format=%d)" % audio_format)
				return null
		elif chunk_id == "data":
			audio = bytes.slice(offset, offset + chunk_size)
		offset += chunk_size + (chunk_size & 1)
	if audio.is_empty():
		return null
	if bits == 24:
		var frames := int(audio.size() / (3 * channels))
		var pcm16 := PackedByteArray()
		pcm16.resize(frames * channels * 2)
		var oi := 0
		for fi in frames:
			for ch in channels:
				var i := (fi * channels + ch) * 3
				var v: int = audio[i] | (audio[i + 1] << 8) | (audio[i + 2] << 16)
				if v & 0x800000:
					v -= 0x1000000
				var s16: int = clampi(v >> 8, -32768, 32767)
				pcm16[oi] = s16 & 0xFF
				pcm16[oi + 1] = (s16 >> 8) & 0xFF
				oi += 2
		audio = pcm16
		bits = 16
	elif bits != 16:
		push_error("Drill: unsupported WAV bit depth %d" % bits)
		return null
	var frame_count := int(audio.size() / (2 * channels))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = channels > 1
	stream.data = audio
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = maxi(frame_count - 1, 0)
	return stream


func _on_work_audio_finished() -> void:
	if _spinning and _work_audio != null:
		_work_audio.play()


func _sync_work_audio(delta: float) -> void:
	if _work_audio == null or not is_instance_valid(_work_audio):
		_setup_work_audio()
	if _work_audio == null or _work_audio.stream == null:
		return
	# Wait until deferred add_child finishes.
	if not _work_audio.is_inside_tree():
		return
	var target_db := (
		work_mining_volume_db if _contacting else work_volume_db
	)
	var duck_speed := absf(work_volume_db - work_mining_volume_db) / maxf(work_duck_s, 0.05)
	_work_volume_current_db = move_toward(
		_work_volume_current_db,
		target_db,
		duck_speed * delta
	)
	_work_audio.volume_db = _work_volume_current_db
	if _spinning:
		if not _work_audio.playing:
			_work_volume_current_db = target_db
			_work_audio.volume_db = _work_volume_current_db
			_work_audio.play()
	elif _work_audio.playing:
		_work_audio.stop()


func _set_spinning(active: bool) -> void:
	if _spinning == active:
		return
	_spinning = active
	if not active:
		_bit_spin = 0.0
		_apply_bit_spin()


func _apply_bit_spin() -> void:
	if _drill_bit == null:
		return
	_drill_bit.transform = _bit_rest_local * Transform3D(
		Basis(Vector3.UP, _bit_spin),
		Vector3.ZERO
	)


func _set_contacting(active: bool) -> void:
	if _contacting == active:
		return
	_contacting = active
	_impact_vfx.set_active(active)
	if active:
		_mine_bed.volume_db = mine_volume_db
		_mine_bed.crossfade_s = mine_crossfade_s
		_debris_bed.volume_db = debris_volume_db
		_debris_bed.crossfade_s = debris_crossfade_s
		_mine_bed.start()
		_debris_bed.start()
	else:
		_mine_bed.stop()
		_debris_bed.stop()
