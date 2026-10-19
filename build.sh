#!/bin/bash
#
# build.sh — Build GameMode.app from command line (no Xcode GUI needed)
#
# Usage:
#   ./build.sh                         Build using xcodebuild and Swift packages
#   ./build.sh --channel beta          Include beta-only features
#   ./build.sh CODE_SIGN_IDENTITY=-    Build with ad-hoc signing
# Additional arguments are forwarded to xcodebuild.
# Requires Xcode 27 / Swift 6.4 or newer. Trust the package macros in Xcode
# before the first build, or pass -skipMacroValidation for a headless build.
#
# The resulting app will be at:
#   ./build/GameMode.app
#

set -euo pipefail

APP_NAME="GameMode"
BUILD_DIR="build"
build_with_xcodebuild() {
    echo "==> Building with xcodebuild..."
    xcodebuild \
        -project "${APP_NAME}.xcodeproj" \
        -scheme "${APP_NAME}" \
        -configuration Release \
        -derivedDataPath "${BUILD_DIR}/DerivedData" \
        -onlyUsePackageVersionsFromResolvedFile \
        "$@" \
        build

    # Copy the .app out of DerivedData to a predictable location
    local app_path="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"
    if [ -d "$app_path" ]; then
        rm -rf "${BUILD_DIR}/${APP_NAME}.app"
        cp -R "$app_path" "${BUILD_DIR}/${APP_NAME}.app"
        echo ""
        echo "==> Built successfully: ${BUILD_DIR}/${APP_NAME}.app"
        echo "    To install: cp -R ${BUILD_DIR}/${APP_NAME}.app /Applications/"
    else
        echo "ERROR: Could not find built app"
        exit 1
    fi
}

# TCA uses Swift package dependencies and compiler macros; the standalone swiftc
# fallback cannot resolve or build them. Keep one supported build path.
if [ "${1:-}" = "swiftc" ]; then
    echo "Direct swiftc builds are no longer supported. Use ./build.sh to build with Swift packages."
    exit 2
fi

CHANNEL=stable
if [ "${1:-}" = "--channel" ]; then
    if [ "$#" -lt 2 ]; then echo "--channel requires stable, beta, or rc" >&2; exit 2; fi
    CHANNEL="${2:-}"
    shift 2
fi
case "$CHANNEL" in stable|beta|rc) ;; *) echo "Invalid channel: $CHANNEL (use stable, beta, or rc)" >&2; exit 2 ;; esac
mkdir -p "${BUILD_DIR}"
build_with_xcodebuild "$@" GAMEMODE_CHANNEL="$CHANNEL"

echo ""
echo "==> First-run setup:"
echo "    1. Open the app:  open ${BUILD_DIR}/${APP_NAME}.app"
echo "    2. Grant Accessibility: System Settings → Privacy & Security → Accessibility → add GameMode"
echo "    3. Allow Notifications when prompted"
echo "    4. The app auto-starts on login. Open GeForce Now to test!"
