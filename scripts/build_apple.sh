#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
target="${1:-mac}"
case "$target" in
  mac)
    cmake -S . -B build/mac -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_OSX_ARCHITECTURES=arm64
    cmake --build build/mac -j 4
    ctest --test-dir build/mac --output-on-failure
    printf '%s\n' "build/mac/KartDriftOffline.app"
    ;;
  ios)
    cmake -S . -B build/ios -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
    cmake --build build/ios -j 4
    mkdir -p build/package/Payload
    ditto build/ios/KartDriftOffline.app build/package/Payload/KartDriftOffline.app
    # Ad-hoc signing is for the authorized development device. Normal iPhones
    # need Apple development signing/provisioning; this does not replace it.
    if command -v ldid >/dev/null 2>&1; then ldid -S build/package/Payload/KartDriftOffline.app/KartDriftOffline; fi
    ditto -c -k --keepParent build/package/Payload build/KartDriftOffline-ios.ipa
    printf '%s\n' "build/KartDriftOffline-ios.ipa"
    ;;
  *) printf 'Usage: %s mac|ios\n' "$0"; exit 2 ;;
esac
