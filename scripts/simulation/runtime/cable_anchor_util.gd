class_name CableAnchorUtil
extends RefCounted
## Free-attach cable endpoints. A rope end is one of three things:
##   element_id > 0, port_id != ""  → legacy port link, anchor = port face;
##   element_id > 0, port_id == ""  → clipped anywhere on that block, the point
##                                    is stored in the block's body-group frame
##                                    so it rides the block;
##   element_id == 0                → nailed to the world (terrain, boulder),
##                                    the point is world-space.
## The rope has no placement requirements: any anchor connects to any other.

## Anchors closer than this are the same point — no rope to build.
const MIN_SPAN_M := 0.15
## Wheel knob: 0 — внатяг, 1 — болтается. Rest length interpolates between the
## two factors, so slack is resolution-independent and survives a save.
const SLACK_MIN := 0.0
const SLACK_MAX := 1.0
const SLACK_TIGHT_FACTOR := 1.0
const SLACK_LOOSE_FACTOR := 1.9
## One notch of the wheel. Fine on purpose — the difference between «внатяг» and
## «чуть провисает» is where the feel lives; hold Shift for a coarse sweep.
const SLACK_STEP := 0.01
const SLACK_COARSE_MULTIPLIER := 8
const DEFAULT_SLACK := 0.15


## World position of one rope end, whatever kind of anchor it is.
static func endpoint_world_position(
	world: SimulationWorld,
	element_id: int,
	port_id: String,
	attach: Vector3
) -> Vector3:
	if element_id <= 0 or world == null:
		return attach
	var element := world.get_element(element_id)
	if element == null:
		return attach
	if not port_id.is_empty():
		return IndustryElectricPortUtil.port_anchor_world_position(
			world,
			element,
			port_id
		)
	return world.element_group_transform(element_id) * attach


## World click → the frame the anchor is stored in.
static func localize(
	world: SimulationWorld,
	element_id: int,
	world_point: Vector3
) -> Vector3:
	if element_id <= 0 or world == null:
		return world_point
	if world.get_element(element_id) == null:
		return world_point
	return (
		world.element_group_transform(element_id).affine_inverse()
		* world_point
	)


## Unstretched rope length for a span pulled at the given slack setting.
static func rest_length_m(span_m: float, slack: float) -> float:
	return maxf(span_m, 0.0) * lerpf(
		SLACK_TIGHT_FACTOR,
		SLACK_LOOSE_FACTOR,
		clampf(slack, SLACK_MIN, SLACK_MAX)
	)


## Inverse, for HUD readouts on an existing rope.
static func slack_for_rest(span_m: float, rest_m: float) -> float:
	if span_m <= 0.000001:
		return DEFAULT_SLACK
	return clampf(
		inverse_lerp(
			SLACK_TIGHT_FACTOR,
			SLACK_LOOSE_FACTOR,
			rest_m / span_m
		),
		SLACK_MIN,
		SLACK_MAX
	)


static func step_slack(slack: float, steps: int) -> float:
	return clampf(
		slack + float(steps) * SLACK_STEP,
		SLACK_MIN,
		SLACK_MAX
	)
