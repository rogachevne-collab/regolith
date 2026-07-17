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
4. Все thruster на одной activated assembly получают один assembly-level
   `thrust_command` (0..1). Дифференциальная тяга — вне v0.
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
- archetypes `thruster`, `gyro`;
- assembly flight fields на `AssemblyLocomotionController`;
- projection tick: thruster `apply_force`, gyro `apply_torque`;
- electric consumer + `dynamic_power_w` от throttle / attitude;
- ControlSeat flight bindings;
- kernel tests: validate, flight detection, power demand, force/torque math;
- demo hopper spawn для ручной проверки в игре.

### Не входит

- орбитальная механика и point-gravity flight (см. `MOON-EXPERIMENT-V0`);
- fuel / oxidizer mass flow (только electric budget);
- programmable bindings / automation UI;
- per-thruster override и thrust vectoring joints;
- ion/hydrogen variants, afterburner;
- LCD / in-world thrust readout;
- замена legacy `scripts/launch_vehicle.gd` (остаётся изолированным демо).

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
thrust_command   # 0..1
pitch_command    # -1..1  (local +X torque sense)
yaw_command      # -1..1  (local +Y)
roll_command     # -1..1  (local +Z)
dampeners        # bool, default true
```

Существующие wheel fields сохраняются. Snapshot включает flight fields.

### Power

- Thruster `dynamic_power_w = power_draw_w * thrust_command` при activated seat
  и powered; иначе 0 (+ idle через Industry profile).
- Gyro `dynamic_power_w = power_draw_w * max(|pitch|,|yaw|,|roll|, dampeners? 0.25 : 0)`.
- Без `runtime.powered` сила/момент = 0, status reason `no_power`.

### Projection (каждый physics frame)

Для каждого operational thruster на activated mobile assembly:

1. `thrust_n = max_thrust_n * thrust_command` если powered, иначе 0.
2. World axis = body basis · element basis · face_vector(thrust_axis_face).
3. Offset = body · (element_local_origin + element_basis · nozzle_offset_local)
   − body.origin.
4. `RigidBody3D.apply_force(axis * thrust_n, offset)`; wake body.

Для gyro:

1. Собрать command torque в **body local** axes (pitch→X, yaw→Y, roll→Z).
2. Если dampeners и command ≈ 0: `τ = clamp(-ω_local * dampen_gain, ±max)`.
3. Иначе `τ = command * max_torque_nm` (с делением на число gyro).
4. `apply_torque(body_basis * τ)` на rigid body группы элемента.

## ControlSeat bindings (v0)

Когда assembly — flight (`is_flight_assembly`) и seat occupied:

| Input action | Command |
|---|---|
| `jump` | `thrust_command` |
| `move_forward` / `move_back` | `pitch_command` |
| `move_left` / `move_right` | `roll_command` |
| `yaw_left` / `yaw_right` | `yaw_command` |
| `toggle_parking_brake` | toggle `dampeners` |

Если assembly одновременно locomotive (колёса):

- WASD остаётся wheel drive/steer;
- `jump` = thrust (не brake);
- brake только через `toggle_parking_brake` + остановку, как у ровера;
- attitude (pitch/yaw/roll) = 0, пока нет отдельного mode switch (вне v0).

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
