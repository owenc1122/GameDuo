#!/bin/bash
# Build the fixtures, then check validate_ps2.py and verify_scenekit.swift give the
# expected PASS/FAIL verdicts. Exits nonzero on any mismatch.
set -u
cd "$(dirname "$0")/../../.."
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
B=("$BLENDER" -b --factory-startup --python-exit-code 1)
CONTRACT=tools/ps2_blender/tests/fixture_contract.json
OUT=tools/ps2_blender/tests/out
errors=0

expect() {  # expect <label> <log> <regex>
    if grep -Eq "$3" "$2"; then echo "  ok   $1"; else echo "  MISS $1 (want /$3/)"; errors=$((errors + 1)); fi
}

mkdir -p "$OUT" && rm -f "$OUT"/fixture*.usdz "$OUT"/validation.json
"${B[@]}" --python tools/ps2_blender/tests/make_fixture.py > "$OUT/make_fixture.log" 2>&1 \
    || { echo "fixture build failed, see $OUT/make_fixture.log"; exit 1; }

echo "validate_ps2.py"
"${B[@]}" --python tools/ps2_blender/validate_ps2.py -- --contract "$CONTRACT" > "$OUT/validate.log" 2>&1
code=$?
grep -E '^(OK|FAIL|ERROR) ' "$OUT/validate.log"
expect "good fixture passes" "$OUT/validate.log" '^OK FixtureGood '
expect "collision detected" "$OUT/validate.log" '^FAIL FixtureBadCollision: .*FIX_LID_mesh intersects FIX_BODY_mesh'
expect "missing file reported" "$OUT/validate.log" '^FAIL FixtureMissing: file not found'
[ "$code" -eq 1 ] && echo "  ok   exit code 1" || { echo "  MISS exit code $code != 1"; errors=$((errors + 1)); }
expect "validation.json written" "$OUT/validation.json" '"FixtureBadCollision"'

"${B[@]}" --python tools/ps2_blender/validate_ps2.py -- --contract "$CONTRACT" --only FixtureGood > "$OUT/validate_good.log" 2>&1
code=$?
[ "$code" -eq 0 ] && echo "  ok   --only FixtureGood exits 0" || { echo "  MISS --only FixtureGood exit $code"; errors=$((errors + 1)); }

"${B[@]}" --python tools/ps2_blender/validate_ps2.py -- --contract "$OUT/no_such_contract.json" > "$OUT/validate_nocontract.log" 2>&1
code=$?
expect "missing contract reported" "$OUT/validate_nocontract.log" '^ERROR contract not found'
[ "$code" -ne 0 ] || { echo "  MISS missing contract exited 0"; errors=$((errors + 1)); }

echo "verify_scenekit.swift"
xcrun swift tools/ps2_blender/verify_scenekit.swift "$CONTRACT" FixtureGood > "$OUT/scenekit.log" 2>&1
code=$?
cat "$OUT/scenekit.log"
expect "SceneKit loads good fixture" "$OUT/scenekit.log" '^OK FixtureGood$'
[ "$code" -eq 0 ] || { echo "  MISS SceneKit exit $code"; errors=$((errors + 1)); }
xcrun swift tools/ps2_blender/verify_scenekit.swift "$CONTRACT" FixtureMissing > "$OUT/scenekit_missing.log" 2>&1
code=$?
expect "SceneKit reports missing file" "$OUT/scenekit_missing.log" '^FAIL FixtureMissing: file not found'
[ "$code" -eq 1 ] || { echo "  MISS SceneKit missing-file exit $code"; errors=$((errors + 1)); }

if [ "$errors" -eq 0 ]; then echo "ALL PS2 VALIDATOR TESTS PASSED"; else echo "$errors CHECK(S) FAILED"; exit 1; fi
