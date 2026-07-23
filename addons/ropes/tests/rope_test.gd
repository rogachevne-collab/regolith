extends SceneTree
# Shared harness for rope tests. Subclasses override run() and call check().
#
# Termination is the point of this file. A SceneTree script that returns
# without calling quit() keeps the engine spinning forever at full speed,
# which looks exactly like a hung test — we lost time to that once already.
# So quit() lives here, on the normal path, and the runner adds an OS-level
# timeout for the paths this file cannot reach (assert failures, crashes).

var failures := 0
var title := "TEST"

var _start_usec := 0


func _initialize() -> void:
	_start_usec = Time.get_ticks_usec()
	run()
	var elapsed := float(Time.get_ticks_usec() - _start_usec) / 1e6
	if failures == 0:
		print("%s: PASS (%.1fs)" % [title, elapsed])
	else:
		print("%s: FAIL — %d check(s) (%.1fs)" % [title, failures, elapsed])
	quit(0 if failures == 0 else 1)


## Subclasses implement this.
func run() -> void:
	print("harness: run() not implemented")
	failures += 1


## Compare a measured value against a reference. Pass abs_tol for quantities
## whose reference is zero or whose tolerance is naturally absolute.
func check(what: String, measured: float, reference: float, tol: float,
		abs_tol := false) -> bool:
	var err := absf(measured - reference)
	var ok := err <= tol
	var rel := ""
	if not abs_tol and reference != 0.0:
		rel = " (%.3f%%)" % (err / absf(reference) * 100.0)
	print("  %s %s: measured=%.6f expected=%.6f err=%s%s" %
			["PASS" if ok else "FAIL", what, measured, reference, err, rel])
	if not ok:
		failures += 1
	return ok


## Guard for any loop whose iteration count is not statically obvious.
func over_budget(seconds: float) -> bool:
	return float(Time.get_ticks_usec() - _start_usec) > seconds * 1e6
