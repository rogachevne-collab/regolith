#!/usr/bin/env bash
# Headless gate: pure simulation-logic tests (kernel, graphs, resources, topology).
# Gameplay/UI/presentation are verified in the running game, not here (AGENTS.md).
# Usage: tests/run_tests.sh [--all]
#   --all  also run legacy gameplay/physics integration scenes (slow, optional)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ONE="$ROOT/tests/run_one.sh"

KERNEL=(
	test_simulation_kernel
	test_simulation_runtime
	test_simulation_actuator
	test_interaction_index
	test_simulation_wheel
	test_control_actions
	test_seat_input_router
	test_simulation_thruster
	test_vehicle_power
	test_rover_compose
	test_machine_compose
	test_part_authoring
	test_connectors
	test_simulation_projection
	test_construction_preview
	test_construction_damage
	test_industry_ports
	test_industry_v1
	test_dozer_blade
	test_game_balance
	test_input_bindings
	test_ui_window_stack_input
	test_terrain_materials
	test_player_inventory_hotbar
	test_suit_state
	test_oxygen_survival
	test_connected_block_visual
	test_impact_destruction
	test_snapshot_replica
	test_coop_codec
	test_coop_seat
	test_coop_dig_replay
	test_coop_rope_projection
	test_coop_bug_regressions
	test_granular_patch
	test_granular_lens_scoop
	test_granular_sinter
	test_granular_field_persist
)

# DIG-01/02/03, COOP-04/05 fixed 2026-07-25 — test_coop_bug_regressions moved
# from red-lock manual-only into KERNEL above. See docs/BUG-HUNT-RC-2026-07-25.md
# and docs/_verify/DIG-COOP.md.
# Physics/gameplay/UI integration scenes. Not part of the gate: the running
# game is the verifier for that layer. Runnable via --all or run_one.sh.
EXTRA=(
	test_assembly
	test_character_controller
	test_construction_toolbar_remap
	test_hud_palette_layout
	test_player_interaction
)

SCENES=("${KERNEL[@]}")
if [[ "${1:-}" == "--all" ]]; then
	SCENES+=("${EXTRA[@]}")
fi

if [[ ! -x "$RUN_ONE" ]]; then
	chmod +x "$RUN_ONE"
fi

pass=0
fail=0
failed=()

echo "Regolith kernel gate (${#SCENES[@]} scenes)"
echo

for name in "${SCENES[@]}"; do
	timeout_env=()
	if [[ "$name" == "test_simulation_projection" ]]; then
		timeout_env=( REGOLITH_TEST_TIMEOUT_SEC=45 )
	fi
	if env "${timeout_env[@]}" "$RUN_ONE" "$name"; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		failed+=("$name")
		echo
	fi
done

echo
echo "Summary: $pass passed, $fail failed"

if [[ $fail -gt 0 ]]; then
	printf 'Failed: %s\n' "${failed[*]}"
	exit 1
fi

exit 0
