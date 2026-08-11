extends Node
## Does the native grain kernel lay the same stones the script lays?
##
## `GranularGrainKernel` is a transcription of `GranularGrainShell.lay`'s main
## path, and the thing it is transcribing is a *picture*: eighty integer hashes
## and eight quaternion normalisations per cell, every one of which feeds a
## position, a size or an attitude. A transcription error does not produce a
## slightly different heap — it produces a completely different scatter from the
## first hash that drifts, which is loud here and impossible to review by eye in
## the game. So this asks for the layout of a few thousand cells, slot for slot,
## and compares every basis column and every origin.
##
## **What it covers and what it does not.** The reference below is a hand
## transliteration of `GranularGrainShell.lay`, not a call into it: `lay` writes
## through `RenderingServer` into a MultiMesh, and the headless renderer is a
## stub whose buffers cannot be read back. So this catches the whole of the
## risk that exists today — that the port mis-copied an operator, a seed or an
## order of operations — and it would not catch the script and the kernel
## drifting apart in some later edit that changed both this file's neighbour and
## not this file. Change `lay`'s arithmetic and you must change the reference
## here in the same commit; the numbers themselves live in
## `GranularGrainShell`, so a changed *constant* is picked up automatically.
##
## Not in the kernel gate (`tests/run_tests.sh`) for the same reason
## `test_granular_field_parity` is not: it proves two implementations agree, and
## the gate is for the simulation's own invariants. Run it with
## `tests/run_one.sh test_granular_grain_kernel` after touching either side.

const LABEL := "GRANULAR-GRAIN-KERNEL"
const _Shell := preload("res://scripts/presentation/granular_grain_shell.gd")

## Last-bit tolerance, and it is here for one specific reason: the compiler may
## contract a multiply and an add into an FMA where the interpreter cannot, so
## agreeing implementations can still differ in the final bits. A *transcription*
## error is never subtle — a drifted hash moves a stone by centimetres — so
## anything this size is arithmetic noise and anything bigger is a bug.
const EPSILON := 1e-9

var _max_deviation := 0.0
var _compared := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists(&"GranularGrainKernel"):
		_fail(
			"GranularGrainKernel (native) is not registered — "
			+ "extension not loaded or not rebuilt"
		)
		return
	# Both seat floors the shell is ever built with: zero when nothing else
	# draws the cell, and the view's `RENDER_MIN_FILL` when the surface mesh
	# does. They rescale every seated height, so both are worth a pass.
	for seat_floor in [0.0, 0.15]:
		if not _sweep(float(seat_floor)):
			return
	print(
		"%s: %d slots compared, max deviation %.3e"
		% [LABEL, _compared, _max_deviation]
	)
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


## Every branch the muck can take, crossed against every variant.
##
## The indices are swept rather than sampled because the boulder roll fires on
## about one cell in twenty (`BOULDER_CHANCE`) and the shown-count clamp bites
## only at the ends of the mass range — a handful of hand-picked cells would
## miss both, and both are branches.
func _sweep(seat_floor: float) -> bool:
	var kernel: Object = _Shell.make_kernel(seat_floor)
	if kernel == null:
		_fail("GranularGrainShell.make_kernel returned null")
		return false
	var scales: PackedFloat32Array = _Shell._mesh_scales
	if scales.is_empty():
		_fail("no chip meshes loaded — cannot compare a layout against nothing")
		return false
	var variants := scales.size()
	# A patch normal that is neither axis-aligned nor degenerate, so the
	# tangent basis is exercised rather than falling on a world axis; and the
	# zero normal, which is the fringe fallback along +Y.
	var normals: Array[Vector3] = [
		Vector3.ZERO,
		Vector3(0.31, 0.86, -0.4).normalized(),
		Vector3(-0.94, 0.05, 0.33).normalized(),
	]
	# Below `FINES_MASS`, just above it, mid, and full — the clear-and-return
	# branch, the boulder threshold either side, and the clamp at the top.
	var masses: Array[float] = [0.0, 0.02, 0.039, 0.05, 0.3, 0.49, 0.5, 0.8, 1.0, 1.6]
	for index in range(0, 4096):
		var variant := index % variants
		var cell := Vector3i(index % 37, (index / 37) % 29, (index / 1073) % 31)
		var mass: float = masses[index % masses.size()]
		var normal: Vector3 = normals[index % normals.size()]
		var cell_size := 0.25 if index % 2 == 0 else 0.5
		var surface_pos := Vector3(
			float(cell.x) + 0.5, float(cell.y) + 0.5, float(cell.z) + 0.5
		)
		var got: Array = kernel.call(
			"layout", variant, index, cell, cell_size, mass, surface_pos, normal
		)
		var want := _reference_layout(
			variant, index, cell, cell_size, mass, surface_pos, normal, seat_floor
		)
		if got.size() != want.size():
			_fail(
				"slot count differs at index %d (seat_floor %.2f): native %d, script %d"
				% [index, seat_floor, got.size(), want.size()]
			)
			return false
		for slot in want.size():
			if not _same(got[slot], want[slot]):
				_fail(
					(
						"layout differs at index %d slot %d (seat_floor %.2f, "
						+ "variant %d, mass %.3f, normal %s)\n  native: %s\n  script: %s"
					)
					% [
						index, slot, seat_floor, variant, mass, str(normal),
						str(got[slot]), str(want[slot])
					]
				)
				return false
	return true


