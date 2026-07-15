# Saving & loading data — persist game state to user://

> FileAccess / JSON / ConfigFile / ResourceSaver+Loader / DirAccess. Always write to user://; res:// is read-only in exports.

## Required setup
- **Write to `user://`, never `res://`.** res:// lives in the packed .pck and is read-only at runtime in an exported game — writing there may seem to work in the editor but fails after export. user:// is auto-created and guaranteed writable.
- Real path at runtime: `OS.get_user_data_dir()` or `ProjectSettings.globalize_path("user://")`.
- Optional for shipping: set `application/config/use_custom_user_dir` (bool) = true and `application/config/custom_user_dir_name` (String) in Project Settings for a clean per-game folder.
- Custom Resource saves need a script with `class_name` + `@export` vars so fields serialize; register the class_name so the type resolves on load.
- For a global save API, autoload a `SaveManager.gd` via Project Settings > Globals/Autoload, then call `/root/SaveManager`.

## Version note
- **Renamed in 4.0:** `File` -> `FileAccess`, `Directory` -> `DirAccess`. 3.x `File.new().open()` / `Directory.new()` no longer compile — use static `FileAccess.open()` / `DirAccess.open()`.
- **`ResourceSaver.save` argument order changed in 4.0** to `save(resource, path)` — reversed from 3.x `save(path, resource)`. Common porting bug.
- **JSON in 4.0:** static `JSON.stringify()` / `JSON.parse_string()` replaced 3.x `to_json()`/`parse_json()`; the `JSONParseResult` struct is gone (use instance `parse()` + `.data`, or static `parse_string()`).
- **`JSON.from_native` / `JSON.to_native` were added in 4.4** (NOT 4.3) — convert engine types (Vector2, Color, Transform) to/from JSON-safe values. On 4.3 and older you must split such types into components by hand.

Check with `get_godot_version` / `describe_class class=JSON`.

## Classes & key methods (confirm signatures with describe_class)
- **`FileAccess`** (RefCounted) — raw I/O; auto-closes when freed.
  - `static open(path, flags: ModeFlags) -> FileAccess` — returns **null** on failure; then call `static get_open_error() -> Error`.
  - `static file_exists(path) -> bool`, `static get_file_as_string(path) -> String`, `static get_file_as_bytes(path) -> PackedByteArray` (one-shot, no open/close).
  - `store_var(value: Variant, full_objects=false) -> bool` / `get_var(allow_objects=false) -> Variant` — binary serialize native types (Vector2/Color/Dictionary/Array) preserving exact types. Flags must match.
  - `store_string(s)`, `store_line(s)`, `get_as_text(skip_cr=false) -> String`, `get_line()`, `eof_reached() -> bool`.
  - Encrypted: `static open_encrypted_with_pass(path, flags, pass: String)`, `static open_encrypted(path, flags, key: PackedByteArray, iv=PackedByteArray())` (AES-256, 32-byte key).
  - `close()`, `flush()` — data flushes on close/free; flush() forces a write without closing.
- **`JSON`** (Resource) — `static stringify(data, indent="", sort_keys=true, full_precision=false) -> String` (pass `"\t"` to pretty-print); `static parse_string(json) -> Variant` (null on error); instance `parse(text) -> Error` then read `.data`, with `get_error_line()`/`get_error_message()`.
- **`ConfigFile`** (RefCounted) — `set_value(section, key, value)`, `get_value(section, key, default=null)`, `save(path) -> Error`, `load(path) -> Error`, `has_section_key(section, key)`, `get_sections()`, `get_section_keys(section)`. Encrypted variants: `save_encrypted_pass`/`load_encrypted_pass`.
- **`ResourceSaver`** — `static save(resource: Resource, path="", flags: BitField[SaverFlags]=0) -> Error`. Use `.res` (binary) for shipped saves, `.tres` (text) for debugging.
- **`ResourceLoader`** — `static load(path, type_hint="", cache_mode: CacheMode=1) -> Resource`, `static exists(path, type_hint="") -> bool`.
- **`DirAccess`** — `static dir_exists_absolute(path) -> bool`, `static make_dir_absolute(path) -> Error`, `static open(path) -> DirAccess` (null on failure), `get_files() -> PackedStringArray`, `get_directories()`. Cannot be used via `.new()`.

