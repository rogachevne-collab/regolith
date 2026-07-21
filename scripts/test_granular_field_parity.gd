extends Node
## Does the native field settle *identically* to the script it was ported from?
##
## Not "does it pass the same assertions" — identically, cell for cell, bit for
## bit, after every single sweep. A cellular automaton has no small differences:
## a last-bit disagreement in one transfer changes which neighbour crosses a
## threshold next sweep, and a few hundred sweeps later it is a different pile.
## So parity is checked continuously and the first divergence is reported with
## its cell and its two values, rather than checked at the end where all it
## could say is "the heaps differ".
##
## The script is the specification. Wherever they disagree, the native side is
## wrong by definition — including where the script does something odd, which
## is why `take_fraction` not marking its cell dirty is reproduced rather than
## fixed here.

const LABEL := "GRANULAR-FIELD-PARITY"
const CELL := 0.25


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("GranularVoxelField"):
		_fail("GranularVoxelField (native) is not registered — extension not loaded")
		return
	if not _test_pour_settles_identically():
		return
	if not _test_tight_budget_identically():
		return
	if not _test_undermining_identically():
		return
	if not _test_takes_and_deposits_identically():
		return
	_report_speed()
	print("%s: PASS" % LABEL)
	get_tree().quit(0)


## A pour into a box, compared after every sweep until both come to rest.
func _test_pour_settles_identically() -> bool:
	var dims := Vector3i(32, 40, 32)
	var pair := _make_pair(dims)
	for z in dims.z:
		for x in dims.x:
			for y in 2:
				pair.gd.set_solid(x, y, z, true)
				pair.native.set_solid(x, y, z, true)
	# A column with a real footprint, poured identically into both.
	for step in 12:
		for dz in range(-2, 3):
			for dx in range(-2, 3):
				pair.gd.deposit(16 + dx, 2 + step, 16 + dz, 0.6)
				pair.native.deposit(16 + dx, 2 + step, 16 + dz, 0.6)
	return _run_to_rest(pair, dims, 20000, 0, "pour")


## The starvation case: a budget far smaller than the woken set, which is what
## exercises the rotating window and the carry-over.
func _test_tight_budget_identically() -> bool:
	var dims := Vector3i(24, 40, 24)
	var pair := _make_pair(dims)
	for z in dims.z:
		for x in dims.x:
			pair.gd.set_solid(x, 0, z, true)
			pair.native.set_solid(x, 0, z, true)
	for y in range(20, 36):
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				pair.gd.deposit(12 + dx, y, 12 + dz, 1.0)
				pair.native.deposit(12 + dx, y, 12 + dz, 1.0)
	return _run_to_rest(pair, dims, 20000, 16, "tight budget")


## Rock answered by a callback and then taken away — the lazy `solid_query`
## path, its memo, and the invalidation that has to wake the heap above.
func _test_undermining_identically() -> bool:
	var dims := Vector3i(32, 48, 32)
	var pillar_top := 20
	var carved := [false]
	var query := func(cell: Vector3i) -> bool:
		if cell.y < 2:
			return true
		if bool(carved[0]):
			return false
		return (
			cell.y < pillar_top
			and absi(cell.x - 16) <= 2
			and absi(cell.z - 16) <= 2
		)
	var pair := _make_pair(dims)
	pair.gd.solid_query = query
	pair.native.solid_query = query
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			for dy in range(0, 6):
				pair.gd.deposit(16 + dx, pillar_top + dy, 16 + dz, 1.0)
				pair.native.deposit(16 + dx, pillar_top + dy, 16 + dz, 1.0)
	if not _run_to_rest(pair, dims, 20000, 0, "on the pillar"):
		return false
	carved[0] = true
	pair.gd.invalidate_solid(Vector3i(10, 2, 10), Vector3i(22, pillar_top, 22))
	pair.native.invalidate_solid(Vector3i(10, 2, 10), Vector3i(22, pillar_top, 22))
	return _run_to_rest(pair, dims, 40000, 0, "undermined")


