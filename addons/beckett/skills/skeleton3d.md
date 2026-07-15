# Skeleton3D, skinning & IK — armatures, the SkeletonModifier3D stack, ragdolls, retargeting

> A `Skeleton3D` is a `Node3D` holding a flat index-addressed bone array (rest + pose). Procedural pose tweaks (look-at, spring, IK, ragdoll) live in the **SkeletonModifier3D** child stack, which runs **after** the AnimationMixer.

## Version note
- Server runs **4.6.2** (baseline 4.3+). Confirm with `get_godot_version` / `describe_class`. Many members were renamed or deprecated across 4.3→4.6 — verify per-runtime.
- **4.3**: `SkeletonModifier3D` base + the child-node stack model + `Skeleton3D.modifier_callback_mode_process`. `PhysicalBoneSimulator3D` introduced; `physical_bones_start_simulation/stop_simulation/add_collision_exception/remove_collision_exception` **moved here from Skeleton3D** (those + `*_global_pose_override` + `animate_physical_bones` are now **deprecated** on Skeleton3D).
- **4.4**: `LookAtModifier3D`, `SpringBoneSimulator3D` + `SpringBoneCollision3D`, `RetargetModifier3D`. `SkeletonIK3D` marked **deprecated** (its `interpolation` superseded by `SkeletonModifier3D.influence`).
- **4.5**: `BoneConstraint3D` + `CopyTransformModifier3D` / `AimModifier3D` / `ConvertTransformModifier3D`. `_process_modification()` deprecated in favor of `_process_modification_with_delta(delta)`.
- **4.6**: full IK family — `TwoBoneIK3D`, `ChainIK3D`, `SplineIK3D`, `IterateIK3D` + `FABRIK3D` / `CCDIK3D` / `JacobianIK3D` (under `IKModifier3D`), plus `LimitAngularVelocityModifier3D`, `BoneTwistDisperser3D`. `BoneConstraint3D` references can target a `Node3D` (`REFERENCE_TYPE_NODE`).
- **2D is a separate system**: `Skeleton2D` + `Bone2D` + the resource-based `SkeletonModificationStack2D` (CCDIK / FABRIK / LookAt / TwoBoneIK / Jiggle) — **NOT** SkeletonModifier3D.

## Required setup
- No autoloads or project settings needed — these are core nodes. Skinned meshes come from **import** (glTF recommended, or FBX): the importer builds the `Skeleton3D`, `Skin`, and `MeshInstance3D.skeleton`/`skin` links. You rarely hand-author binds.
- **Registration is structural, not a flag**: a modifier must be a **direct child** of the `Skeleton3D`; a `PhysicalBone3D` a child of `PhysicalBoneSimulator3D`; a `SpringBoneCollision3D` a child of `SpringBoneSimulator3D`. Misplaced = silently ignored.
- Gate 4.4 features (LookAt/SpringBone/Retarget) behind `get_godot_version >= 4.4`; BoneConstraint3D >= 4.5; the IK family / LimitAngularVelocity / BoneTwistDisperser >= 4.6.
- Ragdolls: every simulated bone needs a `PhysicalBone3D` (+ `CollisionShape3D` child) under a `PhysicalBoneSimulator3D` — generate via the editor's Skeleton3D toolbar > **Create Physical Skeleton**. Set the skeleton's `modifier_callback_mode_process` to PHYSICS.

