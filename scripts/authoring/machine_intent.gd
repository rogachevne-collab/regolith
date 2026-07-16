class_name MachineIntent
extends RefCounted

## Agent-facing machine/rig request. Fill from phrase; holes use defaults.

const SUPPORTED_RECIPES: Array[String] = ["drill_arm"]

var recipe: String = "drill_arm"
## short | normal | long — boom frame count on the hinge branch.
var reach: String = "short"
## Piston feed on the tip branch. Off by default: stock 30 kN yeets light arms.
var feed: bool = false
## Extra tip hinge (adds one driven hinge on the branch).
var wrist: bool = false


static func defaults() -> MachineIntent:
	return MachineIntent.new()


static func from_phrase(text: String) -> MachineIntent:
	var intent := MachineIntent.new()
	var raw := text.strip_edges().to_lower()
	if raw.is_empty():
		return intent
	if _has_any(raw, ["карусел", "carousel", "кран", "crane", "двер"]):
		intent.recipe = "unsupported"
	elif _has_any(raw, ["бур", "drill", "манипулятор", "стрел", "arm", "rig"]):
		intent.recipe = "drill_arm"
	if _has_any(raw, ["длинн", "long"]):
		intent.reach = "long"
	elif _has_any(raw, ["коротк", "short"]):
		intent.reach = "short"
	if _has_any(raw, ["подач", "feed", "поршень", "piston"]):
		intent.feed = true
	if _has_any(raw, ["запясть", "wrist"]):
		intent.wrist = true
	return intent


static func from_dict(data: Dictionary) -> MachineIntent:
	var intent := MachineIntent.new()
	if data.is_empty():
		return intent
	intent.recipe = str(data.get("recipe", intent.recipe))
	intent.reach = str(data.get("reach", intent.reach))
	intent.feed = bool(data.get("feed", intent.feed))
	intent.wrist = bool(data.get("wrist", intent.wrist))
	return intent


func unsupported_reason() -> String:
	if recipe not in SUPPORTED_RECIPES:
		return "unsupported_recipe"
	if reach not in ["short", "normal", "long"]:
		return "bad_reach"
	return ""


func boom_frame_count() -> int:
	match reach:
		"short":
			return 0
		"long":
			return 2
		_:
			return 1


func expected_hinge_count() -> int:
	return 2 if wrist else 1


func expected_driven_count() -> int:
	var count := 2  # rotor + boom hinge
	if feed:
		count += 1
	if wrist:
		count += 1
	return count


func to_dict() -> Dictionary:
	return {
		"recipe": recipe,
		"reach": reach,
		"feed": feed,
		"wrist": wrist,
	}


static func _has_any(text: String, needles: Array) -> bool:
	for needle: Variant in needles:
		if text.find(str(needle)) >= 0:
			return true
	return false