## The mutators, including the odd one. Interleaved with sweeps, because their
## effect on the wake queue matters as much as their effect on mass.
func _test_takes_and_deposits_identically() -> bool:
	var dims := Vector3i(16, 24, 16)
	var pair := _make_pair(dims)
	for z in dims.z:
		for x in dims.x:
			pair.gd.set_solid(x, 0, z, true)
			pair.native.set_solid(x, 0, z, true)
	for round_index in 40:
		var x := 4 + (round_index * 7) % 8
		var z := 4 + (round_index * 5) % 8
		var y := 3 + (round_index * 3) % 12
		var a: float = pair.gd.deposit(x, y, z, 0.5)
		var b: float = pair.native.deposit(x, y, z, 0.5)
		if not is_equal_approx(a, b):
			_fail("deposit returned %.9f vs %.9f" % [a, b])
			return false
		if round_index % 3 == 0:
			var ta: float = pair.gd.take_fraction(x, y, z, 0.4)
			var tb: float = pair.native.take_fraction(x, y, z, 0.4)
			if not is_equal_approx(ta, tb):
				_fail("take_fraction returned %.9f vs %.9f" % [ta, tb])
				return false
		if round_index % 7 == 0:
			var ka: float = pair.gd.take(x, y, z)
			var kb: float = pair.native.take(x, y, z)
			if not is_equal_approx(ka, kb):
				_fail("take returned %.9f vs %.9f" % [ka, kb])
				return false
		for _s in 3:
			pair.gd.step(24)
			pair.native.step(24)
			if not _compare(pair, dims, "mutators sweep %d" % round_index):
				return false
		# The dirty batch is what the renderer sees, so it has to match too.
		var da: PackedInt32Array = pair.gd.take_dirty()
		var db: PackedInt32Array = pair.native.take_dirty()
		if da != db:
			_fail(
				"dirty batch differs at round %d: %d vs %d cells"
				% [round_index, da.size(), db.size()]
			)
			return false
	print("%s: mutators and dirty batches identical over 40 rounds" % LABEL)
	return true


## Step both to rest, comparing after every sweep.
func _run_to_rest(
	pair: Dictionary,
	dims: Vector3i,
	max_sweeps: int,
	budget: int,
	what: String
) -> bool:
	var sweeps := 0
	while sweeps < max_sweeps:
		var settled_gd: bool = pair.gd.is_settled()
		var settled_native: bool = pair.native.is_settled()
		if settled_gd != settled_native:
			_fail(
				"%s: is_settled disagrees at sweep %d (script %s, native %s)"
				% [what, sweeps, settled_gd, settled_native]
			)
			return false
		if settled_gd:
			break
		var visited_gd: int = pair.gd.step(budget)
		var visited_native: int = pair.native.step(budget)
		if visited_gd != visited_native:
			_fail(
				"%s: visited count disagrees at sweep %d (%d vs %d)"
				% [what, sweeps, visited_gd, visited_native]
			)
			return false
		# Only cells that moved can disagree, so exactly those are compared —
		# which still catches a divergence in the very sweep that produced it,
		# while a full box walk every sweep costs forty million binding calls
		# to reach the same answer. It also checks the batch itself, which is
		# what the renderer consumes.
		var dirty_gd: PackedInt32Array = pair.gd.take_dirty()
		var dirty_native: PackedInt32Array = pair.native.take_dirty()
		if dirty_gd != dirty_native:
			_fail(
				"%s: dirty batch differs at sweep %d (%d vs %d cells)"
				% [what, sweeps, dirty_gd.size(), dirty_native.size()]
			)
			return false
		var plane := dims.x * dims.z
		for i: int in dirty_gd:
			var cx := i % dims.x
			var cy := i / plane
			var cz := (i / dims.x) % dims.z
			var a: float = pair.gd.mass_at(cx, cy, cz)
			var b: float = pair.native.mass_at(cx, cy, cz)
			if a != b:
				_fail(
					"%s: sweep %d cell (%d,%d,%d) script %.9f vs native %.9f"
					% [what, sweeps, cx, cy, cz, a, b]
				)
				return false
		sweeps += 1
	if sweeps >= max_sweeps:
		_fail("%s: never came to rest in %d sweeps" % [what, max_sweeps])
		return false
	# The whole box once at rest, in case anything moved without being reported
	# dirty — which is precisely the class of bug the per-sweep check cannot see.
	if not _compare(pair, dims, "%s at rest" % what):
		return false
	var vol_gd: float = pair.gd.total_volume_m3()
	var vol_native: float = pair.native.total_volume_m3()
	if absf(vol_gd - vol_native) > 1e-12:
		_fail("%s: volume %.12f vs %.12f" % [what, vol_gd, vol_native])
		return false
	print(
		"%s: %s — identical through %d sweeps, volume %.6f m3"
		% [LABEL, what, sweeps, vol_gd]
	)
	return true


