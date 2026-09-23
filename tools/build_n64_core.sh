#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE="$PROJECT_ROOT/ThirdParty/parallel-n64"
OUTPUT="$PROJECT_ROOT/ThirdParty/N64Core.xcframework"
STAGING="$PROJECT_ROOT/.build/n64-package-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGING/device" "$STAGING/simulator"
# This upstream makefile does not track platform/compiler switches: a clean is required.
for sdk in iphoneos iphonesimulator; do
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    if [ "$sdk" = iphoneos ]; then
        target=arm64-apple-ios14.0
        output_directory="$STAGING/device"
    else
        target=arm64-apple-ios14.0-simulator
        output_directory="$STAGING/simulator"
    fi
    make -C "$CORE" clean platform=ios-arm64
    make -C "$CORE" -j8 platform=ios-arm64 IOSSDK="$sdk_path" \
        CC="clang -target $target -isysroot $sdk_path" \
        CXX="clang++ -target $target -isysroot $sdk_path" \
        MINVERSION= HAVE_OPENGL=0 HAVE_THR_AL=1
    cp "$CORE/parallel_n64_libretro_ios.dylib" "$output_directory/"
done
xcodebuild -create-xcframework \
    -library "$STAGING/device/parallel_n64_libretro_ios.dylib" \
    -library "$STAGING/simulator/parallel_n64_libretro_ios.dylib" \
    -output "$STAGING/N64Core.xcframework"
if [ -d "$OUTPUT" ]; then mv "$OUTPUT" "$STAGING/previous.xcframework"; fi
mv "$STAGING/N64Core.xcframework" "$OUTPUT"
