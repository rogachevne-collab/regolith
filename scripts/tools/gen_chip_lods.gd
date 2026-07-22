extends SceneTree
## Rebuild the chip boulder meshes with a decimated base and LODs below it.
##
## The chips are drawn by `GranularGrainShell` as MultiMesh instances of these
## meshes. MultiMesh picks a mesh LOD by the whole cloud's AABB, so a distance
## LOD barely fires while a heap is in front of you — the chips stay at LOD0
## however small each stone is on screen. To draw them cheaper by default the
## *base* mesh has to be the lower-poly one.
##
## So this takes the first generated LOD (meshoptimizer's LOD1) as the new base
## geometry and regenerates coarser LODs beneath it. The chips now cost about
## an `BASE_LOD`-level stone everywhere, and POM on the surface carries the
## density the full-poly silhouette used to.
##
## Run headless, from the committed (full-poly) meshes:
##   git checkout -- resources/props/lunar_boulder_mesh_small_*.tres
##   godot --headless --path Y:/regolith --script res://scripts/tools/gen_chip_lods.gd
## NOT idempotent against its own output — always start from the git originals,
## or each run decimates the previous base again.

const MESHES := [
	"res://resources/props/lunar_boulder_mesh_small_0.tres",
	"res://resources/props/lunar_boulder_mesh_small_1.tres",
	"res://resources/props/lunar_boulder_mesh_small_2.tres",
]
## Which generated LOD to promote to the base. 0 is meshopt's first (lightest
## still-faithful) reduction — "LOD1" in the usual naming.
const BASE_LOD := 0
## Degrees; welds near-coplanar normals before decimating so a chunky facet is
## not torn into slivers. The authored chips are chunky, so a generous weld is
## safe.
const NORMAL_MERGE_ANGLE := 25.0


func _init() -> void:
	for path in MESHES:
		_bake(path)
	quit(0)


func _bake(path: String) -> void:
	var src := load(path) as ArrayMesh
	if src == null:
		push_error("not an ArrayMesh: %s" % path)
		return
	if src.get_surface_count() != 1:
		push_error("expected one surface in %s, got %d" % [path, src.get_surface_count()])
		return
	var arrays := src.surface_get_arrays(0)
	var primitive := src.surface_get_primitive_type(0)
	var material := src.surface_get_material(0)
	var before := src.surface_get_array_index_len(0) / 3

	# First pass: generate LODs off the full-poly mesh to get the decimated
	# index buffer we want as the new base.
	var probe := ImporterMesh.new()
	probe.add_surface(primitive, arrays, [], {}, material)
	probe.generate_lods(NORMAL_MERGE_ANGLE, 0.0, [])
	if probe.get_surface_lod_count(0) <= BASE_LOD:
		push_warning("%s: only %d LODs, keeping full poly" % [path, probe.get_surface_lod_count(0)])
		ResourceSaver.save(src, path)
		return
	var base_indices := probe.get_surface_lod_indices(0, BASE_LOD)

	# The new base surface: the original vertex data, indexed by the decimated
	# LOD. (Unused vertices remain in the buffer — a handful per chip, no draw
	# cost beyond storage, and generate_lods reindexes what it needs.)
	var base_arrays := arrays.duplicate(true)
	base_arrays[Mesh.ARRAY_INDEX] = base_indices

	var out_mesh := ImporterMesh.new()
	out_mesh.add_surface(primitive, base_arrays, [], {}, material)
	out_mesh.generate_lods(NORMAL_MERGE_ANGLE, 0.0, [])
	var out := out_mesh.get_mesh()
	if out == null:
		push_error("rebuild produced no mesh for %s" % path)
		return
	var after := base_indices.size() / 3
	var err := ResourceSaver.save(out, path)
	if err != OK:
		push_error("save failed for %s: %d" % [path, err])
		return
	print(
		"chip base: %s — %d tris -> %d tris (LOD%d as base), sub-LODs generated"
		% [path.get_file(), before, after, BASE_LOD + 1]
	)
