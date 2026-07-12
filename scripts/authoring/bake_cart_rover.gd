extends SceneTree

const AUTHORING_SCENE := (
	"res://scenes/blueprint_authoring/cart_rover.tscn"
)


func _initialize() -> void:
	var packed := load(AUTHORING_SCENE) as PackedScene
	if packed == null:
		push_error("Failed to load cart_rover authoring scene")
		quit(1)
		return
	var root := packed.instantiate() as BlueprintAuthoringRoot
	if root == null:
		push_error("cart_rover authoring root is not BlueprintAuthoringRoot")
		quit(1)
		return
	var result: Dictionary = root.bake()
	if not bool(result.get("ok", false)):
		push_error(
			"cart_rover bake failed: %s" % ", ".join(root.last_bake_diagnostics)
		)
		root.free()
		quit(1)
		return
	print("Baked cart_rover to %s" % str(result.get("path", "")))
	root.free()
	quit(0)
