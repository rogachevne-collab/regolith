extends SceneTree

const AUTHORING_SCENE := (
	"res://scenes/blueprint_authoring/slice01_base_minimal.tscn"
)


func _initialize() -> void:
	var packed := load(AUTHORING_SCENE) as PackedScene
	if packed == null:
		push_error("Failed to load authoring scene")
		quit(1)
		return
	var root := packed.instantiate() as BlueprintAuthoringRoot
	if root == null:
		push_error("Authoring scene root is not BlueprintAuthoringRoot")
		quit(1)
		return
	var result: Dictionary = root.bake()
	if not bool(result.get("ok", false)):
		push_error(
			"Authoring bake failed: %s" % ", ".join(root.last_bake_diagnostics)
		)
		root.free()
		quit(1)
		return
	print(
		"Baked authoring blueprint to %s"
		% str(result.get("path", ""))
	)
	result.clear()
	root.free()
	packed = null
	quit(0)
