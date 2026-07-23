class_name RoverIntent
extends RefCounted

## Agent-facing rover request. Fill from phrase; holes use defaults.
## Supported wheel_count: even 4..12 (колбаса = 12).

const SUPPORTED_WHEEL_COUNTS: Array[int] = [4, 6, 8, 10, 12]

var wheel_count: int = 4
## short | normal | long
var length: String = "normal"
## narrow | normal | wide
var width: String = "normal"
## low | normal | tall
var height: String = "normal"
## front | center
var cockpit: String = "front"
## rear | side
var power: String = "rear"
## Какую пару «подвеска + колесо» ставить. Дефолт — детали, испечённые
## визардом: сеточных колёс без точных точек крепления больше нет.
## Геометрию композер выводит из самих архетипов, а не из этих id.
var suspension_archetype_id: String = ""
var wheel_archetype_id: String = ""


func _init() -> void:
	use_authored_wheels()


static func defaults() -> RoverIntent:
	return RoverIntent.new()


static func from_phrase(text: String) -> RoverIntent:
	var intent := RoverIntent.new()
	var raw := text.strip_edges().to_lower()
	if raw.is_empty():
		return intent
	intent.wheel_count = _parse_wheel_count(raw)
	if _has_any(raw, ["колбас", "sausage"]):
		intent.length = "long"
	elif _has_any(raw, ["длинн", "long"]):
		intent.length = "long"
	elif _has_any(raw, ["коротк", "short"]):
		intent.length = "short"
	if _has_any(raw, ["широк", "wide"]):
		intent.width = "wide"
	elif _has_any(raw, ["узк", "narrow"]):
		intent.width = "narrow"
	if _has_any(raw, ["высок", "tall"]):
		intent.height = "tall"
	elif _has_any(raw, ["низк", "low"]):
		intent.height = "low"
	if _has_any(raw, ["центр", "center", "середи"]):
		intent.cockpit = "center"
	if _has_any(raw, ["сбоку", "side", "боков"]):
		intent.power = "side"
	return intent


## Поставить пару, испечённую визардом. Пары нет — id остаются пустыми и
## unsupported_reason() честно скажет «bad_wheel_archetype», вместо того чтобы
## молча собрать ровер без колёс.
func use_authored_wheels() -> bool:
	var pair := Slice01Archetypes.authored_wheel_pair()
	if pair.is_empty():
		return false
	suspension_archetype_id = str(pair["suspension"])
	wheel_archetype_id = str(pair["wheel"])
	return true


func suspension_archetype() -> ElementArchetype:
	return Slice01Archetypes.load_required(suspension_archetype_id)


func wheel_archetype() -> ElementArchetype:
	return Slice01Archetypes.load_required(wheel_archetype_id)


func unsupported_reason() -> String:
	if wheel_count not in SUPPORTED_WHEEL_COUNTS:
		return "unsupported_wheel_count"
	if length not in ["short", "normal", "long"]:
		return "bad_length"
	if width not in ["narrow", "normal", "wide"]:
		return "bad_width"
	if height not in ["low", "normal", "tall"]:
		return "bad_height"
	if cockpit not in ["front", "center"]:
		return "bad_cockpit"
	if power not in ["rear", "side"]:
		return "bad_power"
	var suspension := suspension_archetype()
	if suspension == null or not suspension.is_suspension():
		return "bad_suspension_archetype"
	var wheel := wheel_archetype()
	if wheel == null or not wheel.is_wheel():
		return "bad_wheel_archetype"
	return ""


func axle_count() -> int:
	return maxi(int(wheel_count / 2.0), 1)


func length_cells() -> int:
	var base := 5
	match length:
		"short":
			base = 4
		"long":
			base = 7
		_:
			base = 5
	var axles := axle_count()
	# One cell per axle minimum; long колбаса stretches for gaps.
	base = maxi(base, axles)
	if length == "long":
		base = maxi(base, axles * 2)
	elif wheel_count >= 10:
		base = maxi(base, axles + 2)
	if cockpit == "center":
		base = maxi(base, 6)
	# Room for distributor bay + battery rows behind cockpit.
	var battery_rows := ceili(float(battery_count()) / float(_batteries_per_row()))
	base = maxi(base, 4 + battery_rows * 2)
	return base


