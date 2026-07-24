class_name RemotePlayer
extends Node3D
## Visual stand-in for another player in COOP-HOST-V0 stage 3. No physics body:
## poses are host-authoritative and arrive with latency, so a CharacterBody
## would fight them; player-vs-player collision is not a stage-3 goal. Builds its
## own children in code so the scene file stays a bare Node3D.
##
## Renders ~120 ms in the past and interpolates between buffered poses, so a
## 20 Hz pose stream looks smooth. Extrapolates briefly on a dropped packet;
## hard-snaps on a long gap.

const INTERP_DELAY_MS := 120
const MAX_EXTRAP_MS := 250
const SNAP_GAP_MS := 1000
const SNAP_DIST := 20.0
const BUFFER_LIMIT := 16
const CAPSULE_RADIUS := 0.35
const CAPSULE_HEIGHT := 1.8

var _uid := ""
var _body: MeshInstance3D
var _nick_label: Label3D
var _head: Node3D
var _headlamp: SpotLight3D
var _tool_holder: Node3D
var _tool_id := StringName()
## Ring of {t:int, p:Vector3, q:Quaternion, qh:Quaternion, l:bool, v:Vector3,
## tool:StringName}.
var _samples: Array[Dictionary] = []


func _ready() -> void:
	set_meta("player_id", _uid)  # host impact predicate keys on this (future)
	_build_visuals()


func setup(uid: String, nick: String) -> void:
	_uid = uid
	if is_inside_tree():
		set_meta("player_id", _uid)
	set_nick(nick)


func set_nick(nick: String) -> void:
	if _nick_label != null:
		_nick_label.text = nick


## Pose dict from the network: {p, q, qh, l, v}. Stamped with local receive time
## for the interpolation clock.
func push_pose(pose: Dictionary) -> void:
	_samples.append({
		"t": Time.get_ticks_msec(),
		"p": pose.get("p", global_position),
		"q": pose.get("q", Quaternion.IDENTITY),
		"qh": pose.get("qh", pose.get("q", Quaternion.IDENTITY)),
		"l": bool(pose.get("l", false)),
		"v": pose.get("v", Vector3.ZERO),
		"tool": StringName(pose.get("tool", &"")),
	})
	while _samples.size() > BUFFER_LIMIT:
		_samples.pop_front()


func _process(_delta: float) -> void:
	if _samples.is_empty():
		return
	var render_t := Time.get_ticks_msec() - INTERP_DELAY_MS
	var newest: Dictionary = _samples[_samples.size() - 1]
	var oldest: Dictionary = _samples[0]
	# Discrete state: no point interpolating a tool swap, just show the latest.
	_set_tool(StringName(newest.get("tool", &"")))

	if render_t <= int(oldest["t"]):
		_apply(oldest["p"], oldest["q"], oldest["qh"], bool(oldest["l"]))
		return

	if render_t >= int(newest["t"]):
		_apply_extrapolated(newest, render_t)
		return

	for i in range(_samples.size() - 1):
		var a: Dictionary = _samples[i]
		var b: Dictionary = _samples[i + 1]
		var ta := int(a["t"])
		var tb := int(b["t"])
		if render_t < ta or render_t > tb:
			continue
		var span := maxf(float(tb - ta), 1.0)
		var f := clampf(float(render_t - ta) / span, 0.0, 1.0)
		var pa: Vector3 = a["p"]
		var pb: Vector3 = b["p"]
		if pa.distance_to(pb) > SNAP_DIST:
			_apply(pb, b["q"], b["qh"], bool(b["l"]))
			return
		_apply(
			pa.lerp(pb, f),
			(a["q"] as Quaternion).slerp(b["q"], f),
			(a["qh"] as Quaternion).slerp(b["qh"], f),
			bool(b["l"])
		)
		return


func _apply_extrapolated(sample: Dictionary, render_t: int) -> void:
	var gap := render_t - int(sample["t"])
	var base_pos: Vector3 = sample["p"]
	if gap > SNAP_GAP_MS:
		_apply(base_pos, sample["q"], sample["qh"], bool(sample["l"]))
		return
	var ahead := mini(gap, MAX_EXTRAP_MS)
	var predicted := base_pos + (sample["v"] as Vector3) * (float(ahead) / 1000.0)
	_apply(predicted, sample["q"], sample["qh"], bool(sample["l"]))