## Enums / option values
- `FileAccess.ModeFlags`: `READ=1`, `WRITE=2` (creates/truncates), `READ_WRITE=3` (file must exist), `WRITE_READ=7` (creates/truncates, then readable).
- `ResourceLoader.CacheMode`: `CACHE_MODE_IGNORE=0`, `CACHE_MODE_REUSE=1` (default), `CACHE_MODE_REPLACE=2`. Use **IGNORE** for save files so an updated file on disk is re-read.
- `ResourceSaver.SaverFlags` (BitField): `FLAG_NONE=0`, `FLAG_COMPRESS=32`, ... combine with `|`.
- `@GlobalScope.Error`: `OK=0` plus codes (`ERR_FILE_NOT_FOUND`, `ERR_FILE_CANT_OPEN`); compare returns against `OK`.

## Recipe — JSON save/load via an autoload SaveManager (inspectable)
```
write_script path=res://SaveManager.gd content="""
extends Node
const PATH := "user://savegame.json"
func save_game(data: Dictionary) -> void:
    var f := FileAccess.open(PATH, FileAccess.WRITE)
    if f == null:
        push_error(FileAccess.get_open_error()); return
    f.store_string(JSON.stringify(data, "\t"))
    f.close()
func load_game() -> Dictionary:
    if not FileAccess.file_exists(PATH):
        return {}
    var result = JSON.parse_string(FileAccess.get_file_as_string(PATH))
    return result if result is Dictionary else {}
"""
# register res://SaveManager.gd as autoload "SaveManager" in Project Settings > Globals
call_method target=/root/SaveManager method=save_game args=[{"level": 7, "hp": 100, "inventory": ["sword","shield"]}]
```
Note: JSON returns all numbers as floats (saved `7` -> `7.0`) — cast with `int()` on load. To verify: `play_scene`, trigger save, then re-`load_game` and `assert_node_state`.

## Recipe — typed binary save (preserves Vector2/int exactly)
```
write_script path=res://BinSave.gd content="""
extends Node
const PATH := "user://save.dat"
func save_state(state: Dictionary) -> void:
    var f := FileAccess.open(PATH, FileAccess.WRITE)  # or open_encrypted_with_pass(PATH, FileAccess.WRITE, "pw")
    f.store_var(state, false); f.close()
func load_state() -> Dictionary:
    if not FileAccess.file_exists(PATH): return {}
    var f := FileAccess.open(PATH, FileAccess.READ)
    var d = f.get_var(false); f.close(); return d
"""
```

## Recipe — Resource player save + ConfigFile settings
```
write_script path=res://SaveGame.gd content="""
class_name SaveGame extends Resource
@export var coins := 0
@export var player_position := Vector2.ZERO
@export var inventory: Array[String] = []
"""
# ensure folder, then save (note resource,path order) and load with a fresh read:
call_method target=/root/SaveManager method=... # DirAccess.make_dir_absolute("user://saves") if not dir_exists_absolute
# ResourceSaver.save(save_game, "user://saves/slot1.res")
# var sg = ResourceLoader.load("user://saves/slot1.res", "", ResourceLoader.CACHE_MODE_IGNORE)
```

## Common traps
- `FileAccess.open()` returns **null** on failure and does NOT throw — always null-check and read `FileAccess.get_open_error()`.
- JSON has only a float number type: integers round-trip as floats (`7` -> `7.0`); cast `int()` or use `store_var`/Resources for int-heavy data.
- JSON cannot store Vector2/Color/Transform as typed values — use `JSON.from_native`/`to_native` (**4.4+**) or split into components manually on 4.3-.
- `store_var(value, full_objects)` and `get_var(allow_objects)` must use matching flags. Keep both **false** for untrusted/shared data — `true` deserializes Objects and is a code-execution risk.
- Loading `.tres`/`.res` from an untrusted source can execute arbitrary code (resources may embed scripts). For cloud/shared saves use JSON or `store_var(allow_objects=false)`, never `ResourceLoader.load`.
- `ResourceSaver.save(resource, path)` — argument order, not `(path, resource)`.
- Reloading a Resource without `CACHE_MODE_IGNORE` returns the stale cached instance instead of disk data.
- `ConfigFile` section/key **names** cannot contain spaces (truncated at the space); values are fine. Mutations are memory-only until you call `save()`.
- 2D vs 3D save/load is identical — only property types differ (Vector2 vs Vector3/Transform3D). `store_var` and Resource `@export` handle both natively.

Always confirm exact method names, signatures, and enum values with `describe_class` (e.g. `describe_class class=FileAccess`) before relying on them.