## Batteries so full drive demand fits battery discharge budget (all-or-nothing).
func battery_count() -> int:
	var draw_w := _wheel_drive_draw_w()
	var discharge_w := _battery_discharge_w()
	if draw_w <= 0.0 or discharge_w <= 0.0:
		return 1
	return maxi(ceili(float(wheel_count) * draw_w / discharge_w), 1)


func _batteries_per_row() -> int:
	# Each battery footprint is 2 cells wide.
	return maxi(int(width_cells_base() / 2.0), 1)


func width_cells_base() -> int:
	match width:
		"wide":
			return 6
		"narrow":
			return 4
		_:
			return 4


func width_cells() -> int:
	var base := width_cells_base()
	# Fit at least 2 batteries per row when budget needs many packs.
	var packs := battery_count()
	if packs >= 3:
		base = maxi(base, 6)
	return base


## Считаем по ТОМУ колесу, которое поставим: у авторского аппетит свой, и
## батарей под него нужно столько же своих.
func _wheel_drive_draw_w() -> float:
	var wheel := wheel_archetype()
	if wheel != null and wheel.wheel_definition != null:
		return maxf(wheel.wheel_definition.power_draw_w, 0.0)
	return 300.0


static func _battery_discharge_w() -> float:
	var discharge: Variant = IndustryElectricProfile.archetype_default(
		"power_battery_small",
		"discharge_w",
		IndustryElectricProfile.DEFAULT_BATTERY_DISCHARGE_W
	)
	return maxf(float(discharge), 0.0)


func module_y() -> int:
	return 2 if height == "tall" else 1


func needs_deck_stack() -> bool:
	return height == "tall"


func axle_z_cells() -> Array[int]:
	var axles := axle_count()
	var length_z := length_cells()
	var cells: Array[int] = []
	if axles <= 1:
		cells.append(0)
		return cells
	var used: Dictionary = {}
	for i: int in range(axles):
		var z := int(
			round(float(i) * float(length_z - 1) / float(axles - 1))
		)
		z = clampi(z, 0, length_z - 1)
		# Keep unique axle cells; nudge forward if collision.
		while used.has(z) and z < length_z - 1:
			z += 1
		while used.has(z) and z > 0:
			z -= 1
		used[z] = true
		cells.append(z)
	cells.sort()
	return cells


func to_dict() -> Dictionary:
	return {
		"wheel_count": wheel_count,
		"length": length,
		"width": width,
		"height": height,
		"cockpit": cockpit,
		"power": power,
		"suspension_archetype_id": suspension_archetype_id,
		"wheel_archetype_id": wheel_archetype_id,
	}


static func from_dict(data: Dictionary) -> RoverIntent:
	var intent := RoverIntent.new()
	if data.is_empty():
		return intent
	intent.wheel_count = int(data.get("wheel_count", 4))
	intent.length = str(data.get("length", "normal"))
	intent.width = str(data.get("width", "normal"))
	intent.height = str(data.get("height", "normal"))
	intent.cockpit = str(data.get("cockpit", "front"))
	intent.power = str(data.get("power", "rear"))
	intent.suspension_archetype_id = str(
		data.get("suspension_archetype_id", intent.suspension_archetype_id)
	)
	intent.wheel_archetype_id = str(
		data.get("wheel_archetype_id", intent.wheel_archetype_id)
	)
	return intent


static func _parse_wheel_count(raw: String) -> int:
	var regex := RegEx.new()
	regex.compile("(\\d+)\\s*(?:кол|wheel)")
	var matched := regex.search(raw)
	if matched != null:
		return int(matched.get_string(1))
	regex.compile("(?:кол[а-я]*|wheels?)\\s*(\\d+)")
	matched = regex.search(raw)
	if matched != null:
		return int(matched.get_string(1))
	if _has_any(raw, ["двенадцатикол", "12-wheel", "twelve wheel"]):
		return 12
	if _has_any(raw, ["шестикол", "6-wheel", "six wheel"]):
		return 6
	return 4


static func _has_any(raw: String, keys: Array) -> bool:
	for key: Variant in keys:
		if raw.find(str(key)) >= 0:
			return true
	return false
