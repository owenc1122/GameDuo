#!/bin/bash
# Rebuild all five PS2 runtime assets from scratch, then run every check.
#
#   tools/ps2_blender/run_all.sh [--render]
#
# Order (Blender runs strictly one at a time; the M2 build machine has 8 GB):
#   1. PS2-MemoryCard  (the console's --check appends PS2_Model/PS2-MemoryCard.blend)
#   2. PS2-DualShock2
#   3. PS2-Console     (with --check: memory card / DualShock 2 plug fit tests)
#   4. PS2-DVD         (always renders renders/dvd_{label,data}.png)
#   5. PS2-Case        (imports build_dvd.py helpers; always renders renders/case_*.png)
# then tests/run_tests.sh, validate_ps2.py (all assets) and verify_scenekit.swift
# (all assets). --render also writes the console / DualShock 2 / memory card check
# renders. Logs go to build/ps2_logs/. Exits 1 if any step fails.
set -u
cd "$(dirname "$0")/../.."
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
B=("$BLENDER" -b --factory-startup --python-exit-code 1)
LOGS=build/ps2_logs
mkdir -p "$LOGS"

RENDER=()  # expanded as ${RENDER[@]+...}: bash 3.2 + set -u rejects empty arrays
for arg in "$@"; do
    case "$arg" in
        --render) RENDER=(--render) ;;
        *) echo "usage: $0 [--render]"; exit 2 ;;
    esac
done

failed=()
step() {  # step <label> <command...>
    local label=$1; shift
    local log="$LOGS/$label.log"
    local t0=$SECONDS
    printf '%-22s ' "$label"
    if "$@" > "$log" 2>&1; then
        echo "PASS ($((SECONDS - t0)) s)"
    else
        echo "FAIL ($((SECONDS - t0)) s), see $log"
        tail -n 15 "$log" | sed 's/^/    /'
        failed+=("$label")
    fi
}

echo "== build"
step build_memory_card "${B[@]}" --python PS2_Model/source/build_memory_card.py -- ${RENDER[@]+"${RENDER[@]}"}
step build_dualshock2  "${B[@]}" --python PS2_Model/source/build_dualshock2.py -- ${RENDER[@]+"${RENDER[@]}"}
step build_console     "${B[@]}" --python PS2_Model/source/build_console.py -- --check ${RENDER[@]+"${RENDER[@]}"}
step build_dvd         "${B[@]}" --python PS2_Disc_Case/source/build_dvd.py
step build_case        "${B[@]}" --python PS2_Disc_Case/source/build_case.py

echo "== checks"
step validator_tests   bash tools/ps2_blender/tests/run_tests.sh
step validate_ps2      "${B[@]}" --python tools/ps2_blender/validate_ps2.py
step verify_scenekit   xcrun swift tools/ps2_blender/verify_scenekit.swift

echo "== verdicts"
grep -hE '^(OK|FAIL|ERROR) ' "$LOGS/validate_ps2.log" | sed 's/^/validate_ps2    /'
grep -hE '^(OK|FAIL|ERROR) ' "$LOGS/verify_scenekit.log" | sed 's/^/verify_scenekit /'
grep -h '^\[console\] FIT' "$LOGS/build_console.log" | sed 's/^/console --check /'
grep -h 'self-check' "$LOGS/build_case.log" | sed 's/^/case            /'

if [ ${#failed[@]} -eq 0 ]; then
    echo "ALL PS2 BUILDS AND CHECKS PASSED"
else
    echo "FAILED: ${failed[*]}"
    exit 1
fi
