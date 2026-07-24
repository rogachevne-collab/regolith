# Control Axes v0 — continuous seat routing (first slice)

Статус: implementation contract для непрерывного вождения с `ControlSeat`.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` («ControlSeat и Binding»);
- `docs/specs/CONTROL-ACTIONS-V0.md` (дискретные глаголы / per-seat toggles);
- `docs/specs/ROVER-MODULES-V1.md` (колёса, parking brake, settle-freeze);
- `docs/specs/POC-THRUSTERS-V0.md` (thruster/gyro consumers).

## Цель

Отделить **физические** input actions (`project.godot`) от **semantic**
continuous channels, которые читают wheel / thruster / gyro consumers. Первый
срез — hardcoded router без UIC и без произвольного remapping.

```text
InputMap strengths (gateway)
        |
        v
SeatInputRouter  +  SeatControlState (per-seat policy)
        +  parking_brake (latched, assembly-wide)
        |
        v
SeatInputFrame  (ephemeral, not serialized)
        |
        v
AssemblyLocomotionController.apply_driver_frame  (one writer / tick)
        |
        +--> wheel tick (drive / brake / steer + gates)
        +--> thruster projection (translate + gates)
        +--> gyro projection (attitude + gates + latched dampeners)
```

## Semantic channels (`SeatInputFrame`)

| Поле | Диапазон | Consumer |
|---|---|---|
| `drive_command` | −1..1 | wheels |
| `steering_command` | −1..1 | wheels (steerable only) |
| `brake_command` | 0..1 | wheels (service brake) |
| `translate_command` | Vector3 −1..1 body-local | thrusters |
| `pitch_command`, `yaw_command`, `roll_command` | −1..1 | gyros |
| `wheels_route_enabled` … | bool | effective gate per consumer |

Body axes: x = right, y = up, **−z = forward** (Godot).

## Hardcoded axis map (v0)

Router не знает про capabilities assembly — только policy + raw strengths.

| Physical input | Raw key | Wheels (if `control_wheels`) | Thrusters (if `control_thrusters`) | Gyros (if `control_gyros`) |
|---|---|---|---|---|
| W / S | `move_forward` / `move_back` | drive ± | `translate.z` | — |
| A / D | `move_left` / `move_right` | steer ± | `translate.x` | — |
| Space | `jump` ∪ `move_up` → `space` | `brake_command` | `translate.y` up | — |
| C | `move_down` | — | `translate.y` down | — |
| Mouse X/Y (FP) | `look_x` / `look_y` | — | — | yaw / pitch |
| Q / E | `roll_left` / `roll_right` | — | — | roll |
| P | edge `toggle_parking_brake` | latched PB (policy: wheels ON) | — | — |
| Z | edge `toggle_dampeners` | latched dampeners assembly-wide | same | same |

**Space fan-out:** при включённых wheels и thrusters одно нажатие Space даёт
service brake на колёса **и** vertical translate на thrusters — без mutex
«flight vs drive».

**Parking brake:** assembly-wide safety latch. При latched PB router публикует
`drive=0`, `steer=0`, `brake=1` **даже если** `control_wheels=false` (pilot
channels gated, hold остаётся). Consumer: pilot drive/steer/service-brake
только при `wheels_route_enabled`; PB hold всегда. См. settle-freeze в
`ROVER-MODULES-V1.md`.

**Modal UI:** открытый терминал / панель → `zero_frame`: continuous channels
= 0, route gates сохраняются → latched dampeners продолжают гасить по
включённым consumers.

## Per-seat policy vs assembly latched state

| State | Scope | Command / UI |
|---|---|---|
| `control_wheels`, `control_thrusters`, `control_gyros` | per `ControlSeat` `element_id` | `configure_seat_controls`; terminal faceplate toggles |
| `parking_brake`, `dampeners` | per assembly | P / Z edges в gateway; не per-seat |

Effective gates копируются в locomotion каждый тик; consumers **must** suppress
manual force/torque **and** dampening when their gate is off
(`ThrusterSimulationService`, wheel tick, gyro projection).

## Границы v0

### Входит

- `SeatInputRouter`, `SeatInputFrame`, `SeatControlState`;
- gateway tick → `apply_driver_frame`;
- hardcoded table выше;
- one active seat writer per assembly.

### Вне scope (явно)

- UIC / arbitrary player remapping;
- multi-channel bindings (один key → несколько semantic targets);
- concurrent dual-pilot / co-driver seats;
- per-thruster enable groups (latched thruster on/off — отдельно, не route);
- Control Graph / autopilot continuous axes (общий locomotion writer позже).

## Acceptance

1. Hybrid rover+thrusters: W drives wheels **and** translates when both routes ON.
2. Space: brake + lift одновременно при обоих routes ON.
3. `control_gyros=false`: mouse не крутит craft; thrusters не затронуты.
4. Gate off: нет manual thrust **и** нет linear dampening thrusters; latched
   `dampeners` on assembly сохраняется.
5. Parking brake / settle-freeze — поведение из `ROVER-MODULES-V1.md` без регрессии.
