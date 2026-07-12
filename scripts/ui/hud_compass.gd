extends Control
## Top-centre compass ribbon. Presentation only: derives heading from the camera
## aim basis (North = -Z, East = +X, clockwise) and draws a scrolling tape. Never
## writes to any transform. Cardinal letters: N / В / Ю / З (latin N kept as the
## internationally recognised North marker, Cyrillic for the rest — noted in spec).

const RIBBON_WIDTH := 360.0
const TOP := 22.0
const HALF_SPAN_DEG := 60.0        # degrees visible each side of centre
const CARDINALS := {0: "N", 90: "В", 180: "Ю", 270: "З"}

var _camera: Camera3D
var _font: Font
var _heading := 0.0


func setup(ctx: Dictionary) -> void:
	_camera = ctx.get("camera")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = get_theme_default_font()
	if _font == null:
		_font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	if _camera == null:
		return
	var heading := _current_heading()
	if absf(_short_delta(heading, _heading)) > 0.05:
		_heading = heading
		queue_redraw()


func _current_heading() -> float:
	var basis: Basis
	if _camera.has_method("aim_transform"):
		basis = (_camera.call("aim_transform") as Transform3D).basis
	else:
		basis = _camera.global_transform.basis
	var forward := -basis.z
	var deg := rad_to_deg(atan2(forward.x, -forward.z))
	return fposmod(deg, 360.0)


func _short_delta(a: float, b: float) -> float:
	return fposmod(a - b + 180.0, 360.0) - 180.0


func _draw() -> void:
	if _font == null:
		return
	var cx := size.x * 0.5
	var half := RIBBON_WIDTH * 0.5

	# Baseline.
	draw_line(
		Vector2(cx - half, TOP),
		Vector2(cx + half, TOP),
		Color(HudTokens.COL_DIM, 0.35),
		1.0
	)

	# Ticks + cardinal glyphs across the visible span.
	var start := int(floor(_heading - HALF_SPAN_DEG))
	var end := int(ceil(_heading + HALF_SPAN_DEG))
	for a: int in range(start, end + 1):
		if a % 15 != 0:
			continue
		var norm := fposmod(float(a), 360.0)
		var delta := _short_delta(norm, _heading)
		if absf(delta) > HALF_SPAN_DEG:
			continue
		var x := cx + delta / HALF_SPAN_DEG * half
		var major := int(norm) % 45 == 0
		var tick_len := 8.0 if major else 4.0
		draw_line(
			Vector2(x, TOP),
			Vector2(x, TOP + tick_len),
			Color(HudTokens.COL_DIM, 0.7 if major else 0.4),
			1.0
		)
		if CARDINALS.has(int(norm)):
			_draw_centered(CARDINALS[int(norm)], x, TOP + 24.0, 13, HudTokens.COL_TITLE)

	# Centre marker (cyan) + heading readout.
	draw_line(
		Vector2(cx, TOP - 6.0),
		Vector2(cx, TOP + 10.0),
		HudTokens.COL_VALID,
		1.0
	)
	var heading_deg := int(round(_heading)) % 360
	_draw_centered("%03d°" % heading_deg, cx, TOP + 44.0, 15, HudTokens.COL_TEXT)


func _draw_centered(text: String, cx: float, y: float, font_size: int, color: Color) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(
		_font,
		Vector2(cx - w * 0.5, y),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		color
	)
