extends RefCounted
class_name ViewmodelRtMesh

const BUF_FLAGS := (
	RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT
	| RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT
)


static func collect_mesh_instances(root: Node, skip_subtree: Node = null) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	_collect_mesh_instances_impl(root, skip_subtree, out)
	return out


static func _collect_mesh_instances_impl(node: Node, skip: Node, out: Array[MeshInstance3D]) -> void:
	if skip != null and (node == skip or skip.is_ancestor_of(node)):
		return
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			out.append(mi)
	for child in node.get_children():
		_collect_mesh_instances_impl(child, skip, out)


static func bake_blas(
	rd: RenderingDevice,
	meshes: Array[MeshInstance3D],
	bake_root: Node3D
) -> Dictionary:
	var interleaved := PackedFloat32Array()
	var indices := PackedInt32Array()
	var index_base := 0
	var bake_inv := bake_root.global_transform.affine_inverse()
	for mi in meshes:
		var arrays := _mesh_surface_arrays(mi)
		if arrays.is_empty():
			continue
		var local := bake_inv * mi.global_transform
		_append_surface(interleaved, indices, arrays, local, index_base)
		index_base = interleaved.size() / 3
	if interleaved.is_empty() or indices.is_empty():
		return {}
	return bake_blas_from_arrays(rd, interleaved, indices)


## Bake pre-extracted terrain-local (or object-local) triangle data.
static func bake_blas_from_arrays(
	rd: RenderingDevice,
	interleaved: PackedFloat32Array,
	indices: PackedInt32Array
) -> Dictionary:
	if interleaved.is_empty() or indices.is_empty():
		return {}
	var interleaved_bytes := interleaved.to_byte_array()
	var vertex_buffer := rd.vertex_buffer_create(interleaved_bytes.size(), interleaved_bytes, BUF_FLAGS)
	var vdesc := RDVertexAttribute.new()
	vdesc.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	vdesc.location = 0
	vdesc.offset = 0
	vdesc.stride = 12
	var vfmt := rd.vertex_format_create([vdesc])
	@warning_ignore("integer_division")
	var vertex_count := interleaved.size() / 3
	var vertex_array := rd.vertex_array_create(vertex_count, vfmt, [vertex_buffer])
	var index_bytes := indices.to_byte_array()
	var index_buffer := rd.index_buffer_create(
		indices.size(),
		RenderingDevice.INDEX_BUFFER_FORMAT_UINT32,
		index_bytes,
		false,
		BUF_FLAGS
	)
	var index_array := rd.index_array_create(index_buffer, 0, indices.size())
	var geometry := RDAccelerationStructureGeometry.new()
	geometry.index_buffer = index_buffer
	geometry.index_count = indices.size()
	geometry.vertex_buffer = vertex_buffer
	geometry.vertex_count = vertex_count
	geometry.vertex_format = vdesc.format
	geometry.vertex_stride = 12
	geometry.flags = RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT
	var blas := rd.blas_create(
		[geometry],
		RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT
	)
	if not blas.is_valid():
		rd.free_rid(vertex_buffer)
		rd.free_rid(index_buffer)
		rd.free_rid(vertex_array)
		rd.free_rid(index_array)
		return {}
	rd.blas_build(blas)
	return {
		"blas": blas,
		"vertex_buffer": vertex_buffer,
		"vertex_array": vertex_array,
		"index_buffer": index_buffer,
		"index_array": index_array,
	}


## Extract triangles from a Mesh surface arrays Array (as returned by
## VoxelLodTerrain.get_mesh_block_surface). Vertices stay in mesh-local space.
## When `transition_mask` >= 0, apply the same Transvoxel vertex transform the
## terrain shader uses (`get_transvoxel_position` + inactive-transition cull).
static func extract_from_surface_arrays(surface: Array, transition_mask: int = -1) -> Dictionary:
	if surface.is_empty() or surface[Mesh.ARRAY_VERTEX] == null:
		return {}
	var interleaved := PackedFloat32Array()
	var indices := PackedInt32Array()
	if transition_mask >= 0 and surface[Mesh.ARRAY_CUSTOM0] != null:
		_append_transvoxel_surface(interleaved, indices, surface, transition_mask)
	else:
		_append_surface(interleaved, indices, [surface], Transform3D.IDENTITY, 0)
	if interleaved.is_empty() or indices.is_empty():
		return {}
	var h := _geometry_hash(interleaved, indices)
	if transition_mask >= 0:
		h = h * 31 + transition_mask
	return {
		"floats": interleaved,
		"indices": indices,
		"content_hash": h,
	}


## Copy mesh triangles into bake_root-local space (survives after snapshot free).
static func extract_local_geometry(mi: MeshInstance3D, bake_root: Node3D) -> Dictionary:
	var interleaved := PackedFloat32Array()
	var indices := PackedInt32Array()
	var arrays := _mesh_surface_arrays(mi)
	if arrays.is_empty():
		return {}
	var local := bake_root.global_transform.affine_inverse() * mi.global_transform
	_append_surface(interleaved, indices, arrays, local, 0)
	if interleaved.is_empty() or indices.is_empty():
		return {}
	return {
		"floats": interleaved,
		"indices": indices,
		"content_hash": _geometry_hash(interleaved, indices),
	}


