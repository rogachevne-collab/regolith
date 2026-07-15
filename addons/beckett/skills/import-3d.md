# 3D asset import (glTF / FBX) — source files into Godot scenes, editor pipeline + runtime loading

> `ResourceImporterScene` converts `.glb/.gltf/.fbx/.dae/.obj/.blend` into a scene (Node3D/MeshInstance3D/Skeleton3D/AnimationPlayer) via a sibling `.import` settings file. At RUNTIME, load with `GLTFDocument`+`GLTFState` (FBX: `FBXDocument`+`FBXState`). **3D only** — no 2D import path.

## Version note
- Server runs **4.6.2** (baseline 4.3+, recommend 4.4+). Check `get_godot_version`; confirm every API with `describe_class`.
- **`GLTFDocument` / `GLTFState`** (runtime glTF load/export): since **4.0**. Compiled into exported games, no setup.
- **`FBXDocument` / `FBXState`** + built-in **ufbx** importer: since **4.3**, marked **EXPERIMENTAL** (API may shift). `.fbx` added in 4.3+ uses ufbx by default — no external FBX2glTF download. Files added in <=4.2 keep FBX2glTF until you switch `fbx/importer`.
- **`GLTFState.handle_binary_image_mode`** (`HandleBinaryImageMode` enum): the non-`MODE` names (`handle_binary_image`, `HANDLE_BINARY_*`) still exist but are **DEPRECATED** — use the `_MODE_` names below.
- `BoneMap` / `SkeletonProfileHumanoid` retargeting, `meshes/generate_lods`, `meshes/create_shadow_meshes`, vertex compression, `meshes/light_baking` UV2, `.blend` import, `EditorScenePostImport`: all **4.0**.
- Editor import options are **not** Godot 3 carryovers (`Spatial`->`Node3D`); the whole pipeline is 4.x-shaped.

## Required setup
- **glTF (.glb/.gltf):** nothing — import and runtime `GLTFDocument` work out of the box.
- **FBX via ufbx (4.3+):** no setup. Force on a pre-4.3 file: set `fbx/importer = 1` in its `.import`, reimport. Disable FBX entirely: ProjectSettings `filesystem/import/fbx/enabled`.
- **FBX via FBX2glTF (legacy):** download the executable, set ProjectSettings `filesystem/import/fbx2gltf/...` path.
- **`.blend`:** install official **Blender 3.0+** (3.5+ recommended), set ProjectSettings `filesystem/import/blender/...` path. Shells out to Blender; **not** on Android/Web editors; every teammate needs Blender.
- **OBJ "as Scene":** switch the file's importer to *OBJ as Scene* in the Import dock, then **RESTART the editor** for scene options to appear.
- No autoloads required for any import or runtime workflow.

## ResourceImporterScene — editor import options (the `.import` `[params]` keys)
Not a node and **NOT runtime properties** — you cannot change these with `set_property` on a loaded node. Edit the file's sibling `.import` `[params]` block (or Advanced Import Settings / an import script), then reimport.
- `nodes/root_type` (String, `""`->Node3D), `nodes/root_name` (String), `nodes/root_scale` (float, 1.0), `nodes/apply_root_scale` (bool, true), `nodes/root_script` (Script), `nodes/import_as_skeleton_bones` (bool, false), `nodes/use_name_suffixes` (bool, true), `nodes/use_node_type_suffixes` (bool, true).
- `meshes/ensure_tangents` (bool, true — Mikktspace, only if missing), `meshes/generate_lods` (bool, true), `meshes/create_shadow_meshes` (bool, true), `meshes/light_baking` (int, default 1 — sets each `GeometryInstance3D.gi_mode`; **Static Lightmaps** generates UV2 on import for `LightmapGI`), `meshes/lightmap_texel_size` (float, 0.2 — only with Static Lightmaps), `meshes/force_disable_compression` (bool, false).
- `skins/use_named_skins` (bool, true).
- `animation/import` (bool, true), `animation/fps` (float, 30 — match your DCC tool), `animation/trimming` (bool, false), `animation/remove_immutable_tracks` (bool, true), `animation/import_rest_as_RESET` (bool, false).
- `materials/extract` (int: 0 Keep Internal / 1 Extract Once / 2 Extract and Overwrite), `materials/extract_format` (int: 0 Text `.tres` / 1 Binary `.res` / 2 `.material`), `materials/extract_path` (String, ""->source folder).
- `import_script/path` (String -> `EditorScenePostImport` script), `_subresources` (Dictionary — per-node/mesh/material/animation overrides + animation slices from Advanced Import Settings).
- Format-specific keys (added by the active format importer, edited in the Import dock/Advanced dialog): `fbx/importer` (0 FBX2glTF / 1 ufbx), `retarget/bone_map`, `retarget/bone_renamer/rename_bones`, `retarget/rest_fixer/*`, embedded-image-handling and naming-version options. Confirm exact spellings in the dialog before scripting them.

