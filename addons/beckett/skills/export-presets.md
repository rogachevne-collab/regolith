# Exporting & feature tags — presets, CLI export, OS.has_feature, per-platform overrides

> `export_presets.cfg` defines per-platform presets; the agent edits it and runs `godot --headless --export-release`. Runtime code branches with `OS.has_feature(tag)`. Feature tags are case-sensitive and only resolve in EXPORTED builds, never the editor.

## Version note
- Server runs **4.6.2** (baseline 4.3+, recommend 4.4+). Confirm with `get_godot_version`; check APIs with `describe_class class=ProjectSettings` / `EditorExportPlatform`.
- **4.7**: Manage Export Templates can download **individual platform** templates (not the whole ~1 GB set); GDExtensions get their own Project Settings section. Both are editor conveniences — the `export_project` / `list_export_presets` tool flow is unchanged.
- **CLI flag rename (4.0):** old `--export` became `--export-release`; also `--export-debug`. CI must use the new names.
- **Headless / dedicated server (since 4.0):** any 4.x binary runs with `--headless` (display=headless, audio=Dummy) — no separate server build. Use the `dedicated_server` feature tag and/or `--headless`.
- **`ProjectSettings.get_setting_with_override()` (4.0):** the override-aware reader for `setting.feature` keys.
- **Patch packs (4.4):** `--export-patch` and `EditorExportPlatform.export_pack_patch/export_zip_patch` ship only changed/new files vs configured base packs.
- **Patch delta encoding (4.6):** patches can store only the changed portion of a resource, shrinking updates.

## Required setup
- **Export templates must match the engine version+build exactly** (here `4.6.2.stable`). Install via Editor > Manage Export Templates… (TPZ from the official download page). Missing/mismatched templates make export fail.
- **A preset must exist** before CLI export: Project > Export > Add…, or a hand-written `[preset.N]` block in `export_presets.cfg`, with a `platform` and `export_path`.
- **Non-resource files** (.json/.txt/.csv) only ship if listed in `include_filter`; otherwise only recognized resources are packed.
- **Runtime mod/DLC loading:** mount packs in an autoload's `_init()` via `ProjectSettings.load_resource_pack`; declare the autoload in `[autoload]` of `project.godot`.
- **Script/PCK encryption requires custom-compiled templates** built with env `SCRIPT_AES256_ENCRYPTION_KEY` (exactly 64 hex chars); official prebuilt templates cannot encrypt. Then set the preset's custom template paths + `encryption_include_filters`.
- **Secrets:** gitignore `export_credentials.cfg` (holds `script_encryption_key`, store passwords); commit `export_presets.cfg`. Copy credentials to CI manually.

## OS (singleton) — runtime feature queries
- `has_feature(name: String) -> bool` — true if the tag is present in the running instance. Case-sensitive. C#: `OS.HasFeature`. **Custom tags resolve only in exported builds, never the editor.**
- `get_name() -> String` — coarse OS name: `"Windows"`, `"macOS"`, `"Linux"`, `"Android"`, `"iOS"`, `"Web"` (also `"FreeBSD"`/`"NetBSD"`/`"OpenBSD"`/`"BSD"`).
- `get_cmdline_user_args() -> PackedStringArray` — only args after a lone `--`; use to detect e.g. a `--server` startup flag.
- `is_debug_build() -> bool` (const) — true for a **debug export template OR when running in the editor**; false for a release template. (For "is this an exported build at all", prefer `has_feature("template")`.)

## Feature tags (standard, case-sensitive)
- **Platform:** `windows`, `macos`, `linuxbsd`, `linux`, `bsd`, `android`, `ios`, `web` (+ `web_windows`/`web_macos`/`web_linuxbsd`/`web_android`/`web_ios`).
- **Build type:** `debug`, `release`, `editor`, `editor_hint`, `editor_runtime`, `template`, `template_debug`, `template_release`. (`editor` = running in the editor; `template` = an exported build.)
- **Category:** `pc`, `mobile`, `web`.
- **Architecture:** `64`, `32`; `x86_64`, `x86_32`, `arm64`, `arm32`, `arm`, `rv64`, `wasm64`, `wasm32`, `wasm`, … (Web reports `wasm32`).
- **Precision / threading:** `single`, `double`; `threads`, `nothreads`.
- **Texture compression (only these three are feature tags):** `etc`, `etc2`, `s3tc`. (BPTC and ASTC are VRAM texture *formats*, not `OS.has_feature` tags.)
- **Special:** `dedicated_server`, `movie`, `shader_baker`.
- **Custom:** added per preset via the Features tab / `custom_features` in the cfg; apply only to exported builds.

## ProjectSettings (singleton) — overrides & extra packs
- `get_setting_with_override(name: StringName) -> Variant` — honors `name.feature` overrides for the active build's tags. **Use this**, not `get_setting`.
- `get_setting(name: String, default_value: Variant = null) -> Variant` — IGNORES feature overrides (returns base value).
- `load_resource_pack(pack: String, replace_files: bool = true, offset: int = 0) -> bool` — mounts a .pck/.zip onto `res://`; `offset` skips a header. Call in autoload `_init()`, not `_ready()`.
- Per-feature override key form in `project.godot`: `section/subsection/setting.feature = value` (no quotes on the suffix), e.g. `display/window/size/viewport_width.web=1280`.