func _apply(
	pos: Vector3,
	body_q: Quaternion,
	head_q: Quaternion,
	lamp_on: bool
) -> void:
	# Root carries body orientation; Body/NickLabel/Head ride as local children,
	# so Head stays at eye height (its local +Y offset) and we only re-aim it.
	global_transform = Transform3D(Basis(body_q), pos)
	if _head != null:
		_head.global_basis = Basis(head_q)
	if _headlamp != null:
		_headlamp.visible = lamp_on


func _build_visuals() -> void:
	_body = MeshInstance3D.new()
	_body.name = "Body"
	var capsule := CapsuleMesh.new()
	capsule.radius = CAPSULE_RADIUS
	capsule.height = CAPSULE_HEIGHT
	_body.mesh = capsule
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.72, 0.78, 0.86, 1.0)
	_body.material_override = material
	add_child(_body)

	_nick_label = Label3D.new()
	_nick_label.name = "NickLabel"
	_nick_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_nick_label.no_depth_test = false
	_nick_label.fixed_size = false
	_nick_label.pixel_size = 0.006
	_nick_label.position = Vector3(0.0, 1.4, 0.0)
	_nick_label.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_nick_label.outline_size = 8
	add_child(_nick_label)

	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(0.0, 0.7, 0.0)
	add_child(_head)

	_headlamp = SpotLight3D.new()
	_headlamp.name = "Headlamp"
	_headlamp.light_color = Color(1.0, 0.93, 0.82, 1.0)
	_headlamp.light_energy = 3.2
	_headlamp.spot_range = 12.0
	_headlamp.spot_attenuation = 0.8
	_headlamp.spot_angle = 42.0
	_headlamp.visible = false
	# SpotLight3D points down its local -Z, same as the player Camera it mirrors.
	_head.add_child(_headlamp)

	# Child of Head, so the held tool tracks the synced look direction for free,
	# exactly like the headlamp. Offset puts it at the avatar's right hand.
	_tool_holder = Node3D.new()
	_tool_holder.name = "ToolHolder"
	_tool_holder.position = Vector3(0.28, -0.35, -0.3)
	_head.add_child(_tool_holder)


## Swap the visible held tool. Placeholder meshes in the same code-built style
## as the capsule body; unknown tool ids show empty hands.
func _set_tool(tool_id: StringName) -> void:
	if _tool_holder == null or tool_id == _tool_id:
		return
	_tool_id = tool_id
	for child: Node in _tool_holder.get_children():
		child.queue_free()
	if tool_id == &"drill":
		_tool_holder.add_child(_build_drill())


func _build_drill() -> Node3D:
	var drill := Node3D.new()
	drill.name = "Drill"

	var housing := MeshInstance3D.new()
	housing.name = "Housing"
	var housing_mesh := BoxMesh.new()
	housing_mesh.size = Vector3(0.12, 0.16, 0.34)
	housing.mesh = housing_mesh
	var housing_material := StandardMaterial3D.new()
	housing_material.albedo_color = Color(0.24, 0.26, 0.3, 1.0)
	housing.material_override = housing_material
	drill.add_child(housing)

	var bit := MeshInstance3D.new()
	bit.name = "Bit"
	var bit_mesh := CylinderMesh.new()
	bit_mesh.top_radius = 0.012
	bit_mesh.bottom_radius = 0.035
	bit_mesh.height = 0.45
	bit.mesh = bit_mesh
	# Cylinder axis is +Y; -90° about X sends +Y to -Z, so the tapered tip
	# points where the head looks (local -Z, same convention as the headlamp).
	bit.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	bit.position = Vector3(0.0, 0.0, -0.36)
	var bit_material := StandardMaterial3D.new()
	bit_material.albedo_color = Color(0.68, 0.62, 0.5, 1.0)
	bit_material.metallic = 0.7
	bit_material.roughness = 0.4
	bit.material_override = bit_material
	drill.add_child(bit)

	return drill
