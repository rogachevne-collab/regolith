# Audio — players, buses, effects, adaptive music

> Play sounds with AudioStreamPlayer*, route and mix through AudioServer buses (INDEX-based), add effects, and drive adaptive/procedural streams.

## Version note
- Server runs **4.6.2** (baseline 4.3+, recommend 4.4+). Confirm with `get_godot_version` / `describe_class`.
- Godot 3→4: `AudioStreamSample`→**`AudioStreamWAV`** (renamed 4.0), `AudioStreamOGGVorbis`→`AudioStreamOggVorbis`. Old AI snippets often use the 3.x names.
- **`volume_linear`** on all players + `AudioServer.set_bus_volume_linear`/`get_bus_volume_linear`: **added 4.4** (absent in 4.3 — use `@GlobalScope.linear_to_db()` there).
- Adaptive streams `AudioStreamInteractive`/`AudioStreamSynchronized`/`AudioStreamPlaylist`, `AudioEffectHardLimiter`, and `playback_type` (sample/web): **added 4.3** (absent 4.0–4.2).
- `AudioStreamGenerator.mix_rate_mode` enum: **added 4.4**. Polyphonic honoring the player's `pitch_scale`: fixed **4.5.2**.

## Players
- `AudioStreamPlayer` — non-positional (music, UI). Has `mix_target` (MixTarget: STEREO=0 first channel, SURROUND=1, CENTER=2) — the 2D/3D variants do NOT.
- `AudioStreamPlayer2D` — positional in **pixels**: `max_distance` (float, default **2000**), `attenuation` (curve exponent, default 1.0), `panning_strength`.
- `AudioStreamPlayer3D` — positional in **meters**, different props (no `attenuation` float): `unit_size` (10.0), `max_db` (3.0), `attenuation_model` (AttenuationModel: INVERSE_DISTANCE=0, INVERSE_SQUARE_DISTANCE=1, LOGARITHMIC=2, DISABLED=3), `max_distance` (0.0 = no cutoff), `doppler_tracking` (DISABLED/IDLE_STEP/PHYSICS_STEP), `emission_angle` (45°). **2D and 3D attenuation are NOT interchangeable.**
- Shared props: `stream` (an `AudioStream` — loaded `.ogg`/`.wav`/`.mp3`), `volume_db` (0 = full, -80 = silent), `volume_linear` [4.4], `pitch_scale` (1.0), `autoplay`, `bus` (bus **name**), `playing`, `max_polyphony` (int, **default 1** — raise to let repeated `play()` calls layer), `playback_type` [4.3, Experimental].
- Methods: `play(from_position := 0.0)` (start time in **SECONDS**, not a stream index — single-stream player has no name overload), `stop()`, `seek(sec)`, `get_stream_playback()` (returns null until `play()` called), `has_stream_playback()`.
- Signal: **`finished()`** on all three (essential for freeing dynamically spawned one-shots). Setting `stream` stops any audio currently playing on that player.

