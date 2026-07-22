extends WorldEnvironment

## Live console knobs for the shared lunar Environment + CameraAttributes.
##
## The look lives in resources/environment/*.tres; this node only lets you turn
## the dials while the game runs and then persist what your eye picked:
##
##   env_preset aces|agx|filmic|neutral   swap the whole tonemap/grade block
##   env_exposure 1.2                tonemap exposure
##   env_glow 1 0.2 2.0              enabled, intensity, hdr threshold
##   env_ssil 1 0.35                 regolith bounce into shadow (costly)
##   env_ssao 1 0.65
##   env_grade 1.05 1.08             contrast, saturation
##   env_ambient 0.42 0.7            energy, sky contribution
##   env_sun 1.55                    DayNightCycle key-light energy
##   env_autoexposure 1 0.35 0.5     enabled, speed, scale
##   env_dump                        print a .tres-ready diff-vs-default block
##   env_save                        write the live values back to the .tres
##   env_reload                      discard live edits, reload from disk
##
## `neutral` (linear tonemap, no grade, no glow) is the reference preset for
## judging raw albedo while authoring materials — not a shippable look.

## DayNightCycle drives sun + ambient every frame, so those two knobs have to
## write to it instead of to the Environment or they are stomped next tick.
@export_node_path("Node") var day_night_path: NodePath = ^"../DayNightCycle"

const _COMMANDS: Array[StringName] = [
	&"env_preset", &"env_exposure", &"env_glow", &"env_ssil", &"env_ssao",
	&"env_grade", &"env_ambient", &"env_sun", &"env_autoexposure",
	&"env_dump", &"env_save", &"env_reload",
]

var _day_night: Node


func _ready() -> void:
	_day_night = get_node_or_null(day_night_path)
	_register_console_commands()


func _exit_tree() -> void:
	if LimboConsole == null or not LimboConsole.has_method("unregister_command"):
		return
	for command in _COMMANDS:
		LimboConsole.unregister_command(String(command))


func _register_console_commands() -> void:
	if LimboConsole == null or not LimboConsole.has_method("register_command"):
		return
	LimboConsole.register_command(env_preset, "env_preset", "aces | agx | filmic | neutral")
	LimboConsole.register_command(env_exposure, "env_exposure", "tonemap exposure")
	LimboConsole.register_command(env_glow, "env_glow", "on [intensity] [hdr_threshold]")
	LimboConsole.register_command(env_ssil, "env_ssil", "on [intensity] - bounce light, costly")
	LimboConsole.register_command(env_ssao, "env_ssao", "on [intensity]")
	LimboConsole.register_command(env_grade, "env_grade", "[contrast] [saturation]")
	LimboConsole.register_command(env_ambient, "env_ambient", "[energy] [sky_contribution]")
	LimboConsole.register_command(env_sun, "env_sun", "key light energy")
	LimboConsole.register_command(env_autoexposure, "env_autoexposure", "on [speed] [scale]")
	LimboConsole.register_command(env_dump, "env_dump", "print live values as .tres text")
	LimboConsole.register_command(env_save, "env_save", "write live values into the .tres")
	LimboConsole.register_command(env_reload, "env_reload", "reload the .tres from disk")


func env_preset(preset: String) -> void:
	var env := environment
	if env == null:
		return
	match preset.to_lower():
		"aces":
			env.tonemap_mode = Environment.TONE_MAPPER_ACES
			env.tonemap_exposure = 1.0
			env.adjustment_enabled = true
			env.adjustment_contrast = 1.08
			env.adjustment_saturation = 1.05
			env.glow_enabled = true
		"agx":
			env.tonemap_mode = Environment.TONE_MAPPER_AGX
			env.tonemap_exposure = 1.15
			env.adjustment_enabled = true
			env.adjustment_contrast = 1.05
			env.adjustment_saturation = 1.08
			env.glow_enabled = true
		"filmic":
			env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
			env.tonemap_exposure = 0.92
			env.adjustment_enabled = false
			env.glow_enabled = true
		"neutral":
			env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			env.tonemap_exposure = 1.0
			env.adjustment_enabled = false
			env.glow_enabled = false
		_:
			_info("unknown preset '%s' (aces | agx | filmic | neutral)" % preset)
			return
	_info("preset %s" % preset.to_lower())


func env_exposure(value: float) -> void:
	if environment == null:
		return
	environment.tonemap_exposure = maxf(value, 0.0)
	_info("tonemap_exposure = %.3f" % environment.tonemap_exposure)


func env_glow(enabled: bool, intensity: float = -1.0, hdr_threshold: float = -1.0) -> void:
	var env := environment
	if env == null:
		return
	env.glow_enabled = enabled
	if intensity >= 0.0:
		env.glow_intensity = intensity
	if hdr_threshold >= 0.0:
		env.glow_hdr_threshold = hdr_threshold
	_info("glow %s  intensity=%.3f  threshold=%.3f" % [
		"on" if enabled else "off", env.glow_intensity, env.glow_hdr_threshold
	])