## Runtime classes
- **`GLTFDocument`** (extends Resource): `append_from_file(path: String, state: GLTFState, flags := 0, base_path := "") -> Error`; `append_from_buffer(bytes: PackedByteArray, base_path: String, state: GLTFState, flags := 0) -> Error`; `append_from_scene(node: Node, state, flags := 0) -> Error`; `generate_scene(state, bake_fps := 30.0, trimming := false, remove_immutable_tracks := true) -> Node`; `generate_buffer(state) -> PackedByteArray`; `write_to_filesystem(state, path: String) -> Error`. Export props: `image_format` (String, "PNG"; None/PNG/JPEG/Lossless WebP/Lossy WebP), `lossy_quality` (float, 0.75), `root_node_mode` (`ROOT_NODE_MODE_SINGLE_ROOT=0` default / `KEEP_ROOT=1` / `MULTI_ROOT=2`).
- **`GLTFState`** (extends Resource): `base_path` (String — **set before `append_from_buffer`** so textures/buffers resolve), `bake_fps` (float, 30.0), `create_animations` (bool, true), `import_as_skeleton_bones` (bool), `handle_binary_image_mode` (`HandleBinaryImageMode`: `HANDLE_BINARY_IMAGE_MODE_DISCARD_TEXTURES=0` / `_EXTRACT_TEXTURES=1` default / `_EMBED_AS_BASISU=2` / `_EMBED_AS_UNCOMPRESSED=3`). Getters: `get_animations()`, `get_meshes()`, `get_materials()`, `get_images()`, `get_skins()`, `get_nodes()`, `get_scene_node(idx)`/`get_node_index(node)`.
- **`FBXDocument`** (extends GLTFDocument) + **`FBXState`** (extends GLTFState, `allow_geometry_helper_nodes: bool = false`): same method shapes; experimental, verify on engine.
- **`EditorScenePostImport`** (`@tool`, extends RefCounted): `_post_import(scene: Node) -> Object` (mutate the imported root, **return it**), `get_source_file() -> String`. Meshes here are **`ImporterMesh`** (pre-LOD), not `ArrayMesh` — call `ImporterMesh.generate_lods(normal_merge_angle, normal_split_angle, bone_transform_array)`.
- **`BoneMap`**: `profile` (SkeletonProfile — use **`SkeletonProfileHumanoid`** for humanoids) + per-bone name map; assigned via Retarget in Advanced Import Settings.

## Recipe — load a .glb at RUNTIME and add it to the scene
```
get_godot_version                                   # confirm 4.x (GLTFDocument needs 4.0+)
find_classes query=GLTFDocument
describe_class class=GLTFDocument inherited=true     # confirm signatures on THIS engine
describe_class class=GLTFState
write_script path=res://glb_loader.gd content="extends Node3D
func _ready():
    var doc := GLTFDocument.new()
    var state := GLTFState.new()
    var err := doc.append_from_file(\"res://models/robot.glb\", state)
    if err == OK:
        add_child(doc.generate_scene(state))
    else:
        push_error(\"glTF load failed: %s\" % error_string(err))
"
create_node type=Node3D name=ModelHost parent=.
attach_script target=ModelHost path=res://glb_loader.gd
create_node type=Camera3D name=Camera3D parent=.       # plus a DirectionalLight3D so it's visible
play_scene
wait_for_node path=ModelHost     # then get_remote_tree + screenshot to confirm; stop_scene
```

## Recipe — post-import script: add LODs / collision after import
```
write_script path=res://import_post.gd content="@tool
extends EditorScenePostImport
func _post_import(scene):
    _walk(scene)
    return scene                                   # MUST return the root
func _walk(n):
    if n is ImporterMeshInstance3D and n.mesh:
        n.mesh.generate_lods(25.0, 60.0, [])       # ImporterMesh, not ArrayMesh
    for c in n.get_children():
        _walk(c)
"
validate_script path=res://import_post.gd
# then set import_script/path="res://import_post.gd" in the file's .import [params] and reimport
```

## Common traps
- The editable sidecar is **`model.glb.import`** (next to the source). The cached scene/meshes live under **`.godot/imported/`** — never hand-edit or commit the cache; DO commit the source + `.import`.
- Import options are **not** runtime properties: to change *how* a file imports, edit its `.import` `[params]` (or Advanced Import Settings / `EditorScenePostImport`) then reimport. To change a model *at runtime*, load it with `GLTFDocument` instead.
- `append_from_buffer` does **NOT** set `base_path` — set `state.base_path` (or pass `base_path`) yourself or external textures/`.bin` vanish. `append_from_file` sets it automatically.
- Switching `fbx/importer` (FBX2glTF <-> ufbx) changes skeleton rest poses and can break `NodePath` refs / instanced-scene edits; it forces a reimport.
- `apply_root_scale = true` bakes scale into meshes/anims, so nodes you add later are **not** scaled; set `false` to keep scale on the root transform.
- Lightmap UV2 is generated at import **only** with `meshes/light_baking` = Static Lightmaps (or per-mesh in Advanced). Runtime-loaded glTF has no UV2 — call `ArrayMesh.lightmap_unwrap(transform, texel_size)` yourself.
- Mesh compression is ON by default; blocky normals/UVs or very large meshes -> `meshes/force_disable_compression = true`.
- `ensure_tangents` only generates tangents *if missing* — without them, normal/height maps render wrong; prefer exporting tangents from your DCC tool.
- OBJ loads as a **Mesh resource by default** (`load()` returns a Mesh for `MeshInstance3D.mesh`), with no skeletons/animation/UV2/PBR; use *OBJ as Scene* (+ editor restart) for scene options. Collada `.dae` is legacy — use glTF for animation/complex hierarchy.
- `EditorScenePostImport` must be `@tool`, extend `EditorScenePostImport`, and **return** the (modified) scene; meshes are `ImporterMesh` at that stage.
- 3D only — do not `create_node Sprite2D` for model import; glTF/FBX/OBJ have no 2D path. `FBXDocument`/`FBXState` are experimental on 4.3+.

Always confirm exact class, property, and method names with `describe_class` (and `get_godot_version`) before relying on them — import keys and runtime APIs shift across Godot versions.
