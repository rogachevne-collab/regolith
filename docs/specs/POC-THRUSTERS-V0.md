# Thrusters + Gyro v0 — Flight PoC

Статус: implementation contract для lunar hop / VTOL без орбитальной механики.

Родительские документы:

- `docs/PHYSICAL-LANGUAGE.md` («Actuator», «Gyro», «ControlSeat и Binding»);
- `docs/specs/SIMULATION-KERNEL-V0.md`;
- `docs/specs/INDUSTRY-V1.md`;
- `docs/specs/ROVER-MODULES-V1.md` (ControlSeat / locomotion pattern);
- `docs/CONCEPT.md` (орбитальная механика не ядро; hop/VTOL допустимы).

## Цель

Добавить элементные `Thruster` и `Gyro` в языке Assembly:

- игрок ставит thruster / gyro как обычные construction items;
- сила и момент идут через Jolt (`apply_force` / `apply_torque`), не через joints;
- electric on/off budget из Industry v1 гасит тягу без питания;
- ControlSeat на assembly с thruster даёт flight bindings (тяга + attitude + dampeners);
- критерий: собрать hopper, взлететь, перелететь десятки метров, сесть.

Это реализация уже определённых в `PHYSICAL-LANGUAGE.md` понятий «сила в точке»
(двигатель) и `Gyro`. Новая параллельная модель механики не вводится.

## Нормативные решения

1. Thruster и Gyro — **element-scoped Actuator**, не `SimulationJoint`. Ближе к
   колесу (роль + projection tick), чем к поршню/ротору.
2. Симуляция владеет throttle / attitude command / power demand / status.
   Jolt владеет позой, скоростью и результатом сил.
3. `thrust_axis_face` — направление **силы на корпус** (реакция). Сопло визуально
   противоположно оси.
4. Все thruster на одной activated assembly читают общий
   `translate_command` (body-local 6DOF); каждый thruster стреляет по
   alignment своей оси. Дифференциальные группы — вне v0.
5. Все gyro на assembly делят `pitch_command` / `yaw_command` / `roll_command`
   (−1..1) и флаг `dampeners`. Каждый gyro вносит долю момента
   `command * max_torque_nm / gyro_count` (равномерно).
6. Dampeners: при нулевом attitude input gyro гасит `angular_velocity` до
   `max_torque_nm` (пропорциональный демпфер). Не отдельная SAS-система.
7. Mobile assembly = locomotive (колёса) **или** flight (есть operational thruster).
   Seat entry и unfreeze работают для обоих.
8. Орбита, multi-body solar system, fuel mass flow, atmosphere drag — вне v0.

## Границы

### Входит

- `ThrusterDefinition` / `GyroDefinition` на `ElementArchetype`;
- archetypes `thruster`, `gyro`, `landing_leg` (Support / посадочная нога);
- assembly flight fields на `AssemblyLocomotionController`;
- projection tick: thruster `apply_force`, gyro `apply_torque`;
- electric consumer + `dynamic_power_w` от throttle / attitude;
- ControlSeat flight bindings;
- kernel tests: validate, flight detection, power demand, force/torque math;
- demo hopper spawn с 4 landing legs для ручной проверки в игре.

### Не входит

- орбитальная механика и point-gravity flight (см. `MOON-EXPERIMENT-V0`);
- fuel / oxidizer mass flow (только electric budget);
- programmable bindings / automation UI;
- per-thruster override и thrust vectoring joints;
- ion/hydrogen variants, afterburner;
- LCD / in-world thrust readout;
- retractable landing gear / powered legs;
- замена legacy `scripts/launch_vehicle.gd` (остаётся изолированным демо).

### Landing leg

`landing_leg` — placeable `Support` под палубой:

- высокий `max_integrity` (посадочный расходник, не fragile thruster);
- collider-«стопа» у низа клетки — ниже центра thruster, бьётся о грунт первой;
- terrain impact damage × `K_LANDING_GEAR` (мягче обычного `K_DAMAGE`);
- без actuator/joint — жёсткая нога, не подвеска ровера.

