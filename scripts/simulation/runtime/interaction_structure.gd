class_name InteractionStructure
extends RefCounted
## Topology-stable aim/HUD identity for one element (Interaction Read-Model).
## Owned by InteractionIndex; callers must not mutate fields.

var element_id := 0
var assembly_id := 0
var archetype_id := ""
var topology_revision := 0
var roles: PackedStringArray = PackedStringArray()
var driven_joint_id := 0
var driven_joint_kind := -1
var control_seat := false
var wheel_element_id := 0
var suspension_element_id := 0
## Authored / max clamps from archetype definitions (piston/rotor/hinge/wheel).
var authored: Dictionary = {}
## ActuatorDisplayPose: seed on rebuild; push+Hz from ActuatorSimulationService.
var display_pose_m := 0.0
var display_actuator_status: StringName = &""
var display_at_rest := true