func env_ssil(enabled: bool, intensity: float = -1.0) -> void:
	var env := environment
	if env == null:
		return
	env.ssil_enabled = enabled
	if intensity >= 0.0:
		env.ssil_intensity = intensity
	_info("ssil %s  intensity=%.3f" % ["on" if enabled else "off", env.ssil_intensity])


func env_ssao(enabled: bool, intensity: float = -1.0) -> void:
	var env := environment
	if env == null:
		return
	env.ssao_enabled = enabled
	if intensity >= 0.0:
		env.ssao_intensity = intensity
	_info("ssao %s  intensity=%.3f" % ["on" if enabled else "off", env.ssao_intensity])


func env_grade(contrast: float = -1.0, saturation: float = -1.0) -> void:
	var env := environment
	if env == null:
		return
	env.adjustment_enabled = true
	if contrast >= 0.0:
		env.adjustment_contrast = contrast
	if saturation >= 0.0:
		env.adjustment_saturation = saturation
	_info("grade contrast=%.3f saturation=%.3f" % [
		env.adjustment_contrast, env.adjustment_saturation
	])


func env_ambient(energy: float = -1.0, sky_contribution: float = -1.0) -> void:
	var env := environment
	if env == null:
		return
	if sky_contribution >= 0.0:
		env.ambient_light_sky_contribution = clampf(sky_contribution, 0.0, 1.0)
	if energy >= 0.0:
		env.ambient_light_energy = energy
		# DayNightCycle rewrites ambient every frame; keep its targets in sync.
		if _day_night != null and is_instance_valid(_day_night):
			_day_night.set("day_ambient_energy", energy)
			_day_night.set("flat_day_ambient_energy", energy)
	_info("ambient energy=%.3f sky=%.3f" % [
		env.ambient_light_energy, env.ambient_light_sky_contribution
	])


func env_sun(energy: float) -> void:
	if _day_night == null or not is_instance_valid(_day_night):
		_info("no DayNightCycle at %s" % String(day_night_path))
		return
	_day_night.set("day_sun_energy", maxf(energy, 0.0))
	_info("day_sun_energy = %.3f" % energy)


func env_autoexposure(enabled: bool, speed: float = -1.0, scale: float = -1.0) -> void:
	var attrs := camera_attributes as CameraAttributesPractical
	if attrs == null:
		_info("no CameraAttributesPractical on this WorldEnvironment")
		return
	attrs.auto_exposure_enabled = enabled
	if speed >= 0.0:
		attrs.auto_exposure_speed = speed
	if scale >= 0.0:
		attrs.auto_exposure_scale = scale
	_info("auto exposure %s  speed=%.3f  scale=%.3f  sensitivity=%.0f..%.0f" % [
		"on" if enabled else "off", attrs.auto_exposure_speed, attrs.auto_exposure_scale,
		attrs.auto_exposure_min_sensitivity, attrs.auto_exposure_max_sensitivity
	])


func env_dump() -> void:
	_dump_resource(environment, "Environment")
	_dump_resource(camera_attributes, "CameraAttributes")


func env_save() -> void:
	_save_resource(environment)
	_save_resource(camera_attributes)


func env_reload() -> void:
	_reload_resource(environment)
	_reload_resource(camera_attributes)


## Print every property that differs from the class default, in .tres syntax.
func _dump_resource(res: Resource, header: String) -> void:
	if res == null:
		return
	var reference := ClassDB.instantiate(res.get_class()) as Resource
	if reference == null:
		return
	var lines: PackedStringArray = PackedStringArray()
	for prop: Dictionary in res.get_property_list():
		if (int(prop.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var prop_name := String(prop.get("name", ""))
		if prop_name in ["resource_local_to_scene", "resource_path", "resource_name", "script"]:
			continue
		var value: Variant = res.get(prop_name)
		# Sub-resources (sky, textures) are not worth round-tripping as text.
		if value is Object:
			continue
		if value == reference.get(prop_name):
			continue
		lines.append("%s = %s" % [prop_name, var_to_str(value)])
	_info("--- %s (%s) ---\n%s" % [header, res.resource_path, "\n".join(lines)])


func _save_resource(res: Resource) -> void:
	if res == null:
		return
	var path := res.resource_path
	if path.is_empty() or not path.begins_with("res://"):
		_info("not a project resource, nothing to save (inline sub-resource?)")
		return
	if not OS.has_feature("editor"):
		_info("res:// is read-only in an exported build; use env_dump instead")
		return
	var err := ResourceSaver.save(res, path)
	if err != OK:
		_info("save failed (%d): %s" % [err, path])
	else:
		_info("saved %s" % path)


func _reload_resource(res: Resource) -> void:
	if res == null or res.resource_path.is_empty():
		return
	var fresh := ResourceLoader.load(
		res.resource_path, "", ResourceLoader.CACHE_MODE_REPLACE
	)
	if fresh != null:
		_info("reloaded %s" % res.resource_path)


func _info(message: String) -> void:
	if LimboConsole != null and LimboConsole.has_method("info"):
		LimboConsole.info(message)
	else:
		print(message)
