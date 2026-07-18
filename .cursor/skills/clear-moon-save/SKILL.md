---
name: clear-moon-save
description: >-
  Clears Regolith moon world progress (player/build save + digs SQLite) while
  keeping the crust heightmap. Use when the user asks to clear/reset/wipe save,
  почистить сейв, сбросить прогресс, or fresh world start.
---

# Clear Moon Save

## When to use

- User asks to clear/reset/wipe the save or moon progress
- Phrases like «почисти сейв», «сбрось прогресс», «чистый мир»

Do **not** delete shader_cache, logs, or `crust_heightmap.exr` unless the user
explicitly asks for a full wipe including heightmap rebake.

## Command

From repo root:

```bash
./run.sh --headless --script res://scripts/tools/clear_moon_progress.gd
```

Script: `scripts/tools/clear_moon_progress.gd`.

## What it removes / keeps

| Path (under `user://moon_experiment/gen_vN/`) | Action |
|---|---|
| `world_save.json` | remove (assemblies, inventory, player pose) |
| `moon.sqlite` | remove (voxel digs / stream mods) |
| `crust_heightmap.exr` | **keep** (fast next launch) |
| `generator_version.txt` | keep |

macOS userdata mirror (for manual checks):

`~/Library/Application Support/Godot/app_userdata/Regolith/moon_experiment/`

## Agent workflow

1. `cd` to repo root
2. Run the command above (do not invent `rm` paths — use the script)
3. Confirm stdout contains `clear_moon_progress: removed …` or `no progress files`
4. Tell the user the next game launch starts a fresh world (heightmap reused)

## Notes

- Game must not be writing autosave during delete; if the game is running, stop
  it first or warn that it may rewrite the save on quit.
- Flat-yard legacy save `user://regolith_world_save.json` is separate; only clear
  it if the user is on `flat_moon` / explicitly asks for that path too.
