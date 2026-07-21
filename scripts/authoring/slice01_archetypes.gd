class_name Slice01Archetypes
extends RefCounted

const ARCHETYPE_DIR := "res://resources/archetypes/slice01/"
const ROVER_IDS: PackedStringArray = [
	"rover_frame",
	"wheel_suspension",
	"drive_wheel",
	"cockpit",
	"power_battery_small",
	"power_distributor_small",
]
const FLIGHT_IDS: PackedStringArray = [
	"thruster",
	"gyro",
	"landing_leg",
]
const REQUIRED_IDS: PackedStringArray = [
	"foundation",
	"frame",
	"large_frame",
	"frame_beam",
	"frame_basalt",
	"power_source",
	"power_distributor",
	"power_battery",
	"stationary_drill",
	"dozer_blade",
	"cargo_store",
	"cargo_pipe",
	"processor",
	"fabricator",
	"electrolyzer",
]


static func load_required(archetype_id: String) -> ElementArchetype:
	var path := "%s%s.tres" % [ARCHETYPE_DIR, archetype_id]
	if not ResourceLoader.exists(path):
		push_error(
			"Required Slice-01 archetype asset is missing: %s" % path
		)
		return null
	var resource: Resource = ResourceLoader.load(path)
	var archetype := resource as ElementArchetype
	if archetype == null:
		push_error(
			"Slice-01 archetype asset has wrong type; expected "
			+ "ElementArchetype: %s" % path
		)
		return null
	if archetype.archetype_id != archetype_id:
		push_error(
			"Slice-01 archetype_id mismatch at %s: expected '%s', got '%s'"
			% [path, archetype_id, archetype.archetype_id]
		)
		return null
	GameBalance.apply_element(archetype)
	return archetype


static func load_all_required() -> Array[ElementArchetype]:
	var archetypes: Array[ElementArchetype] = []
	for archetype_id: String in REQUIRED_IDS:
		var archetype: ElementArchetype = load_required(archetype_id)
		if archetype == null:
			return []
		archetypes.append(archetype)
	return archetypes


static func foundation() -> ElementArchetype:
	return load_required("foundation")


static func frame() -> ElementArchetype:
	return load_required("frame")


static func large_frame() -> ElementArchetype:
	return load_required("large_frame")


static func frame_beam() -> ElementArchetype:
	return load_required("frame_beam")


static func power_source() -> ElementArchetype:
	return load_required("power_source")


static func stationary_drill() -> ElementArchetype:
	return load_required("stationary_drill")


static func dozer_blade() -> ElementArchetype:
	return load_required("dozer_blade")


static func cargo_store() -> ElementArchetype:
	return load_required("cargo_store")


static func processor() -> ElementArchetype:
	return load_required("processor")


static func fabricator() -> ElementArchetype:
	return load_required("fabricator")


static func electrolyzer() -> ElementArchetype:
	return load_required("electrolyzer")


static func piston_base() -> ElementArchetype:
	return load_required("piston_base")


static func piston_head() -> ElementArchetype:
	return load_required("piston_head")


static func piston_base_large() -> ElementArchetype:
	return load_required("piston_base_large")


static func piston_head_large() -> ElementArchetype:
	return load_required("piston_head_large")


static func rotor_base() -> ElementArchetype:
	return load_required("rotor_base")


static func rotor_top() -> ElementArchetype:
	return load_required("rotor_top")


static func rotor_base_large() -> ElementArchetype:
	return load_required("rotor_base_large")


static func rotor_top_large() -> ElementArchetype:
	return load_required("rotor_top_large")


static func hinge_base() -> ElementArchetype:
	return load_required("hinge_base")


static func hinge_top() -> ElementArchetype:
	return load_required("hinge_top")


static func load_actuator_archetypes() -> Array[ElementArchetype]:
	var archetypes: Array[ElementArchetype] = []
	for archetype_id: String in [
		"piston_base",
		"piston_head",
		"piston_base_large",
		"piston_head_large",
		"rotor_base",
		"rotor_top",
		"rotor_base_large",
		"rotor_top_large",
		"hinge_base",
		"hinge_top",
	]:
		var archetype: ElementArchetype = load_required(archetype_id)
		if archetype == null:
			return []
		archetypes.append(archetype)
	return archetypes


static func load_rover_archetypes() -> Array[ElementArchetype]:
	var archetypes: Array[ElementArchetype] = []
	for archetype_id: String in ROVER_IDS:
		var archetype: ElementArchetype = load_required(archetype_id)
		if archetype == null:
			return []
		archetypes.append(archetype)
	return archetypes


static func load_flight_archetypes() -> Array[ElementArchetype]:
	var archetypes: Array[ElementArchetype] = []
	for archetype_id: String in FLIGHT_IDS:
		var archetype: ElementArchetype = load_required(archetype_id)
		if archetype == null:
			return []
		archetypes.append(archetype)
	return archetypes


static func thruster() -> ElementArchetype:
	return load_required("thruster")


static func gyro() -> ElementArchetype:
	return load_required("gyro")


static func landing_leg() -> ElementArchetype:
	return load_required("landing_leg")


static func rover_frame() -> ElementArchetype:
	return load_required("rover_frame")


static func wheel_suspension() -> ElementArchetype:
	return load_required("wheel_suspension")


static func drive_wheel() -> ElementArchetype:
	return load_required("drive_wheel")


static func cockpit() -> ElementArchetype:
	return load_required("cockpit")


static func power_battery_small() -> ElementArchetype:
	return load_required("power_battery_small")


static func power_distributor_small() -> ElementArchetype:
	return load_required("power_distributor_small")