## export_presets.cfg fields (the file the agent edits)
- `[preset.N]`: `name="…"`; `platform="Windows Desktop"|"Linux"|"macOS"|"Web"|"Android"|"iOS"`; `runnable=true/false`; `dedicated_server=true/false`; `custom_features=""`; `export_path=""`; `include_filter=""`; `exclude_filter=""` (comma-separated globs vs `res://` paths); `encryption_include_filters=""`; `encrypt_pck=false`; `encrypt_directory=false`.
- `export_filter` string values (cfg tokens — stable): `all_resources` | `scenes` (selected scenes+deps) | `resources` (selected resources+deps) | `exclude` (all except checked) | `customized` (per-file Keep / Strip Visuals / Remove).
- `[preset.N.options]`: platform keys, e.g. `binary_format/embed_pck=true/false`, `custom_template/release` & `/debug`, application metadata, codesign fields.

## EditorExportPlatform (editor-only) — programmatic export alternative
`export_project(preset, debug, path, flags=0, notify=true) -> Error`, `export_pack(preset, debug, path, flags=0) -> Error`, `export_zip(...)`, `export_pack_patch(preset, debug, path, patches: PackedStringArray=[], flags=0) -> Error` (4.4+), `save_pack(preset, debug, path, embed: bool=false) -> Dictionary`. Editor context only; `Error` enum, `OK==0`.

## Recipe — headless Windows release export via CLI
```
get_godot_version                       # confirm 4.6.2 → templates must be 4.6.2.stable
read_script path=res://export_presets.cfg     # inspect existing presets (if any)
# write export_presets.cfg with:
#   [preset.0] name="Windows" platform="Windows Desktop" runnable=true
#     export_filter="all_resources" export_path="build/win/game.exe"
#   [preset.0.options] binary_format/embed_pck=false
# then export (path is PROJECT-relative, quote the preset name):
ctx_shell command="godot --headless --path E:/best/godot-mcp --export-release \"Windows\" build/win/game.exe"
# verify build/win/game.exe + game.pck exist. Data-only: --export-pack "Windows" build/win/game.pck
```

## Recipe — branch at runtime by feature tag (server vs client, debug overlay)
```
write_script path=res://boot.gd content="extends Node
func _ready():
    if OS.has_feature(\"dedicated_server\") or DisplayServer.get_name() == \"headless\":
        _start_server()
    else:
        _start_client()
    if OS.has_feature(\"debug\"):           # true in editor + --export-debug, false in release
        add_child(preload(\"res://debug_overlay.tscn\").instantiate())
"
validate_script path=res://boot.gd
attach_script target=/root/Main path=res://boot.gd
play_scene                                  # NOTE: custom tags are FALSE here — test them in a real export
```

## Recipe — per-platform ProjectSettings override
```
# In project.godot (or set_setting + ProjectSettings.save()):
#   display/window/size/viewport_width=1920
#   display/window/size/viewport_width.web=1280
#   display/window/size/viewport_width.mobile=720
write_script path=res://res.gd content="extends Node
func _ready():
    var w = ProjectSettings.get_setting_with_override(\"display/window/size/viewport_width\")
    # 1280 in a Web export, 720 on mobile, else 1920; get_setting() would always give 1920
    print(w)
"
attach_script target=/root/Main path=res://res.gd
```

## Common traps
- **`export_filter` per-file mode token is `customized`, not `customize`** — writing the wrong token is not parsed.
- **Custom feature tags are FALSE in the editor** even with a Runnable preset — `OS.has_feature("my_tag")` only works in an actual export. Test custom-tag logic in a built binary.
- **`get_setting()` ignores `.feature` overrides** — use `get_setting_with_override()` to read per-feature values.
- **Dedicated server visual stripping:** choose the **"Export as dedicated server"** mode on the Resources tab (exposes per-file Keep / Strip Visuals / Remove). Strip Visuals replaces textures/meshes with dimension-preserving placeholders so code reading texture size still works. Detect at runtime with `OS.has_feature("dedicated_server")` or `DisplayServer.get_name() == "headless"`.
- **Files/folders starting with `.` are NEVER exported** (keeps `.git`/`.import` out) — don't rely on dotfiles shipping.
- **`include_filter` is required to ship non-resource files** (.txt/.json/.csv); plain assets Godot doesn't recognize as resources are otherwise dropped.
- **Encryption needs custom-compiled templates** (env `SCRIPT_AES256_ENCRYPTION_KEY`, 64 hex chars); prebuilt templates can't. The key ships in the binary, so this is obfuscation, not strong DRM.
- **`load_resource_pack` must run before its assets are needed** — call it in an autoload `_init()`, not `_ready()`, or preloads fail. `replace_files=true` (default) lets a mod/patch override base files.
- **CLI output path is relative to the project dir** (where `project.godot` lives), NOT the shell CWD — pass `--path` when scripting. Preset names with spaces need quotes.
- **`embed_pck` (Windows) caps the combined exe at ~3.89 GB.** Without embedding you ship the exe + a sidecar `.pck` of the same base name.
- **Templates must match the build exactly** (`4.6.2.stable`); a mismatch makes export silently fail or error.
- **Patch packs only carry files changed vs the listed base pack(s)** — configure base packs (Patches tab / `patches` PackedStringArray) or the patch is empty.
- **2D vs 3D:** exporting is platform/build-wide and identical for both; only the texture-compression *format* picked per platform differs (and BPTC/ETC2 are unavailable on macOS, S3TC unavailable on mobile/Web).

Confirm exact class, property, and method names with `describe_class` (and `get_godot_version`) before relying on them — export APIs and option keys shift between Godot versions.
