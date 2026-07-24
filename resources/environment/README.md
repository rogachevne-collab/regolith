# Shared lunar environment

`moon_surface_env.tres` + `moon_camera_attributes.tres` are the single source of
truth for the surface look. `scenes/main.tscn` and `scenes/granular_corridor_test.tscn`
point at them; edit the files, every scene follows.

`.tres` comments are stripped by `ResourceSaver`, so the reasoning lives here.

## Project presentation (not in this .tres)

Owned by `project.godot` `[display]` / `[rendering]`:

| Setting | Value | Reason |
| --- | --- | --- |
| Window | 1920×1080 | Was 1280×720 — edges and terrain LOD read softer at low res |
| Screen-space AA | SMAA (`screen_space_aa=2`) | Cheap edge cleanup without MSAA cost |
| Debanding | on | Kills banding on sky / ambient gradients |

## Directional shadows (`main.tscn` sun)

Strategy: **sharp near / fade far**. One atlas cannot stay crisp at 1.5 km.

| Knob | Value | Reason |
| --- | --- | --- |
| `max_distance` | 576 | Was 1536; terrain `view_distance` is 512 — longer range only mush |
| `fade_start` | 0.8 | Distant shadows dissolve instead of hard cut / mushy edge |
| `shadow_blur` | 0.65 | Was 1.25; lunar sun has tiny angular size → harder penumbra |
| `normal_bias` | 1.25 | Was 2.5; less floaty contact after blur drop |
| splits | 0.03 / 0.10 / 0.28 | More texels on player / rover / build range |
| `blend_splits` | off | Long outdoor + blend → stripe shimmer on near casters |
| atlas `size` | 8192 | Project setting; more texels for the same cascades |

## What is set and why

| Block | Value | Reason |
| --- | --- | --- |
| Tonemap | ACES, exposure 1.0 | Deep blacks and a hard highlight shoulder — vacuum contrast. AgX was tried and read washed out: it lifts blacks and desaturates by design, which is the opposite of what a moon wants. |
| Auto exposure | **off** (wired, one command away) | Tried on, backed out. Godot meters average framebuffer luminance, and half of a lunar frame is black sky — the meter reads "dark", lifts the whole image, and sunlit ground blows out while shadows go grey. Revisit only if driven explicitly (e.g. enabled underground), not as a global. |
| Ambient | sky contribution **0.0**, energy **1.0** | Was 0.7 / 0.42, inherited from the old inline env. Sky contribution 0.7 against a black starfield throws away 70% of the fill for nothing, so ambient was effectively dead: 0.42 and 0.20 rendered identically, and at a low sun the shadowed half of the frame fell to pure black with zero detail. Fill now comes from `ambient_light_color` (bluish — it stands in for earthshine + regolith bounce). `DayNightCycle` rewrites the energy every frame, so the matching `day_ambient_energy` / `flat_*` overrides live on that node in `main.tscn` and `granular_corridor_test.tscn`. |
| SSIL | on, intensity 0.35 | Regolith albedo bounce into shadowed crater walls. Was 0.9 and made shadows read grey — on the Moon they should stay near black with just enough bounce to keep detail. **First thing to cut when GPU-bound.** |
| SSAO | unchanged from the old inline env | Already tuned; only `light_affect`/`ao_channel_affect` nudged off zero. |
| SSR | on, max_steps 48, fade_out 1.5 | Screen-space reflections for metallic frame panels / glass under hard sun. Matte regolith barely shows it. Half-res is the engine default. Console: `env_ssr`. No ReflectionProbe yet (open construction + moving spawn). |
| Glow | Screen blend (4.6+ default order: before tonemap), intensity 0.25, threshold 2.0, levels 4–5 | Vacuum has no atmospheric bloom, but the camera does. Threshold 1.4 + lifted exposure put the *whole sunlit ground* over the line and the screen washed out; at 2.0 only the sun disc and hot emitters cross it. Levels 4–5 = one broad soft halo instead of a tight ring. Was Additive; switched to Screen to match Godot 4.6+ glow-before-tonemap behaviour. |
| Fog | off | Vacuum. The distance haze in `flat_moon.tscn` is a deliberate non-physical exception, left alone. |
| SDFGI | off | Heaviest switch in the renderer, and the world streams. SSIL covers the near-field bounce that actually reads. |

Sun and ambient energies are **not** owned by this file — `DayNightCycle`
(`scripts/day_night_cycle.gd`) rewrites them every frame.

## Locked sun (temporary)

`main.tscn` and `granular_corridor_test.tscn` set `enabled = false` and
`noon_phase_offset = 0.13` on their `DayNightCycle` node. The cycle still aligns
to the spawn point on `_ready`, then stops — the light does not move.

Why the offset exists: `align_noon_above()` puts the sun at the local zenith,
which is the flattest light possible — no relief, no cast shadows, everything
one tone. Sweeping the offset against a frozen sun:

| offset | elevation | reads as |
| --- | --- | --- |
| 0.00 | ~80° | flat, no shadows — the old spawn look |
| 0.10 | ~44° | still soft |
| **0.13** | **~33°** | **lit working area + shadow band + bright far ridge** |
| 0.16 | ~22° | the ground under the player goes into shade |
| 0.19 | ~12° | half the frame is a void |
| −0.13 | ~33° | mirrored azimuth: front light, flat again |

Elevations are measured against world +Y at one spawn point. The offset is
relative to *local* noon, so on a sphere the same 0.13 reads ~10° differently
depending on where you land — a re-run measured 43°. That is inherent: a fixed
world-space sun would be wrong at every other longitude.

To hand the day back: `enabled = true` on the node. Keep the offset, it only
changes where the cycle starts.

## Tuning it with your eyes

The `WorldEnvironment` node carries `scripts/tools/environment_tuner.gd`. Open the
console (backtick) in a running game:

```
env_preset aces | agx | filmic | neutral
env_exposure 1.0
env_glow 1 0.2 2.0
env_ssil 1 0.35
env_ssao 1 0.65
env_grade 1.08 1.05
env_ambient 0.42 0.7
env_sun 1.55
env_autoexposure 0
env_dump      # print live values as .tres text
env_save      # write live values back into these files
env_reload    # discard live edits
```

`filmic` restores the exact pre-change look for A/B. `neutral` (linear tonemap,
no grade, no glow) is the reference for judging raw albedo while authoring
materials — not a shippable look.

Two traps when tuning live, both hit during the pass that set these values:

- **Freeze the sun first.** `DayNightCycle` runs a 10-minute orbit, so two shots
  a minute apart are lit differently and any A/B between them is noise. Set
  `enabled = false` on the node, set `phase`, then call `_apply()`.
- **`env_ambient` writes to the cycle, not to the inspector.** The cycle
  overwrites `Environment.ambient_light_energy` every frame, so an inspector
  edit lasts one tick.

Useful phases: `0.0` ≈ 73° sun (flat, no relief), `0.08` ≈ 44° (typical),
`0.14` ≈ 23° (raking — this is the one that exposes a black-shadow floor).

## Scenes still carrying their own environment

Left alone because their values genuinely diverge, not by oversight:

- `flat_moon.tscn`, `test_kinetic_playground.tscn` — SDFGI + distance fog.
- `test_moon_5km_flat.tscn` — different ambient balance for the 5 km scale.
- `granular_playground.tscn`, `granular_voxel_playground.tscn`, `granular_cascade.tscn`,
  `bench_voxel_scale.tscn` — black-box lighting rigs for isolating the sim.
- `scenes/vfx/drill_impact_preview.tscn` — VFX-only rig.
