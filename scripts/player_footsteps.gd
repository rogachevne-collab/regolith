extends Node

## Ground gravel footsteps for the player CharacterBody3D.

@export var player_path: NodePath = NodePath("..")
@export var audio_path: NodePath = NodePath("FootstepAudio")
@export var walk_interval_s := 0.42
@export var sprint_interval_s := 0.30
@export var min_speed_mps := 0.7
@export var volume_db := -8.0

var _player: CharacterBody3D
var _audio: AudioStreamPlayer
var _cooldown := 0.0


func _ready() -> void:
	_player = get_node(player_path) as CharacterBody3D
	_audio = get_node(audio_path) as AudioStreamPlayer
	_audio.volume_db = volume_db


func _physics_process(delta: float) -> void:
	if _player == null or _audio == null:
		return
	_cooldown = maxf(0.0, _cooldown - delta)
	if not _should_step():
		return
	if _cooldown > 0.0:
		return
	_audio.play()
	var sprinting := (
		_player.has_method("is_gameplay_input_enabled")
		and bool(_player.call("is_gameplay_input_enabled"))
		and Input.is_action_pressed(&"sprint")
	)
	_cooldown = sprint_interval_s if sprinting else walk_interval_s


func _should_step() -> bool:
	if _player.has_method("is_in_vehicle") and bool(_player.call("is_in_vehicle")):
		return false
	if _player.has_method("is_fly_mode") and bool(_player.call("is_fly_mode")):
		return false
	if _player.has_method("is_spawn_ready") and not bool(_player.call("is_spawn_ready")):
		return false
	if not _player.is_on_floor():
		return false
	var up := _player.up_direction
	if up.length_squared() < 0.0001:
		up = Vector3.UP
	var horizontal := _player.velocity - up * _player.velocity.dot(up)
	return horizontal.length() >= min_speed_mps
