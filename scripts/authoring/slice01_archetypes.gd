class_name Slice01Archetypes
extends RefCounted

const ARCHETYPE_DIR := "res://resources/archetypes/slice01/"
## Parts baked by the Part Wizard land here and are picked up automatically —
## no lists to edit by hand.
const AUTHORED_DIR := "res://resources/archetypes/authored/"
const ROVER_IDS: PackedStringArray = [
	"rover_frame",
	"cockpit",
	"control_terminal",
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
		path = "%s%s.tres" % [AUTHORED_DIR, archetype_id]
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


## Every wizard-baked part id, sorted. Internal archetypes (piston heads
## etc.) never land in AUTHORED_DIR, so no filtering is needed here.
static func authored_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	var dir := DirAccess.open(AUTHORED_DIR)
	if dir == null:
		return ids
	for file: String in dir.get_files():
		# In exported builds text resources may appear as .tres.remap.
		var name := file.trim_suffix(".remap")
		if name.get_extension() != "tres":
			continue
		ids.append(name.get_basename())
	ids.sort()
	return ids


## Пара «подвеска + колесо», испечённая визардом. Пусто, если в AUTHORED_DIR
## нет хотя бы одной из них. При нескольких берётся первая по алфавиту —
## порядок детерминированный, а точный выбор задаётся id в RoverIntent.
static func authored_wheel_pair() -> Dictionary:
	var wheel_id := ""
	var suspension_id := ""
	for archetype_id: String in authored_ids():
		var archetype: ElementArchetype = load_required(archetype_id)
		if archetype == null:
			continue
		if wheel_id.is_empty() and archetype.is_wheel():
			wheel_id = archetype_id
		if suspension_id.is_empty() and archetype.is_suspension():
			suspension_id = archetype_id
	if wheel_id.is_empty() or suspension_id.is_empty():
		return {}
	return {"wheel": wheel_id, "suspension": suspension_id}


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


## Просвет под днищем ровера: ход подвески + радиус колеса той пары, которую
## реально ставит композер. Пары нет — просвета не требуем, спавн просто сядет
## на грунт.
static func rover_wheel_clearance_m() -> float:
	var pair := authored_wheel_pair()
	if pair.is_empty():
		return 0.0
	var suspension := load_required(str(pair["suspension"]))
	var wheel := load_required(str(pair["wheel"]))
	if (
		suspension == null
		or wheel == null
		or suspension.suspension_definition == null
		or wheel.wheel_definition == null
	):
		return 0.0
	return (
		suspension.suspension_definition.suspension_travel_m
		+ wheel.wheel_definition.radius_m
	)


static func cockpit() -> ElementArchetype:
	return load_required("cockpit")


static func control_terminal() -> ElementArchetype:
	return load_required("control_terminal")


static func power_battery_small() -> ElementArchetype:
	return load_required("power_battery_small")


static func power_distributor_small() -> ElementArchetype:
	return load_required("power_distributor_small")
