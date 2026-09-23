#!/bin/bash
# Build the fixtures, then check validate_ps2.py and verify_scenekit.swift give the
# expected PASS/FAIL verdicts on tests/fixture/contract.json. Exits nonzero on any mismatch.
set -u
cd "$(dirname "$0")/../../.."
BLENDER=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
B=("$BLENDER" -b --factory-startup --python-exit-code 1)
CONTRACT=tools/ps2_blender/tests/fixture/contract.json
OUT=tools/ps2_blender/tests/out
errors=0

miss() { echo "  MISS $1"; errors=$((errors + 1)); }
expect() {  # expect <label> <log> <regex>
    if grep -Eq -- "$3" "$2"; then echo "  ok   $1"; else miss "$1 (want /$3/)"; fi
}
expect_code() {  # expect_code <label> <wanted> <actual>
    if [ "$3" -eq "$2" ]; then echo "  ok   $1 exits $2"; else miss "$1 exits $3, want $2"; fi
}

mkdir -p "$OUT" && rm -f "$OUT"/fixture*.usdz "$OUT"/validation.json
"${B[@]}" --python tools/ps2_blender/tests/make_fixture.py > "$OUT/make_fixture.log" 2>&1 \
    || { echo "fixture build failed, see $OUT/make_fixture.log"; exit 1; }

echo "validate_ps2.py"
V="$OUT/validate.log"
"${B[@]}" --python tools/ps2_blender/validate_ps2.py -- --contract "$CONTRACT" > "$V" 2>&1
code=$?
grep -E '^(OK|FAIL|ERROR) ' "$V"
expect "good fixture passes (needs contract_parts merge)" "$V" '^OK FixtureGood '
expect "collision detected" "$V" '^FAIL FixtureBadCollision: .*FIX_LID_mesh intersects FIX_BODY_mesh'
expect "allow_touch on a parent keeps the mover checked" "$V" '^FAIL FixtureAllowTouchLeak: .*FIX_LATCH intersects FIX_BODY_mesh'
expect "mesh fully inside detected" "$V" '^FAIL FixtureInside: .*FIX_LATCH is inside FIX_BODY_mesh'
expect "rotated rot_* pivot rejected" "$V" '^FAIL FixtureRestRotation: .*rest rotation'
expect "ambiguous name rejected" "$V" '^FAIL FixtureAmbiguous: ambiguous name FIX_LATCH'
expect "missing file reported" "$V" '^FAIL FixtureMissing: file not found'
expect_code "full fixture run" 1 "$code"
expect "validation.json written" "$OUT/validation.json" '"FixtureInside"'
python3 - "$OUT/validation.json" <<'PY' && echo "  ok   stale validation.json entry dropped" || miss "stale entry kept"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data['StaleAsset'] = {'passed': True}
json.dump(data, open(path, 'w'))
PY

"${B[@]}" --python tools/ps2_blender/validate_ps2.py -- --contract "$CONTRACT" --only FixtureGood > "$OUT/validate_good.log" 2>&1
expect_code "--only FixtureGood" 0 $?
grep -q '"StaleAsset"' "$OUT/validation.json" && miss "StaleAsset still in validation.json" || echo "  ok   StaleAsset removed on rewrite"

"${B[@]}" --python tools/ps2_blender/validate_ps2.py -- --contract "$OUT/no_such/contract.json" > "$OUT/validate_nocontract.log" 2>&1
code=$?
expect "missing contract reported" "$OUT/validate_nocontract.log" '^ERROR contract not found'
expect_code "missing contract" 2 "$code"

echo "verify_scenekit.swift"
S="$OUT/scenekit.log"
xcrun swift tools/ps2_blender/verify_scenekit.swift --contract "$CONTRACT" > "$S" 2>&1
code=$?
cat "$S"
expect "SceneKit: good fixture (merged contract)" "$S" '^OK FixtureGood$'
expect "SceneKit: lid lift moves 20 mm up" "$S" 'FixtureGood FIX_LID loc_y=0.02: centre moved \[0.000, 20.000, 0.000\]'
expect "SceneKit: rotated rot_* pivot rejected" "$S" '^FAIL FixtureRestRotation: .*rest rotation'
expect "SceneKit: ambiguous name rejected" "$S" '^FAIL FixtureAmbiguous: ambiguous name FIX_LATCH'
expect "SceneKit: missing file reported" "$S" '^FAIL FixtureMissing: file not found'
expect_code "SceneKit full fixture run" 1 "$code"
xcrun swift tools/ps2_blender/verify_scenekit.swift --contract "$CONTRACT" --only FixtureGood > "$OUT/scenekit_good.log" 2>&1
expect_code "SceneKit --only FixtureGood" 0 $?

if [ "$errors" -eq 0 ]; then echo "ALL PS2 VALIDATOR TESTS PASSED"; else echo "$errors CHECK(S) FAILED"; exit 1; fi
