#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AZAHAR_ROOT="$PROJECT_ROOT/ThirdParty/Azahar"
TOOLS_ROOT="$PROJECT_ROOT/.tools/azahar-build"
OUTPUT="$PROJECT_ROOT/ThirdParty/AzaharCore.xcframework"

if [ ! -x "$TOOLS_ROOT/bin/cmake" ]; then
    python3 -m venv "$TOOLS_ROOT"
    "$TOOLS_ROOT/bin/python" -m pip install --upgrade pip cmake ninja
fi

export PATH="$TOOLS_ROOT/bin:$PATH"

configure_core() {
    build_directory=$1
    sdk=$2
    cmake \
        -DENABLE_LIBRETRO=ON \
        -DENABLE_TESTS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS=-DIOS \
        -DCMAKE_CXX_FLAGS=-DIOS \
        -DIOS=ON \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DCITRA_USE_PRECOMPILED_HEADERS=OFF \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DENABLE_OPT=OFF \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -S "$AZAHAR_ROOT" \
        -B "$build_directory"
    cmake --build "$build_directory" --target citra_libretro -j 8
}

configure_core "$AZAHAR_ROOT/build/ios-arm64" iphoneos
configure_core "$AZAHAR_ROOT/build/ios-simulator-arm64" iphonesimulator

STAGING="$PROJECT_ROOT/.build/azahar-package-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGING"

xcodebuild -create-xcframework \
    -library "$AZAHAR_ROOT/build/ios-arm64/bin/Release/azahar_libretro.dylib" \
    -headers "$AZAHAR_ROOT/externals/libretro-common/libretro-common/include" \
    -library "$AZAHAR_ROOT/build/ios-simulator-arm64/bin/Release/azahar_libretro.dylib" \
    -headers "$AZAHAR_ROOT/externals/libretro-common/libretro-common/include" \
    -output "$STAGING/AzaharCore.xcframework"
if [ -d "$OUTPUT" ]; then mv "$OUTPUT" "$STAGING/previous.xcframework"; fi
mv "$STAGING/AzaharCore.xcframework" "$OUTPUT"
