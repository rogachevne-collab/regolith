extends Node3D

## Bake SE-like moon crust: panoramic heightmap for SdfSphereHeightmap (seconds).
## Not the old multi-hour VoxelLodTerrain region crawl.
## Usage: ./run.sh res://scenes/moon_bake_stream.tscn

const WIDTH := 2048
const HEIGHT := 1024
const _HeightmapUtil := preload("res://scripts/simulation/runtime/moon_heightmap_util.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var abs_path: String = _HeightmapUtil.absolute_heightmap_path()
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
	var img: Image = _HeightmapUtil.bake_heightmap(WIDTH, HEIGHT, abs_path)
	if img == null or img.get_width() <= 0:
		push_error("BAKE: heightmap failed")
	else:
		print(
			"BAKE: DONE heightmap %dx%d → %s (%.1f KB)"
			% [
				img.get_width(),
				img.get_height(),
				abs_path,
				float(FileAccess.get_file_as_bytes(abs_path).size()) / 1024.0,
			]
		)
	get_tree().quit()
