#!/usr/bin/env bash
# Builds Swapjutsu.app from project.yml: `scripts/build-app.sh [Debug|Release]` (Release by default).
# The project is generated, not committed; the app lands in build/<config>/ and its path is printed last.
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-Release}"
case "$config" in
    Debug | Release) ;;
    *)
        echo "usage: $0 [Debug|Release]" >&2
        exit 64
        ;;
esac
xcodegen generate --quiet --use-cache --cache-path build/xcodegen-cache.json
# ARCHS here as well as in project.yml: project.yml doesn't reach the package's targets, which a Release build would
# also compile for x86_64, where Float16 is unavailable.
xcodebuild -project Swapjutsu.xcodeproj -scheme Swapjutsu -configuration "$config" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
    CONFIGURATION_BUILD_DIR="$PWD/build/$config" ARCHS=arm64 -quiet build
echo "$PWD/build/$config/Swapjutsu.app"
