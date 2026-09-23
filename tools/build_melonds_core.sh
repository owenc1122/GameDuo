#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PATH="$PROJECT_ROOT/.tools/azahar-build/bin:$PATH"
export PATH
for platform in sim device; do
    sdk=iphonesimulator
    if [ "$platform" = device ]; then sdk=iphoneos; fi
    cmake -S "$PROJECT_ROOT/ThirdParty/melonds-ds" -B "$PROJECT_ROOT/.build/melonds-modern-$platform" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DENABLE_JIT=OFF -DENABLE_OPENGL=OFF -DBUILD_AS_SHARED_LIBRARY=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build "$PROJECT_ROOT/.build/melonds-modern-$platform" -j8
done
STAGING="$PROJECT_ROOT/.build/melonds-package-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGING"
xcodebuild -create-xcframework \
    -library "$PROJECT_ROOT/.build/melonds-modern-device/src/libretro/melondsds_libretro.dylib" \
    -library "$PROJECT_ROOT/.build/melonds-modern-sim/src/libretro/melondsds_libretro.dylib" \
    -output "$STAGING/MelonDSCore.xcframework"
if [ -d "$PROJECT_ROOT/ThirdParty/MelonDSCore.xcframework" ]; then
    mv "$PROJECT_ROOT/ThirdParty/MelonDSCore.xcframework" "$STAGING/previous.xcframework"
fi
mv "$STAGING/MelonDSCore.xcframework" "$PROJECT_ROOT/ThirdParty/MelonDSCore.xcframework"
