extends Node3D
## Spike 2: can a second, finer VoxelTerrain carry the loose material?
##
## Spike 1 showed the flow rules are affordable. This asks the other half:
## whether the voxel plugin will mesh and collide a 0.25 m field for us, so
## none of that has to be written in GDScript. The decisive proof is a physics
## raycast — if a ray lands on material we wrote, then meshing, collision
## generation and streaming all worked, which is the whole reason to put loose
## material in a terrain instead of a hand-rolled mesh.
##
## Bounded on purpose: a 0.25 m field must never try to cover a 19 km planet.
## It exists only around wherever digging is happening.

const _HeadlessTestHarness := preload(
	"res://scripts/testing/headless_test_harness.gd"
)

const LABEL := "GRANULAR-VOXEL-TERRAIN"
const VOXEL_SCALE := 0.25
## Half-size of the region the fine field covers, in world metres.
const REGION_HALF_M := 12.0
## Blob written in world metres, the size of a few drill bites' worth.
const BLOB_RADIUS_M := 1.5
const BLOB_CENTRE := Vector3(0.0, 0.0, 0.0)
const SETTLE_FRAMES := 240


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_HeadlessTestHarness.arm_watchdog(self, LABEL, 90.0)
	var terrain := VoxelTerrain.new()
	terrain.scale = Vector3.ONE * VOXEL_SCALE
	var mesher := VoxelMesherTransvoxel.new()
	terrain.mesher = mesher
	# Flat generator pushed far below the region: every voxel starts as air, so
	# the field holds nothing but what we write into it.
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = -100000.0
	terrain.generator = generator
	terrain.generate_collisions = true
	var half_voxels := int(REGION_HALF_M / VOXEL_SCALE)
	terrain.set_bounds(
		AABB(
			Vector3(-half_voxels, -half_voxels, -half_voxels),
			Vector3(half_voxels * 2, half_voxels * 2, half_voxels * 2)
		)
	)
	add_child(terrain)
	var viewer := VoxelViewer.new()
	viewer.view_distance = half_voxels
	terrain.add_child(viewer)

	print(
		"%s: terrain scale %.2f, bounds +-%d voxels (+-%.1f m)"
		% [LABEL, VOXEL_SCALE, half_voxels, REGION_HALF_M]
	)
	for _i in 30:
		await get_tree().process_frame

	var tool_ := terrain.get_voxel_tool()
	if tool_ == null:
		_fail("no VoxelTool from the fine terrain")
		return
	tool_.channel = VoxelBuffer.CHANNEL_SDF
	tool_.mode = VoxelTool.MODE_ADD
	var local_centre: Vector3 = (
		terrain.global_transform.affine_inverse() * BLOB_CENTRE
	)
	var local_radius := BLOB_RADIUS_M / VOXEL_SCALE
	var write_started := Time.get_ticks_usec()
	tool_.do_sphere(local_centre, local_radius)
	var write_ms := float(Time.get_ticks_usec() - write_started) / 1000.0
	print(
		"%s: wrote r=%.2f m blob (%d voxels across) in %.2f ms"
		% [LABEL, BLOB_RADIUS_M, int(local_radius * 2.0), write_ms]
	)

	for _i in SETTLE_FRAMES:
		await get_tree().process_frame

	# The proof: drop a ray onto the blob and see whether physics knows it is
	# there. Nothing else confirms meshing and collision actually happened.
	var from := BLOB_CENTRE + Vector3.UP * (BLOB_RADIUS_M + 4.0)
	var to := BLOB_CENTRE - Vector3.UP * (BLOB_RADIUS_M + 4.0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		_fail("physics ray found nothing — the fine field did not collide")
		return
	var hit_point: Vector3 = hit["position"]
	var expected_top := BLOB_CENTRE.y + BLOB_RADIUS_M
	print(
		"%s: ray hit %s (top expected ~%.2f, off by %.2f m)"
		% [LABEL, str(hit_point), expected_top, absf(hit_point.y - expected_top)]
	)
	print("%s: statistics %s" % [LABEL, str(terrain.get_statistics())])
	print(
		"%s: static memory %.1f MB"
		% [LABEL, float(OS.get_static_memory_usage()) / 1048576.0]
	)
	if absf(hit_point.y - expected_top) > 1.0:
		_fail(
			"collision surface is %.2f m from where the blob was written"
			% absf(hit_point.y - expected_top)
		)
		return
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("%s: FAIL - %s" % [LABEL, message])
	get_tree().quit(1)
