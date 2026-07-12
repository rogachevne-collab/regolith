class_name Slice01Archetypes
extends RefCounted

const ARCHETYPE_DIR := "res://resources/archetypes/slice01/"
const REQUIRED_IDS: PackedStringArray = [
	"foundation",
	"frame",
	"frame_beam",
	"power_source",
	"stationary_drill",
	"cargo_store",
	"processor",
	"fabricator",
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


static func frame_beam() -> ElementArchetype:
	return load_required("frame_beam")


static func power_source() -> ElementArchetype:
	return load_required("power_source")


static func stationary_drill() -> ElementArchetype:
	return load_required("stationary_drill")


static func cargo_store() -> ElementArchetype:
	return load_required("cargo_store")


static func processor() -> ElementArchetype:
	return load_required("processor")


static func fabricator() -> ElementArchetype:
	return load_required("fabricator")