## Looping (per-stream-resource, NOT on the player)
AudioStreamPlayer has no `loop`. Set it on the stream resource:
- `AudioStreamWAV` — `loop_mode` (LoopMode: DISABLED=0, FORWARD=1, PINGPONG=2, BACKWARD=3) + `loop_begin`/`loop_end`. WAV has **no BPM metadata** (can't beat-sync interactive music).
- `AudioStreamOggVorbis` / `AudioStreamMP3` — `loop` (bool) + `loop_offset` (float). Both expose static `load_from_buffer()` / `load_from_file()` to build streams at runtime.

## Buses (mixing) — AudioServer (a singleton; target by class name)
Buses are global. **Only `get_bus_index("Music")` takes a name** (Master is 0); every other call takes an **integer index** that shifts when buses are added/moved — resolve fresh each time, never cache.
- Layout: `add_bus(at_position)`, `set_bus_name(idx, "Music")`, `set_bus_send(idx, "Master")`, `remove_bus(idx)`.
- Mix: `set_bus_volume_db(idx, db)`, `set_bus_volume_linear(idx, lin)` [4.4], `set_bus_mute(idx, true)`, `set_bus_solo(idx, true)`.
- Effects: `add_bus_effect(idx, effect)`, `get_bus_effect(idx, i)`, `get_bus_effect_instance(idx, i)` (runtime instance for reading data).

## Bus effects (concrete classes only)
`AudioEffectReverb`, `AudioEffectDelay`, `AudioEffectChorus`, `AudioEffectCompressor`, `AudioEffectDistortion`, `AudioEffectPanner`, `AudioEffectPitchShift`.
- **Limiter:** `AudioEffectHardLimiter` (`ceiling_db` default -0.3, `pre_gain_db`, `release`). `AudioEffectLimiter` is **deprecated [4.3] — use AudioEffectHardLimiter**.
- **EQ/Filter are ABSTRACT** — cannot instantiate. Use `AudioEffectEQ6`/`EQ10`/`EQ21`; and `AudioEffectLowPassFilter`/`HighPassFilter`/`BandPassFilter`/`NotchFilter`/`HighShelfFilter`/`LowShelfFilter`/`BandLimitFilter`.
- **Analysis/IO:** `AudioEffectSpectrumAnalyzer` (read magnitudes via `AudioEffectSpectrumAnalyzerInstance` from `get_bus_effect_instance`); `AudioEffectCapture` / `AudioEffectRecord` — require ProjectSettings `audio/driver/enable_input = true` plus OS mic permission.

## Overlapping & adaptive streams (set as a player's `stream`)
- `AudioStreamPolyphonic` (`polyphony` default 32) + `AudioStreamPlaybackPolyphonic`: many voices through one node. `var pb = player.get_stream_playback()`; `var id = pb.play_stream(sfx, 0.0, 0.0, 1.0)` → int (INVALID_ID=**-1** on overflow); `pb.stop_stream(id)`, `set_stream_volume(id, db)`, `set_stream_pitch_scale(id, s)`.
- `AudioStreamRandomizer`: random pick with `random_pitch`/`random_volume_offset_db`; `playback_mode` (PLAYBACK_RANDOM_NO_REPEATS=0, RANDOM=1, SEQUENTIAL=2); `add_stream()`/`set_stream()`.
- `AudioStreamInteractive` [4.3] — clip transition table; drive via `AudioStreamPlaybackInteractive.switch_to_clip_by_name()`.
- `AudioStreamSynchronized` [4.3] — vertical layering, `MAX_STREAMS=32`, `set_sync_stream_volume(idx, db)` per layer, `get_stream_count()`.
- `AudioStreamPlaylist` [4.3] — sequential/`shuffle`, `loop` (default true), `fade_time` (0.3), `MAX_STREAMS=64`. Adaptive/beat-sync needs OGG/MP3 (BPM); WAV lacks it.
- `AudioStreamGenerator` (`mix_rate`, `buffer_length`; `mix_rate_mode` [4.4]) + `AudioStreamGeneratorPlayback`: each frame `while pb.get_frames_available() > 0: pb.push_frame(Vector2(s, s))` (or `push_buffer(PackedVector2Array)`). Push enough per frame to avoid skips (`get_skips()`).

## Listeners & area routing
- Listener defaults: **2D** = screen center unless an `AudioListener2D` is current; **3D** = the current `Camera3D` unless an `AudioListener3D.make_current()` overrides.
- `Area2D`/`Area3D` with `audio_bus_override = true` + `audio_bus_name` reroute contained players to e.g. a reverb bus (gated by `audio_bus_mask`).
- A player's `bus` must match an existing bus **name** or audio silently falls back to Master.

## Required setup
- No autoload needed; AudioServer is always available. Default buses live in `default_bus_layout.tres` (ProjectSettings `audio/buses/default_bus_layout`).
- **Web/HTML5:** set `playback_type` to `AudioServer.PLAYBACK_TYPE_SAMPLE` [4.3] (or ProjectSettings `audio/general/default_playback_type.web`); `AudioServer.register_stream_as_sample()` pre-registers. Caveat: SAMPLE ignores realtime bus effects and mid-play pitch/volume changes — use STREAM when those matter. Still **Experimental** in 4.6.
- Recording/mic capture needs `audio/driver/enable_input = true`.

## Recipe — music player routed to a Music bus, looping
```
call_method target=AudioServer method=add_bus args=[1]
call_method target=AudioServer method=set_bus_name args=[1,"Music"]
create_node type=AudioStreamPlayer name=Music parent=<root>
set_resource target=Music property=stream resource=res://music/theme.ogg
set_property target=Music/stream property=loop value=true          # OGG/MP3 loop bool
set_property target=Music property=bus value="Music"
set_property target=Music property=autoplay value=true
play_scene
```

## Recipe — 0..1 UI volume slider on the Music bus (4.4+)
```
write_script path=res://vol.gd content="extends HSlider
func _ready():
    min_value = 0.0; max_value = 1.0; value = 1.0
    value_changed.connect(_on_changed)
func _on_changed(v):
    var idx = AudioServer.get_bus_index(\"Music\")   # resolve fresh
    AudioServer.set_bus_volume_linear(idx, v)        # 4.4+; pre-4.4 use set_bus_volume_db(idx, linear_to_db(v))
"
attach_script target=<the HSlider> path=res://vol.gd
```

## Recipe — overlapping SFX through one polyphonic player + master limiter
```
create_node type=AudioStreamPlayer name=Sfx parent=<root>
set_resource target=Sfx property=stream class=AudioStreamPolyphonic
call_method target=AudioServer method=add_bus_effect args=[0, "<AudioEffectHardLimiter instance>"]
# then in script: var pb = $Sfx.get_stream_playback(); var id = pb.play_stream(load("res://hit.wav"))
```

## Common traps
- **Bus calls are index-based** except `get_bus_index()` — passing a name to `set_bus_volume_db` etc. fails. Indices move; re-resolve after any layout change.
- **`play(x)` x is SECONDS**, not a stream id; the basic player plays its single `stream` only — use `AudioStreamPolyphonic`/`Randomizer` for variety/overlap, or raise `max_polyphony`.
- **Looping is on the stream resource**, not the player: WAV `loop_mode`, OGG/MP3 `loop`. WAV has no BPM → can't beat-sync.
- **Tweening `volume_db` to/from `-inf` breaks** — tween `volume_linear` [4.4] or clamp the dB floor (e.g. -60).
- `AudioEffectEQ`/`AudioEffectFilter` are **abstract** — instantiate `EQ6`/`EQ10`/`EQ21` and the concrete filter subclasses. `AudioEffectLimiter` is deprecated → `AudioEffectHardLimiter`.
- A wrong/empty `bus` name silently routes to Master. `get_stream_playback()` is null before the first `play()`.
- **2D vs 3D:** 2D = pixels + `attenuation` curve; 3D = meters + `unit_size`/`max_db`/`attenuation_model` (no `attenuation` float). Only the non-positional player has `mix_target`.
- SAMPLE `playback_type` (web) ignores realtime bus effects and live pitch/volume — use STREAM for those.
- Free one-shot players on the **`finished()`** signal, or spawned voices leak.

Confirm exact class, property, method, and enum names with `describe_class` / `find_methods` (and `get_godot_version`) before relying on them — audio APIs shifted across 4.x.
