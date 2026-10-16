#!/bin/bash
# Run from the pinned source checkout. Tools come from the workflow commit.
set -euo pipefail
: "${TAG:?}"
: "${VERSION:?}"
: "${BUILD_VERSION:?}"
: "${CHANNEL:?}"
: "${SOURCE_COMMIT:?}"
: "${RELEASE_TOOLS:?}"
: "${RELEASE_DIRECTORY:?}"
: "${RUNNER_TEMP:?}"

python3 -m unittest discover -s "$RELEASE_TOOLS/scripts" -p 'test_*.py'
xcodebuild -project GameMode.xcodeproj -scheme GameMode -configuration Debug \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' \
    -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation \
    GAMEMODE_CHANNEL="$CHANNEL" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test

KEYCHAIN_PATH="$RUNNER_TEMP/gamemode-signing-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.keychain-db"
CERTIFICATE_PATH="$RUNNER_TEMP/gamemode-certificate-${GITHUB_RUN_ID}.p12"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do ORIGINAL_KEYCHAINS+=("$keychain"); done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
cleanup() {
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
    rm -f "$CERTIFICATE_PATH"
}
trap cleanup EXIT
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
printf '%s' "$CERTIFICATE_P12" | base64 --decode > "$CERTIFICATE_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -P "$CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}"
rm -f "$CERTIFICATE_PATH"

# Both beta and stable are optimized Release builds; the channel controls flags.
./build.sh --channel "$CHANNEL" -skipMacroValidation \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
    OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
python3 "$RELEASE_TOOLS/scripts/release.py" verify-bundle --app build/GameMode.app --tag "$TAG"
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [ -z "$IDENTITY" ]; then echo 'No Developer ID Application identity found' >&2; exit 1; fi
find build/GameMode.app/Contents/Frameworks -type f -perm +111 | while IFS= read -r binary; do
    if file "$binary" | grep -q 'Mach-O'; then
        codesign --force --sign "$IDENTITY" --timestamp --options runtime "$binary"
    fi
done
find build/GameMode.app/Contents/Frameworks -depth -type d \( -name '*.app' -o -name '*.xpc' \) | while IFS= read -r nested; do
    codesign --force --sign "$IDENTITY" --timestamp --options runtime "$nested"
done
codesign --force --sign "$IDENTITY" --timestamp --options runtime build/GameMode.app/Contents/Frameworks/Sparkle.framework
codesign --force --sign "$IDENTITY" --timestamp --options runtime --entitlements GameMode/GameMode.entitlements build/GameMode.app
codesign --verify --deep --strict --verbose=2 build/GameMode.app

ZIP="build/GameMode-${VERSION}.zip"
ditto -c -k --keepParent build/GameMode.app "$ZIP"
NOTARY_RESULT="$RUNNER_TEMP/gamemode-notary-${GITHUB_RUN_ID}.json"
if ! xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
    --team-id "$TEAM_ID" --wait --timeout 600 --output-format json > "$NOTARY_RESULT"; then
    cat "$NOTARY_RESULT"
    echo 'Notarization did not succeed. No release will be published.' >&2
    exit 1
fi
python3 - "$NOTARY_RESULT" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit(f"Notarization was not accepted: {result.get('status')}; submission {result.get('id')}")
PY
xcrun stapler staple build/GameMode.app
spctl --assess --type execute --verbose build/GameMode.app
rm "$ZIP"
ditto -c -k --keepParent build/GameMode.app "$ZIP"

SIGN_TOOL=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
SIGNATURE=$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SIGN_TOOL" "$ZIP" -f -)
ED_SIG=$(printf '%s' "$SIGNATURE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(stat -f%z "$ZIP")
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/GameMode.app/Contents/Info.plist)
swift "$RELEASE_TOOLS/scripts/verify_update.swift" "$ZIP" "$ED_SIG" "$PUBLIC_KEY" "$LENGTH"
mkdir -p "$RELEASE_DIRECTORY"
cp "$ZIP" "$RELEASE_DIRECTORY/"
python3 "$RELEASE_TOOLS/scripts/release_delivery.py" record --directory "$RELEASE_DIRECTORY" \
    --tag "$TAG" --commit "$SOURCE_COMMIT" --signature "$ED_SIG" --length "$LENGTH"
