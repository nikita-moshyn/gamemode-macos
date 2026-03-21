#!/bin/bash
#
# build.sh — Build GameMode.app from command line (no Xcode GUI needed)
#
# Usage:
#   ./build.sh          Build using xcodebuild (recommended)
#   ./build.sh swiftc   Build using swiftc directly (fallback)
#
# The resulting app will be at:
#   ./build/GameMode.app
#

set -euo pipefail

APP_NAME="GameMode"
BUILD_DIR="build"
SOURCES=(
    # Models
    "GameMode/Models/GameModeConfig.swift"
    "GameMode/Models/MonitoredApp.swift"
    "GameMode/Models/ShortcutEntry.swift"
    "GameMode/Models/SymbolicHotkeys.swift"
    "GameMode/Models/GestureEntry.swift"
    "GameMode/Models/AppHotkey.swift"
    "GameMode/Models/KeyCodeMap.swift"
    # Core
    "GameMode/Core/ConfigStore.swift"
    "GameMode/Core/StateJournal.swift"
    "GameMode/Core/AppDetector.swift"
    "GameMode/Core/AppMonitor.swift"
    "GameMode/Core/SettingsManager.swift"
    "GameMode/Core/HotkeyManager.swift"
    # Views
    "GameMode/Views/SettingsWindow.swift"
    "GameMode/Views/GeneralSettingsView.swift"
    "GameMode/Views/AboutView.swift"
    "GameMode/Views/ShortcutsSettingsView.swift"
    "GameMode/Views/AppsSettingsView.swift"
    "GameMode/Views/AppPickerSheet.swift"
    "GameMode/Views/MouseSettingsView.swift"
    "GameMode/Views/SystemSettingsView.swift"
    "GameMode/Views/ShortcutRecorderView.swift"
    "GameMode/Views/HotkeysSettingsView.swift"
    # App
    "GameMode/App/GameModeApp.swift"
    "GameMode/App/AppDelegate.swift"
)

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET="arm64-apple-macosx14.0"
else
    TARGET="x86_64-apple-macosx14.0"
fi

build_with_xcodebuild() {
    echo "==> Building with xcodebuild..."
    xcodebuild \
        -project "${APP_NAME}.xcodeproj" \
        -scheme "${APP_NAME}" \
        -configuration Release \
        -derivedDataPath "${BUILD_DIR}/DerivedData" \
        build

    # Copy the .app out of DerivedData to a predictable location
    APP_PATH=$(find "${BUILD_DIR}/DerivedData" -name "${APP_NAME}.app" -type d | head -1)
    if [ -n "$APP_PATH" ]; then
        rm -rf "${BUILD_DIR}/${APP_NAME}.app"
        cp -R "$APP_PATH" "${BUILD_DIR}/${APP_NAME}.app"
        echo ""
        echo "==> Built successfully: ${BUILD_DIR}/${APP_NAME}.app"
        echo "    To install: cp -R ${BUILD_DIR}/${APP_NAME}.app /Applications/"
    else
        echo "ERROR: Could not find built app"
        exit 1
    fi
}

build_with_swiftc() {
    echo "==> Building with swiftc (direct compilation)..."
    echo "    WARNING: swiftc build does not include Sparkle (auto-update)."
    echo "    Use xcodebuild (default) for full functionality."

    SDK_PATH=$(xcrun --show-sdk-path)
    APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
    CONTENTS="${APP_BUNDLE}/Contents"
    MACOS="${CONTENTS}/MacOS"

    # Clean previous build
    rm -rf "${APP_BUNDLE}"
    mkdir -p "${MACOS}"

    # Compile
    echo "    Compiling for ${TARGET}..."
    swiftc \
        -target "${TARGET}" \
        -sdk "${SDK_PATH}" \
        -framework AppKit \
        -framework Carbon \
        -framework IOKit \
        -framework ServiceManagement \
        -framework UserNotifications \
        -O \
        -o "${MACOS}/${APP_NAME}" \
        "${SOURCES[@]}"

    # Copy Info.plist
    cp GameMode/Info.plist "${CONTENTS}/Info.plist"

    # Ad-hoc sign (required for Apple Silicon)
    echo "    Signing..."
    codesign --force --sign - \
        --entitlements GameMode/GameMode.entitlements \
        "${APP_BUNDLE}"

    echo ""
    echo "==> Built successfully: ${APP_BUNDLE}"
    echo "    To install: cp -R ${APP_BUNDLE} /Applications/"
}

# ──────────────────────────────────────

mkdir -p "${BUILD_DIR}"

if [ "${1:-}" = "swiftc" ]; then
    build_with_swiftc
else
    build_with_xcodebuild
fi

echo ""
echo "==> First-run setup:"
echo "    1. Open the app:  open ${BUILD_DIR}/${APP_NAME}.app"
echo "    2. Grant Accessibility: System Settings → Privacy & Security → Accessibility → add GameMode"
echo "    3. Allow Notifications when prompted"
echo "    4. The app auto-starts on login. Open GeForce Now to test!"