## Skeleton3D (extends Node3D)
Properties: `motion_scale` (float, 1.0 — scales position-track animation), `show_rest_only` (bool, false — force rest pose, ignore poses/modifiers), `modifier_callback_mode_process` (`ModifierCallbackModeProcess`: PHYSICS=0, **IDLE=1 default**, MANUAL=2).
Bone array: `get_bone_count() -> int`, `find_bone(name: String) -> int` (-1 if absent), `add_bone(name) -> int` (names cannot contain `:` or `/`), `get_bone_name(idx)`/`set_bone_name(idx,name)`, `get_bone_parent(idx)`/`set_bone_parent(idx, parent_idx)` (**parent index MUST be < child index**), `get_bone_children(idx) -> PackedInt32Array`, `get_parentless_bones() -> PackedInt32Array`.
Pose (current): `get_bone_pose(idx) -> Transform3D`/`set_bone_pose(idx, Transform3D)`, `get/set_bone_pose_position(idx, Vector3)`, `get/set_bone_pose_rotation(idx, Quaternion)`, `get/set_bone_pose_scale(idx, Vector3)`, `get_bone_global_pose(idx) -> Transform3D` / `set_bone_global_pose(idx, Transform3D)` (**SKELETON space, NOT world**).
Rest (bind): `get_bone_rest(idx)`/`set_bone_rest(idx, Transform3D)`, `get_bone_global_rest(idx)`, `reset_bone_pose(idx)`, `reset_bone_poses()`.
Misc: `is_bone_enabled(idx)`/`set_bone_enabled(idx, enabled := true)`, `get_version() -> int` (increments on hierarchy change), `force_update_bone_child_transform(idx)`, `create_skin_from_rest_transforms() -> Skin`, `register_skin(skin: Skin) -> SkinReference`. `force_update_all_bone_transforms()` is **internal-use / discouraged**.
Signals: `skeleton_updated()` (after the **whole modifier stack** finished — best hook to read final transforms), `pose_updated()`, `bone_enabled_changed(idx)`, `bone_list_changed()`, `rest_updated()`.

## SkeletonModifier3D (abstract base, 4.3, extends Node3D)
`active` (bool, true), `influence` (float, 1.0 — 0..1 blend over the incoming pose). `get_skeleton() -> Skeleton3D`. Override `_process_modification_with_delta(delta)` (4.5+) for a custom modifier. Signal `modification_processed()`. Defines the `RotationAxis` and `BoneDirection` enums that subclasses reuse.
**Execution rules (official)**: modifiers run only as DIRECT CHILDREN of the skeleton; processing order = child order; the whole stack runs **after** the AnimationMixer applies its pose, so a modifier **overrides** the animated pose for its bones.

