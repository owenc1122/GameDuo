#!/bin/bash
# Builds the Play! PS2 emulator for WebAssembly with the Game Duo patch and copies Play.js /
# Play.wasm into DuoDS/Resources/PS2Web. Needs git, python3 (>= 3.10 for emsdk; set
# EMSDK_PYTHON), and network access on first run. Work dir: $PLAY_WORK (default ~/Developer/ps2core).
set -euo pipefail
PLAY_COMMIT=83700b2c31e593bc94e845b4b31b797be84dda59
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${PLAY_WORK:-$HOME/Developer/ps2core}"
mkdir -p "$WORK" && cd "$WORK"
export PATH="$(python3 -c 'import site,os;print(os.path.join(site.USER_BASE,"bin"))'):$PATH"
command -v cmake >/dev/null && command -v ninja >/dev/null || python3 -m pip install --user --quiet cmake ninja
[ -d emsdk ] || git clone --depth 1 https://github.com/emscripten-core/emsdk.git
[ -x emsdk/upstream/emscripten/emcc ] || (cd emsdk && ./emsdk install latest && ./emsdk activate latest)
source emsdk/emsdk_env.sh >/dev/null
if [ ! -d Play- ]; then
  git clone --recursive https://github.com/jpd002/Play-.git
fi
cd Play-
if ! git diff --quiet HEAD -- Source/ui_js/Main.cpp 2>/dev/null; then
  echo "Play- already patched"
else
  git fetch --quiet origin "$PLAY_COMMIT" 2>/dev/null || true
  git checkout --quiet "$PLAY_COMMIT" && git submodule update --init --recursive --quiet
  git apply "$HERE/duo.patch"
fi
mkdir -p build_web && cd build_web
[ -f build.ninja ] || emcmake cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF -DBUILD_PLAY=ON -DBUILD_PSFPLAYER=OFF -DUSE_QT=OFF
ninja -j"${JOBS:-4}" Play
cp Source/ui_js/Play.js Source/ui_js/Play.wasm "$REPO/DuoDS/Resources/PS2Web/"
echo "Play! web build copied to DuoDS/Resources/PS2Web"