## Every cell, exact equality. Float32 values that came from the same
## operations in the same order must match to the bit; anything else is a
## divergence however small it looks now.
func _compare(pair: Dictionary, dims: Vector3i, where: String) -> bool:
	for y in dims.y:
		for z in dims.z:
			for x in dims.x:
				var a: float = pair.gd.mass_at(x, y, z)
				var b: float = pair.native.mass_at(x, y, z)
				if a != b:
					_fail(
						"%s: cell (%d,%d,%d) script %.9f vs native %.9f (delta %.3e)"
						% [where, x, y, z, a, b, b - a]
					)
					return false
	return true


## What the port was for. Same box, same pour, same sweeps — wall clock only.
func _report_speed() -> void:
	var dims := Vector3i(96, 64, 96)
	var pair := _make_pair(dims)
	for z in dims.z:
		for x in dims.x:
			for y in 2:
				pair.gd.set_solid(x, y, z, true)
				pair.native.set_solid(x, y, z, true)
	var remaining := 20.0
	for step in 40:
		for dz in range(-4, 5):
			for dx in range(-4, 5):
				if remaining <= 0.0:
					break
				remaining -= pair.gd.deposit(16 + dx, 2 + step, 16 + dz, remaining)
	remaining = 20.0
	for step in 40:
		for dz in range(-4, 5):
			for dx in range(-4, 5):
				if remaining <= 0.0:
					break
				remaining -= pair.native.deposit(16 + dx, 2 + step, 16 + dz, remaining)
	var t := Time.get_ticks_usec()
	var sweeps_gd := 0
	while not pair.gd.is_settled() and sweeps_gd < 20000:
		pair.gd.step(128)
		sweeps_gd += 1
	var ms_gd := float(Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	var sweeps_native := 0
	while not pair.native.is_settled() and sweeps_native < 20000:
		pair.native.step(128)
		sweeps_native += 1
	var ms_native := float(Time.get_ticks_usec() - t) / 1000.0
	print(
		"%s: 20 m3 settled — script %d sweeps %.1f ms, native %d sweeps %.1f ms (%.1fx)"
		% [
			LABEL,
			sweeps_gd,
			ms_gd,
			sweeps_native,
			ms_native,
			ms_gd / maxf(ms_native, 0.001),
		]
	)
	if sweeps_gd != sweeps_native:
		print(
			"%s: WARNING sweep counts differ (%d vs %d)"
			% [LABEL, sweeps_gd, sweeps_native]
		)


func _make_pair(dims: Vector3i) -> Dictionary:
	var native: Object = ClassDB.instantiate("GranularVoxelField")
	native.configure(dims, CELL)
	return {
		"gd": GranularVoxelFieldScript.create(dims, CELL),
		"native": native,
	}


func _fail(message: String) -> void:
	push_error(message)
	print("%s: FAIL - %s" % [LABEL, message])
	get_tree().quit(1)