## Key modifier subclasses
- **PhysicalBoneSimulator3D** (4.3) — ragdoll. `physical_bones_start_simulation(bones: Array[StringName] = [])` (empty = ALL; pass names for partial ragdoll), `physical_bones_stop_simulation()`, `is_simulating_physics() -> bool`, `physical_bones_add/remove_collision_exception(RID)`. Tree: Skeleton3D > PhysicalBoneSimulator3D > **PhysicalBone3D** (one per bone; `bone_name`, `joint_type` `JointType` NONE=0/PIN=1/CONE=2/HINGE=3/SLIDER=4/6DOF=5, `mass`, `apply_central_impulse(Vector3)`, `apply_impulse(impulse, position)`).
- **LookAtModifier3D** (4.4) — aim ONE bone. `bone_name`/`bone`, `forward_axis` (`BoneAxis`, set to the model's real forward), `primary_rotation_axis` (`Axis`), `target_node` (NodePath), `origin_from` (`OriginFrom`: SELF=0/SPECIFIC_BONE=1/EXTERNAL_NODE=2), `duration` (float, 0=instant), `transition_type`/`ease_type` (reuse `Tween.TransitionType`/`EaseType`), `use_angle_limitation`, `primary_limit_angle`. `is_target_within_limitation() -> bool`.
- **SpringBoneSimulator3D** (4.4) — hair/cloth/tail jiggle, index-based settings (each a **linear** chain). `set_setting_count(int)`, `reset()`, per chain `i`: `set_root_bone_name(i,name)`, `set_end_bone_name(i,name)`, `set_center_from(i, CenterFrom)` (WORLD_ORIGIN=0/NODE=1/**BONE=2**), `set_center_bone_name(i,name)`, `set_stiffness(i,f)`, `set_drag(i,f)`, `set_gravity(i,f)`, `set_radius(i,f)`, `set_rotation_axis(i, SkeletonModifier3D.RotationAxis)`, `set_enable_all_child_collisions(i,bool)`. `external_force` (Vector3, wind). Colliders = `SpringBoneCollision3D` children (Sphere `{radius, inside}` / Capsule `{radius, height, inside}` / Plane).
- **RetargetModifier3D** (4.4) — runtime pose transfer to a child skeleton via `profile` (SkeletonProfile). `use_global_pose` (bool), `set_position_enabled/set_rotation_enabled/set_scale_enabled(bool)` (often rotation-only to avoid stretching).
- **BoneConstraint3D** (4.5) family — `CopyTransformModifier3D` / `AimModifier3D` / `ConvertTransformModifier3D`. Index-based: `set_setting_count(int)`, per setting `set_apply_bone`, `set_reference_bone`, `set_amount`. `ReferenceType`: BONE=0, **NODE=1** (4.6, reference a Node3D in model space).
- **IKModifier3D** family (4.6) — `TwoBoneIK3D` (analytic limbs; pole via `set_pole_node`/`set_pole_direction`), `ChainIK3D`, `SplineIK3D`, and `IterateIK3D` -> `FABRIK3D`/`CCDIK3D`/`JacobianIK3D`. Shared base: `mutable_bone_axes`, `set_setting_count(int)`, `clear_settings()`, `reset()`. **`SkeletonIK3D` is deprecated** — use these instead.

## Skinning & retargeting resources
- `Skin` (Resource): `add_bind(bone: int, pose: Transform3D)`, `add_named_bind(name, pose)`, `get/set_bind_bone(i)`, `get/set_bind_pose(i)`. `SkinReference` (RefCounted) is the runtime handle from `register_skin` (`get_skin()`, `get_skeleton()`).
- `BoneMap` (Resource): maps a profile's standard names to a rig's actual names. `profile` (SkeletonProfile), `get_skeleton_bone_name(profile_name) -> StringName`, `set_skeleton_bone_name(profile_name, rig_name)`, `find_profile_bone_name(rig_name)`. Edited in the import dock (Retarget > BoneMap).
- `SkeletonProfile` / `SkeletonProfileHumanoid` (~56 standard humanoid bones): `bone_size`, `root_bone`, `scale_base_bone`, `find_bone(name)`, `get_reference_pose(idx)`, `get_handle_offset(idx) -> Vector2`, `is_required(idx)`, `get_tail_direction(idx)` (`TailDirection`: AVERAGE_CHILDREN=0/SPECIFIC_CHILD=1/END=2).
- **Two retargeting layers** (don't confuse): (a) import-time `BoneMap`+`SkeletonProfileHumanoid` renames/fixes bones once; (b) runtime `RetargetModifier3D` transfers live pose between skeletons.

## BoneAttachment3D (extends Node3D)
Pins a child subtree to one bone (weapon-in-hand, camera-on-head). `bone_name` (String), `bone_idx` (int, -1), `override_pose` (bool — when true, **writes** its transform into the bone, driving it), `use_external_skeleton` (bool) + `external_skeleton` (NodePath). `get_skeleton()`, `on_skeleton_update()`. Parent must be a Skeleton3D unless `use_external_skeleton`.

## Recipe — head bone looks at the player (4.4+ LookAtModifier3D)
```
get_godot_version                                          # confirm >= 4.4
describe_class class=LookAtModifier3D inherited=true        # confirm property names on this runtime
create_node type=LookAtModifier3D name=HeadLook parent=<path>/Skeleton3D   # MUST be a direct child
set_property target=<path>/Skeleton3D/HeadLook property=bone_name value=Head
set_property target=<path>/Skeleton3D/HeadLook property=forward_axis value=4   # match the model's real forward
set_property target=<path>/Skeleton3D/HeadLook property=target_node value=<NodePath to player>
set_property target=<path>/Skeleton3D/HeadLook property=duration value=0.25
set_property target=<path>/Skeleton3D/HeadLook property=use_angle_limitation value=true
set_property target=<path>/Skeleton3D/HeadLook property=primary_limit_angle value=80.0
play_scene
screenshot                                                 # if the head twists wrong, change forward_axis/primary_rotation_axis
call_method target=<path>/Skeleton3D/HeadLook method=is_target_within_limitation args=[]
```

## Recipe — full ragdoll on death (4.3+ PhysicalBoneSimulator3D)
```
# Editor: Skeleton3D toolbar > Create Physical Skeleton (makes PhysicalBoneSimulator3D + PhysicalBone3D + joints)
get_remote_tree                                            # verify the generated bodies
set_property target=<path>/Skeleton3D property=modifier_callback_mode_process value=0   # PHYSICS
call_method target=<path>/Skeleton3D/PhysicalBoneSimulator3D method=physical_bones_start_simulation args=[[]]   # [] = all bones
call_method target=<path>/Skeleton3D/PhysicalBoneSimulator3D method=is_simulating_physics args=[]
# recover: physical_bones_stop_simulation, then Skeleton3D.reset_bone_poses() and resume the AnimationPlayer
```

## Recipe — read a bone's world transform (any 4.x)
```
describe_class class=Skeleton3D inherited=false
call_method target=<path>/Skeleton3D method=find_bone args=[Head]            # -> idx
call_method target=<path>/Skeleton3D method=get_bone_global_pose args=[<idx>]  # SKELETON space, NOT world
# world = skeleton.global_transform * get_bone_global_pose(idx)
```

## Common traps
- A `SkeletonModifier3D` runs ONLY as a **direct child** of the Skeleton3D (not grandchild/sibling). Same for `PhysicalBone3D` and `SpringBoneCollision3D` under their simulators — misplaced nodes are silently ignored.
- Stack order = scene-tree child order, and the stack runs **after** the AnimationMixer — a modifier **overrides** the animated pose for its bones. Reorder children to pick the winner.
- `get_bone_global_pose()` is in **SKELETON space**, not world. Compose `skeleton.global_transform * get_bone_global_pose(idx)` for world (the classic hand-rolled BoneAttachment bug).
- Bone **parent index must be smaller than the child index**; `add_bone` before `set_bone_parent`. Names cannot contain `:` or `/`.
- Deprecated/moved in 4.3: `physical_bones_*` live on `PhysicalBoneSimulator3D`; `*_global_pose_override` + `animate_physical_bones` are deprecated — use `set_bone_global_pose` + `SkeletonModifier3D.influence`.
- `SkeletonIK3D` is **deprecated** — use `TwoBoneIK3D` (limbs) or `AimModifier3D` (simple aiming). Its `interpolation` is replaced by `influence`.
- Keep the Skeleton3D and bones **UNSCALED** with SpringBone — scaling breaks the sim. Set `CenterFrom` to BONE/NODE (not WORLD_ORIGIN) and call `reset()` after teleporting, or springs overshoot violently. SpringBone supports **linear chains only** — model branches (two pigtails) as separate settings.
- `LookAtModifier3D.forward_axis` must match the model's real bone forward, or the bone aims sideways. Use `is_target_within_limitation()` to avoid snapping past the cone.
- For ragdolls set `modifier_callback_mode_process` to **PHYSICS** (0); default IDLE jitters.
- `BoneAttachment3D.override_pose=true` writes the pose (competes with the stack) — for pose-driving prefer a real modifier (e.g. `CopyTransformModifier3D`) in 4.3+.
- 2D is separate: `Skeleton2D`/`Bone2D`/`SkeletonModificationStack2D` — there is no SpringBone/LookAtModifier in 2D.

Always confirm exact class names, property types, method signatures, and enum values with `describe_class` / `find_methods` (and `get_godot_version`) before relying on them — several skeleton APIs were renamed or deprecated across 4.3→4.6.