## Authoring

### ThrusterDefinition

```text
ThrusterDefinition {
  thrust_axis_face      # OrientationUtil.Face — сила на корпус
  max_thrust_n          # SI, > 0
  power_draw_w          # при throttle = 1
  idle_w                # ≥ 0
  nozzle_offset_local   # м в element frame; точка apply_force
}
```

Validator отклоняет: неположительный thrust/power, non-finite offset, отсутствующий
archetype.

### GyroDefinition

```text
GyroDefinition {
  max_torque_nm         # SI, > 0
  power_draw_w          # при |attitude| = 1 или dampeners active
  idle_w
  dampen_gain           # N·m / (rad/s), > 0
}
```

## Runtime

### AssemblyLocomotionController (flight fields)

```text
translate_command  # Vector3 body-local −1..1 (x=right, y=up, z=forward)
pitch_command      # -1..1  (local +X torque)
yaw_command        # -1..1  (local +Y)
roll_command       # -1..1  (local +Z)
dampeners          # bool, default true
```

Существующие wheel fields сохраняются. Snapshot включает flight fields.
Legacy `thrust_command` в snapshot читается как `translate.y`.

### Power

- Thruster `dynamic_power_w = power_draw_w * |translate_command|` (clamped ≤ 1).
- Gyro `dynamic_power_w = power_draw_w * max(|pitch|,|yaw|,|roll|, dampeners? 0.25 : 0)`.
- Без `runtime.powered` сила/момент = 0, status reason `no_power`.

### Projection (каждый physics frame)

Для каждого operational thruster на activated flight assembly:

1. `throttle = max(0, axis_local · desired) * |desired|`, где `desired` =
   `translate_command`, или при нулевом translate и dampeners —
   `−normalize(v_local)` (linear dampen).
2. `thrust_n = max_thrust_n * throttle` если powered.
3. `apply_force` в точке сопла вдоль axis.

Для gyro:

1. Собрать command torque в **body local** (pitch→X, yaw→Y, roll→Z).
2. Если dampeners и command ≈ 0: `τ = clamp(-ω_local * dampen_gain, ±max)`.
3. Иначе `τ = command * max_torque_nm / gyro_count`.
4. `apply_torque(body_basis * τ)`.

## ControlSeat bindings (SE-like)

Когда assembly — flight (`is_flight_assembly`) и seat occupied:

| Input action | Command |
|---|---|
| `move_forward` / `move_back` | `translate.z` (±forward) |
| `move_left` / `move_right` | `translate.x` (±strafe) |
| `move_up` / `move_down` | `translate.y` (Space / C) |
| mouse X / Y (FP, not orbit) | `yaw` / `pitch` |
| `roll_left` / `roll_right` | `roll` (Q / E) |
| `toggle_dampeners` | toggle `dampeners` (Z) |

Orbit camera (`toggle_vehicle_camera` / V): freelook вокруг craft, мышь не рулит.

Если assembly одновременно locomotive (колёса) **и** flight: flight bindings
побеждают (WASD = translate, не drive). Parking brake остаётся на `P`.

Seat entry разрешён для `is_mobile_assembly` = locomotive ∨ flight.

## Acceptance

1. Kernel: archetype validate; flight detection; power demand scales with throttle;
   `compute_thrust_force` / `compute_gyro_torque` unit-stable.
2. In-game: demo hopper взлетает на 1.62 g, летит ≥ 20 м по горизонтали, садится
   без немедленного кувырка при dampeners on.
3. Без питания thruster не поднимает craft (`no_power`).
4. `./tests/run_tests.sh` зелёный.

## Лестница после v0

1. Mode switch wheel/flight на hybrid.
2. Per-thruster groups / differential.
3. Fuel Store + mass flow.
4. Moon experiment + point gravity hop.
