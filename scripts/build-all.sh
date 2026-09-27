#!/usr/bin/env bash
# Builds and tests everything into dist/: protocol tests, server release, firmware images, Android APK.
#   scripts/build-all.sh [--skip-tests]
set -euo pipefail
cd "$(dirname "$0")/.."
SKIP_TESTS=0
[ "${1:-}" = "--skip-tests" ] && SKIP_TESTS=1
git submodule update --init --recursive
scripts/check-protocol.sh
rm -rf dist && mkdir -p dist/server dist/firmware dist/android

if [ "$SKIP_TESTS" = 0 ]; then
    echo "== protocol: vectors on C, C#, Kotlin"
    protocol/scripts/test.sh
    echo "== server tests"
    dotnet test server/home-server.slnx --nologo -v q
    echo "== android core tests"
    (cd android && ./gradlew :core:test --no-daemon -q)
fi

echo "== server"
server/scripts/publish.sh
cp server/dist/*.tar.gz server/dist/*.sha256 dist/server/

echo "== firmware"
for d in firmware/devices/*/; do
    dev=$(basename "$d")
    firmware/scripts/fw-build.sh "$dev"
done
cp -r firmware/dist/* dist/firmware/

if [ -n "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ] || [ -f android/local.properties ]; then
    echo "== android"
    (cd android && ./gradlew :app:assembleDebug --no-daemon -q)
    cp android/app/build/outputs/apk/debug/*.apk dist/android/
else
    echo "== android: skipped (no Android SDK)"
fi
echo "done: dist/"
find dist -maxdepth 3 -type f | sort