func _same(a: Transform3D, b: Transform3D) -> bool:
	_compared += 1
	var vectors: Array[Array] = [
		[a.basis.x, b.basis.x],
		[a.basis.y, b.basis.y],
		[a.basis.z, b.basis.z],
		[a.origin, b.origin],
	]
	var ok := true
	for pair in vectors:
		var lhs: Vector3 = pair[0]
		var rhs: Vector3 = pair[1]
		for axis in 3:
			var deviation := absf(lhs[axis] - rhs[axis])
			if deviation > _max_deviation:
				_max_deviation = deviation
			if deviation > EPSILON:
				ok = false
	return ok


## `GranularGrainShell.lay`'s main path, transliterated — the specification this
## gate holds the kernel to. Slot order is the kernel's: the plug/boulder slot
## first, then one per grain.
##
## Deliberately spelled the way the shell spells it, down to the order of
## operations inside each expression, because that is what is being checked.
func _reference_layout(
	variant: int,
	index: int,
	cell: Vector3i,
	cell_size: float,
	mass: float,
	surface_pos: Vector3,
	surface_nrm: Vector3,
	seat_floor: float
) -> Array:
	var out: Array = []
	var mesh_scale: float = _Shell._mesh_scales[variant]
	var mesh_offset: Vector3 = _Shell._mesh_offsets[variant]
	var x := cell.x
	var y := cell.y
	var z := cell.z
	var held := minf(mass, 1.0)
	var seated := maxf(held - seat_floor, 0.0) / maxf(1.0 - seat_floor, 0.001)
	var fill := seated * cell_size
	var on_patch := surface_nrm != Vector3.ZERO
	var pos_m := surface_pos * cell_size
	var tan_a := Vector3.ZERO
	var tan_b := Vector3.ZERO
	if on_patch:
		var ref := Vector3.UP if absf(surface_nrm.y) < 0.9 else Vector3.RIGHT
		tan_a = surface_nrm.cross(ref).normalized()
		tan_b = surface_nrm.cross(tan_a)
	if held < _Shell.FINES_MASS:
		for g in _Shell.SLOTS_PER_CELL:
			out.append(_Shell._EMPTY)
		return out
	if (
		held >= _Shell.BOULDER_MIN_MASS
		and _Shell._unit(index * 29 + 1) < _Shell.BOULDER_CHANCE
	):
		var size := (
			_Shell.BOULDER_MIN_M
			+ (_Shell.BOULDER_MAX_M - _Shell.BOULDER_MIN_M) * _Shell._unit(index * 29 + 7)
		)
		var basis := Basis(
			Quaternion(
				Vector3(
					_Shell._unit(index * 29 + 3) * 2.0 - 1.0,
					_Shell._unit(index * 29 + 5) * 2.0 - 1.0,
					_Shell._unit(index * 29 + 11) * 2.0 - 1.0
				).normalized(),
				_Shell._unit(index * 29 + 17) * TAU
			)
		).scaled(
			Vector3(
				size,
				size * (0.6 + 0.3 * _Shell._unit(index * 29 + 19)),
				size * (0.75 + 0.35 * _Shell._unit(index * 29 + 23))
			) * mesh_scale
		)
		var origin: Vector3
		if surface_nrm != Vector3.ZERO:
			origin = pos_m - surface_nrm * (size * 0.28)
		else:
			origin = Vector3(
				(float(x) + 0.2 + 0.6 * _Shell._unit(index * 29 + 27)) * cell_size,
				float(y) * cell_size + fill - size * 0.28,
				(float(z) + 0.2 + 0.6 * _Shell._unit(index * 29 + 31)) * cell_size
			)
		out.append(Transform3D(basis, origin + basis * mesh_offset))
	else:
		out.append(_Shell._EMPTY)
	var patch := _Shell._unit(
		(x >> 2) * 73856093 ^ (y >> 2) * 19349663 ^ (z >> 2) * 83492791
	)
	var size_mult := 0.7 + 0.6 * patch
	var shown := clampi(
		int(round(
			float(_Shell.MAX_GRAINS_PER_CELL)
			* held
			* (0.75 + 0.5 * _Shell._unit(index * 9781))
			* (1.2 - 0.4 * patch)
		)),
		1,
		_Shell.MAX_GRAINS_PER_CELL
	)
	for g in _Shell.MAX_GRAINS_PER_CELL:
		if g >= shown:
			out.append(_Shell._EMPTY)
			continue
		var seed := index * _Shell.MAX_GRAINS_PER_CELL + g
		var size_roll := _Shell._unit(seed * 3 + 2)
		var size := _Shell.GRAIN_SIZE_M * size_mult * (
			_Shell.GRAIN_SIZE_MIN_FRACTION
			+ (1.0 - _Shell.GRAIN_SIZE_MIN_FRACTION) * size_roll * size_roll
		)
		var rise := _Shell._unit(seed * 3 + 4)
		var origin: Vector3
		if on_patch:
			var a := (_Shell._unit(seed * 3 + 0) - 0.5) * _Shell.PATCH_SPREAD_CELLS * cell_size
			var b := (_Shell._unit(seed * 3 + 1) - 0.5) * _Shell.PATCH_SPREAD_CELLS * cell_size
			var sink := size * (0.15 + 0.35 * rise) + _Shell.SEAT_NESTLE_CELLS * cell_size
			origin = pos_m + tan_a * a + tan_b * b - surface_nrm * sink
		else:
			var sink := _Shell.SEAT_SINK_CELLS * seated * cell_size
			origin = Vector3(
				(float(x) - 0.15 + 1.3 * _Shell._unit(seed * 3 + 0)) * cell_size,
				(
					float(y) * cell_size
					+ fill * (1.0 - rise * rise)
					- minf(size * 0.45, fill * 0.6)
					- sink
				),
				(float(z) - 0.15 + 1.3 * _Shell._unit(seed * 3 + 1)) * cell_size
			)
		var basis := Basis(
			Quaternion(
				Vector3(
					_Shell._unit(seed * 7 + 3) * 2.0 - 1.0,
					_Shell._unit(seed * 7 + 5) * 2.0 - 1.0,
					_Shell._unit(seed * 7 + 11) * 2.0 - 1.0
				).normalized(),
				_Shell._unit(seed * 7 + 13) * TAU
			)
		).scaled(
			Vector3(
				size,
				size * (0.35 + 0.4 * _Shell._unit(seed * 13 + 1)),
				size * (0.6 + 0.5 * _Shell._unit(seed * 13 + 7))
			) * mesh_scale
		)
		out.append(Transform3D(basis, origin + basis * mesh_offset))
	return out


func _fail(reason: String) -> void:
	push_error("%s: FAIL - %s" % [LABEL, reason])
	print("%s: FAIL - %s" % [LABEL, reason])
	get_tree().quit(1)
