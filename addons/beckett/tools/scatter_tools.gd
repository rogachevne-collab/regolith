@tool
extends RefCounted
class_name BeckettScatterTools

## Scatter authoring (L4, Full-only) — the scriptable analog of Godot 4.7's Scene Paint.
## Instance a scene (or duplicate a node) N times across a 2D/3D region with randomized
## position/rotation/scale, in ONE undoable action (Ctrl+Z removes the whole batch).
## Lets an agent fill a level with props/vegetation/enemies in a single call instead of
## hand-placing each node. Mirrors scene_tools' add_child + owner + EditorUndoRedoManager
## pattern so the scattered nodes persist on save and undo atomically.

const _MAX := 1000

var server


func _register(registry) -> void:
	registry.register({
		"name": "scatter_nodes",
		"description": "Scatter N copies of a scene or node across a region with random position/rotation/scale — the scriptable Scene Paint (fill a level with props/vegetation/enemies in one undoable call). 'source' = a res:// .tscn (instanced per copy) or a node path/name in the open scene (duplicated). 'count' copies go under 'parent' (default scene root). 'region' bounds positions: 2D = [x, y, w, h] (Node2D/Control), 3D = [x, y, z, w, h, d] (Node3D, min corner + size); omit to stack at the parent origin. 'rotation' = max random rotation in degrees (Z in 2D, around Y in 3D), 'scale_min'/'scale_max' = uniform random scale range (default 1.0), 'seed' = deterministic RNG. One undoable action (max 1000).",
		"destructive": true,
		"input_schema": {"type": "object", "properties": {
			"source": {"type": "string", "description": "res:// .tscn to instance, or a node path/name to duplicate"},
			"count": {"type": "integer"},
			"parent": {"type": "string", "description": "parent node path/name; default scene root"},
			"region": {"type": "array", "description": "2D [x,y,w,h] or 3D [x,y,z,w,h,d] bounds for positions"},
			"rotation": {"type": "number", "description": "max random rotation, degrees"},
			"scale_min": {"type": "number"},
			"scale_max": {"type": "number"},
			"seed": {"type": "integer"},
		}, "required": ["source", "count"]},
		"handler": Callable(self, "_scatter"),
	})


func _scatter(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open in the editor.", "suggestion": "Call open_scene first."}
	var count := int(args.get("count", 0))
	if count <= 0:
		return {"error": "count must be >= 1"}
	if count > _MAX:
		return {"error": "count too large (max %d)" % _MAX}
	var parent := _node(str(args.get("parent", "")))
	if parent == null:
		return {"error": "Could not resolve parent: %s" % str(args.get("parent", ""))}

	var source := str(args.get("source", ""))
	var packed: PackedScene = null
	var template: Node = null
	if source.begins_with("res://"):
		packed = ResourceLoader.load(source) as PackedScene
		if packed == null:
			return {"error": "Could not load PackedScene: %s" % source}
	else:
		template = _node(source)
		if template == null:
			return {"error": "Could not resolve source node: %s" % source}
		if template == root:
			return {"error": "Refusing to scatter the scene root (give a child or a res:// scene)."}

	var probe := _make(packed, template)
	var dim := _dim_of(probe)
	if dim == 0:
		probe.free()
		return {"error": "source is neither Node2D/Control (2D) nor Node3D (3D) — scatter needs a spatial node"}

	var region: Array = args.get("region", [])
	var rot_max := float(args.get("rotation", 0.0))
	var s_min := float(args.get("scale_min", 1.0))
	var s_max := float(args.get("scale_max", 1.0))
	var rng := RandomNumberGenerator.new()
	if args.has("seed"):
		rng.seed = int(args["seed"])

	var nodes: Array = [probe]
	for _i in range(count - 1):
		nodes.append(_make(packed, template))

	var base := String(template.name) if template != null else source.get_file().get_basename()
	if base == "":
		base = "Scatter"
	var ur: EditorUndoRedoManager = server.get_undo_redo()
	ur.create_action("MCP scatter_nodes x%d" % count)
	for i in range(nodes.size()):
		var n: Node = nodes[i]
		n.name = "%s_%d" % [base, i + 1]
		_place(n, dim, region, rot_max, s_min, s_max, rng)
		ur.add_do_method(parent, "add_child", n)
		if packed != null:
			ur.add_do_method(n, "set_owner", root)
		else:
			ur.add_do_method(self, "_own_recursive", n, root)
		ur.add_do_reference(n)
		ur.add_undo_method(parent, "remove_child", n)
	ur.commit_action()

	var names: Array = []
	for i in range(mini(nodes.size(), 20)):
		names.append(str(nodes[i].name))
	return {"json": {
		"created": count,
		"parent": ("." if parent == root else String(parent.name)),
		"source": source,
		"dim": ("3D" if dim == 3 else "2D"),
		"region": region,
		"seed": (int(args["seed"]) if args.has("seed") else null),
		"names_preview": names,
	}}



func _make(packed: PackedScene, template: Node) -> Node:
	return packed.instantiate() if packed != null else template.duplicate()


func _dim_of(n: Node) -> int:
	if n is Node3D:
		return 3
	if n is Node2D or n is Control:
		return 2
	return 0


## Place a (not-yet-parented) node with a random position in region, rotation, and scale.
func _place(n: Node, dim: int, region: Array, rot_max: float, s_min: float, s_max: float, rng: RandomNumberGenerator) -> void:
	var s := rng.randf_range(minf(s_min, s_max), maxf(s_min, s_max))
	if dim == 3:
		var p := Vector3.ZERO
		if region.size() >= 6:
			p = Vector3(
				float(region[0]) + rng.randf() * float(region[3]),
				float(region[1]) + rng.randf() * float(region[4]),
				float(region[2]) + rng.randf() * float(region[5]))
		n.position = p
		if rot_max != 0.0:
			n.rotation_degrees = Vector3(0.0, rng.randf_range(-rot_max, rot_max), 0.0)
		if s != 1.0:
			n.scale = Vector3(s, s, s)
	else:
		var pos := Vector2.ZERO
		if region.size() >= 4:
			pos = Vector2(
				float(region[0]) + rng.randf() * float(region[2]),
				float(region[1]) + rng.randf() * float(region[3]))
		n.position = pos
		if rot_max != 0.0:
			n.rotation = deg_to_rad(rng.randf_range(-rot_max, rot_max))
		if s != 1.0:
			n.scale = Vector2(s, s)


func _node(target: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	if target.is_empty() or target == "." or target == "/root" or target == root.name:
		return root
	var n := root.get_node_or_null(NodePath(target))
	if n == null:
		n = root.find_child(target, true, false)
	return n


## Set owner on a node and all descendants so a duplicated subtree persists on save.
func _own_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for c in node.get_children():
		_own_recursive(c, owner)