static func _geometry_hash(floats: PackedFloat32Array, indices: PackedInt32Array) -> int:
	# Dig remeshes often keep corner verts + similar triangle counts — a
	# first/last-only hash collides and leaves a phantom BLAS lid over holes.
	var h := floats.size() * 73856093 + indices.size() * 19349663
	if floats.is_empty():
		return h
	# Dense-enough sample: small digs must change the fingerprint.
	var step := maxi(floats.size() / 128, 3)
	var i := 0
	while i < floats.size():
		h = h * 31 + int(floats[i] * 1000.0)
		i += step
	# Also fold a few Y samples (dig holes change height more than XZ).
	var y_step := maxi(floats.size() / 64, 3)
	var yi := 1
	while yi < floats.size():
		h = h * 31 + int(floats[yi] * 1000.0)
		yi += y_step
	if indices.size() >= 3:
		h = h * 31 + int(indices[0])
		h = h * 31 + int(indices[indices.size() / 2])
		h = h * 31 + int(indices[indices.size() - 1])
	# Cheap AABB fingerprint (dig changes bounds even when counts match).
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	var sum_y := 0.0
	var samples := 0
	var vi := 0
	var v_stride := 3 * maxi(floats.size() / 192, 1)
	while vi + 2 < floats.size():
		var p := Vector3(floats[vi], floats[vi + 1], floats[vi + 2])
		min_v = min_v.min(p)
		max_v = max_v.max(p)
		sum_y += p.y
		samples += 1
		vi += v_stride
	h = h * 31 + int(min_v.x * 100.0) + int(min_v.y * 100.0) * 97 + int(min_v.z * 100.0) * 193
	h = h * 31 + int(max_v.x * 100.0) + int(max_v.y * 100.0) * 97 + int(max_v.z * 100.0) * 193
	if samples > 0:
		h = h * 31 + int((sum_y / float(samples)) * 1000.0)
	return h


static func _mesh_surface_arrays(mi: MeshInstance3D) -> Array:
	var mesh := mi.mesh
	if mesh == null:
		return []
	var arrays: Array = []
	for s in mesh.get_surface_count():
		var src := mesh.surface_get_arrays(s)
		if src.is_empty() or src[Mesh.ARRAY_VERTEX] == null:
			continue
		arrays.append(src)
	return arrays


static func _append_surface(
	interleaved: PackedFloat32Array,
	indices: PackedInt32Array,
	surfaces: Array,
	local: Transform3D,
	index_base: int
) -> void:
	for src in surfaces:
		var verts: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var idx: PackedInt32Array = src[Mesh.ARRAY_INDEX] if src[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		for i in verts.size():
			var p: Vector3 = local * verts[i]
			interleaved.append(p.x)
			interleaved.append(p.y)
			interleaved.append(p.z)
		if idx.is_empty():
			for j in verts.size():
				indices.append(index_base + j)
		else:
			for j in idx.size():
				indices.append(index_base + idx[j])
		index_base += verts.size()


## Mirror of addons/zylann.voxel/shaders/transvoxel.gdshaderinc
## get_transvoxel_position — without this, inactive transition tris stay in the
## BLAS at full size while the visual shader collapses them to degenerate.
static func _append_transvoxel_surface(
	interleaved: PackedFloat32Array,
	indices: PackedInt32Array,
	surface: Array,
	transition_mask: int
) -> void:
	var verts: PackedVector3Array = surface[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return
	var custom0 := _custom0_as_floats(surface[Mesh.ARRAY_CUSTOM0], verts.size())
	if custom0.is_empty():
		_append_surface(interleaved, indices, [surface], Transform3D.IDENTITY, 0)
		return
	var tmask := transition_mask & 0xff
	var remap := PackedInt32Array()
	remap.resize(verts.size())
	var out_count := 0
	for i in verts.size():
		var base := i * 4
		var secondary := Vector3(custom0[base], custom0[base + 1], custom0[base + 2])
		var idata := _float_bits_to_int(custom0[base + 3])
		var cell_border_mask := idata & 63
		var vertex_border_mask := (idata >> 8) & 63
		var itransition := (idata >> 16) & 0xff
		var secondary_factor := 0.0
		if (tmask & cell_border_mask) != 0 and (vertex_border_mask & ~tmask) == 0:
			secondary_factor = 1.0
		# Inactive transition verts are culled in the shader (pos *= 0).
		if itransition != 0 and (itransition & tmask) == 0:
			remap[i] = -1
			continue
		var pos: Vector3 = verts[i].lerp(secondary, secondary_factor)
		remap[i] = out_count
		interleaved.append(pos.x)
		interleaved.append(pos.y)
		interleaved.append(pos.z)
		out_count += 1
	if out_count == 0:
		return
	var idx: PackedInt32Array = surface[Mesh.ARRAY_INDEX] if surface[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		for j in verts.size():
			if remap[j] >= 0:
				indices.append(remap[j])
		return
	var t := 0
	while t + 2 < idx.size():
		var a := remap[idx[t]]
		var b := remap[idx[t + 1]]
		var c := remap[idx[t + 2]]
		if a >= 0 and b >= 0 and c >= 0:
			indices.append(a)
			indices.append(b)
			indices.append(c)
		t += 3


static func _custom0_as_floats(custom0: Variant, vertex_count: int) -> PackedFloat32Array:
	if custom0 == null:
		return PackedFloat32Array()
	if custom0 is PackedFloat32Array:
		var pf: PackedFloat32Array = custom0
		if pf.size() >= vertex_count * 4:
			return pf
		return PackedFloat32Array()
	if custom0 is PackedColorArray:
		var colors: PackedColorArray = custom0
		var out := PackedFloat32Array()
		out.resize(colors.size() * 4)
		for i in colors.size():
			var c: Color = colors[i]
			var o := i * 4
			out[o] = c.r
			out[o + 1] = c.g
			out[o + 2] = c.b
			out[o + 3] = c.a
		return out
	return PackedFloat32Array()


static func _float_bits_to_int(f: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, f)
	return bytes.decode_s32(0)
