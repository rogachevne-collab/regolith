## Full-edition only — the Max-tier violet pixel shimmer for the AI-Effort bar.
##
## This module is trimmed from the free Lite package by pack.ps1 (Lite caps AI effort at L4
## and never reaches the top tier, so it has no shimmer) and is loaded by panel.gd ONLY when
## present (ResourceLoader.exists). Keeping the algorithm in its own file is what guarantees it
## never ships in the public Lite source — panel.gd holds nothing but a null reference there.
##
## Owns all shimmer animation state; panel.gd drives it via set_top()/tick()/draw()/invalidate().
extends RefCounted

var _t := 0.0
var _top_since := -1.0
var _fade := 0.0
var _was_top := false
var _cells: Array = []
var _cells_w := -1.0


## Called on every effort-level change: start the spread reveal when stepping up into the top
## tier, reset it otherwise. The opacity itself eases in tick().
func set_top(is_top: bool) -> void:
	if is_top and not _was_top:
		_top_since = _t
	elif not is_top:
		_top_since = -1.0
	_was_top = is_top


## Advance the animation and ease opacity toward 1 at the top tier, 0 elsewhere. Returns true
## while a redraw is needed (animating, or twinkling while held at the top tier).
func tick(delta: float, is_top: bool) -> bool:
	_t += delta
	var target := 1.0 if is_top else 0.0
	if _fade != target:
		_fade = move_toward(_fade, target, delta / (0.45 if target > 0.0 else 0.65))
		return true
	return is_top


func needs_draw() -> bool:
	return _fade > 0.001


## Force a rebuild of the pixel grid (e.g. the bar resized).
func invalidate() -> void:
	_cells_w = -1.0


## Map a 0..1 pixel brightness onto the violet shimmer ramp (dim mauve -> bright lilac).
func _px_color(b: float) -> Color:
	return Color(0.28 + b * 0.52, 0.26 + b * 0.47, minf(1.0, 0.47 + b * 0.53), 0.16 + b * 0.84)


## Draw the violet pixel field onto `bar` (called from the bar's draw signal). Solid on the
## right, thinning from the 45% mark to a faint ghost grid on the left; every cell twinkles,
## with a wave that amplifies each cell's own twinkle sweeping right->left. Entering / at the
## top tier (is_top) spreads from the thumb; leaving it clears to the right of the node (thumb_x)
## and fades the left *toward* the node as opacity drops.
func draw(bar: Control, w: float, ty: float, th: float, thumb_x: float, es: float, is_top: bool) -> void:
	_build_cells(w, ty, th, thumb_x, es)
	var reveal := 1.0
	if _top_since >= 0.0:
		reveal = clampf((_t - _top_since) / 0.8, 0.0, 1.0)
		reveal = 1.0 - pow(1.0 - reveal, 3.0)
	var max_d := maxf(maxf(thumb_x, w - thumb_x), 1.0)
	var exiting := not is_top
	var span := maxf(thumb_x, 30.0 * es)
	for cell in _cells:
		if not exiting and float(cell["d"]) > reveal * max_d:
			continue
		var sh := 0.5 + 0.5 * sin(_t * float(cell["sp"]) + float(cell["ph"]))
		var wavep := pow(0.5 + 0.5 * sin(_t * 3.0 + float(cell["xf"]) * 9.0), 1.3)
		var b: float
		if bool(cell["on"]):
			var twk := 0.4 if sin(_t * 0.8 + float(cell["tw"]) * 9.0) > 0.93 else 0.0
			var steady := float(cell["base"]) * (0.8 + 0.2 * sh) + twk
			b = clampf(steady + float(cell["base"]) * wavep * sh * 0.9, 0.0, 1.0)
		else:
			b = clampf((0.06 + 0.05 * sh) * (1.0 + wavep * sh * 2.0), 0.0, 1.0)
		var col := _px_color(b)
		col.a *= (clampf((thumb_x - float(cell["x"])) / span, 0.0, 1.0) * _fade if exiting else _fade)
		bar.draw_rect(Rect2(float(cell["x"]), float(cell["y"]), float(cell["s"]), float(cell["s"])), col)


## Build (and cache) the pixel cells for the current bar width — a fixed seed so the dither is
## stable across redraws; rebuilt only when the bar resizes (cells_w changes).
func _build_cells(w: float, ty: float, th: float, thumb_x: float, es: float) -> void:
	if not _cells.is_empty() and absf(_cells_w - w) < 0.5:
		return
	_cells_w = w
	_cells = []
	var cell := maxf(3.0, 3.0 * es)
	var sz := cell - 1.0
	var cols := int(w / cell)
	var rows := maxi(2, int(th / cell))
	var offy := ty + (th - ((rows - 1) * cell + sz)) * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	for c in cols:
		for r in rows:
			var x := c * cell
			var y := offy + r * cell
			var cx := x + sz * 0.5
			var xf: float = cx / w
			var knee := 0.45
			var dens: float = 1.0 if xf >= knee else pow(xf / knee, 1.5)
			_cells.append({
				"x": x, "y": y, "s": sz, "xf": xf, "d": absf(cx - thumb_x),
				"on": rng.randf() < (0.07 + 0.93 * dens),
				"base": (0.72 + rng.randf() * 0.28) * (0.18 + 0.82 * dens),
				"ph": rng.randf() * TAU, "sp": 1.5 + rng.randf() * 2.3, "tw": rng.randf(),
			})
