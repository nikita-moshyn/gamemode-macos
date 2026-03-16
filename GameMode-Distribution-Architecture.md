# GameMode — Distribution & Auto-Update Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        RELEASE PIPELINE                            │
│                                                                     │
│  Developer pushes tag (v1.2.0) to main                             │
│       │                                                             │
│       ▼                                                             │
│  GitHub Actions                                                     │
│       ├── Build (build.sh)                                          │
│       ├── Codesign (Developer ID / ad-hoc)                         │
│       ├── Notarize (xcrun notarytool) [optional but recommended]   │
│       ├── Package → GameMode-v1.2.0.zip                            │
│       ├── Create GitHub Release with .zip asset                    │
│       └── Update Homebrew tap formula (version + SHA256)           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
┌─────────────────────┐    ┌──────────────────────────┐
│   INSTALL METHODS   │    │   IN-APP UPDATE ENGINE   │
│                     │    │                          │
│  brew install ...   │    │  Polls GitHub Releases   │
│  curl | bash        │    │  API on launch + timer   │
│  Manual .zip        │    │                          │
└─────────────────────┘    │  Shows ↓ badge on icon   │
                           │  "Update Available" menu │
                           │  Download → Replace →    │
                           │  Relaunch                │
                           └──────────────────────────┘
```

---

## Part 1 — GitHub Actions Release Pipeline

### Trigger

```yaml
on:
  push:
    tags:
      - 'v*'       # e.g. v1.0.0, v1.2.3-beta
```

Only fires on version tags pushed to any branch (typically main).

### Workflow Steps

```
 ┌───────────────┐
 │  Checkout     │
 └──────┬────────┘
        ▼
 ┌───────────────┐
 │  Build        │  ./build.sh
 └──────┬────────┘
        ▼
 ┌───────────────┐
 │  Codesign     │  codesign --deep --force --sign "Developer ID Application: ..."
 └──────┬────────┘  (or ad-hoc: codesign --deep --force --sign - )
        ▼
 ┌───────────────┐
 │  Notarize     │  xcrun notarytool submit ... --wait
 │  (optional)   │  xcrun stapler staple GameMode.app
 └──────┬────────┘
        ▼
 ┌───────────────┐
 │  Package      │  cd build && zip -r ../GameMode-${TAG}.zip GameMode.app
 └──────┬────────┘
        ▼
 ┌───────────────┐
 │  Release      │  softprops/action-gh-release
 │               │  uploads: GameMode-${TAG}.zip
 │               │  body: auto-generated from CHANGELOG or commits
 └──────┬────────┘
        ▼
 ┌───────────────┐
 │  Update Tap   │  Push new formula to homebrew-gamemode repo
 │  (optional)   │  with updated version, URL, sha256
 └───────────────┘
```

### Workflow File: `.github/workflows/release.yml`

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  build-and-release:
    runs-on: macos-14          # Apple Silicon runner
    steps:
      - uses: actions/checkout@v4

      - name: Extract version from tag
        id: version
        run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Build
        run: |
          chmod +x build.sh
          ./build.sh

      - name: Codesign (ad-hoc)
        run: codesign --deep --force --sign - build/GameMode.app

      # Optional: Developer ID signing + notarization
      # - name: Import signing certificate
      #   env:
      #     CERTIFICATE_P12: ${{ secrets.DEVELOPER_ID_P12 }}
      #     CERTIFICATE_PASSWORD: ${{ secrets.DEVELOPER_ID_PASSWORD }}
      #   run: |
      #     echo "$CERTIFICATE_P12" | base64 --decode > cert.p12
      #     security create-keychain -p "" build.keychain
      #     security import cert.p12 -k build.keychain -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
      #     security set-key-partition-list -S apple-tool:,apple: -k "" build.keychain
      #     security list-keychains -s build.keychain
      #     codesign --deep --force --sign "Developer ID Application: YOUR NAME (TEAM_ID)" build/GameMode.app
      #
      # - name: Notarize
      #   env:
      #     APPLE_ID: ${{ secrets.APPLE_ID }}
      #     APPLE_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
      #     TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
      #   run: |
      #     zip -r GameMode-notarize.zip build/GameMode.app
      #     xcrun notarytool submit GameMode-notarize.zip \
      #       --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$TEAM_ID" --wait
      #     xcrun stapler staple build/GameMode.app

      - name: Package
        run: |
          cd build
          zip -r ../GameMode-${{ steps.version.outputs.VERSION }}.zip GameMode.app

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: GameMode-${{ steps.version.outputs.VERSION }}.zip
          generate_release_notes: true
          draft: false
          prerelease: ${{ contains(github.ref_name, 'beta') || contains(github.ref_name, 'rc') }}

      # Optional: Update Homebrew tap
      # - name: Update Homebrew formula
      #   env:
      #     TAP_GITHUB_TOKEN: ${{ secrets.TAP_GITHUB_TOKEN }}
      #   run: |
      #     SHA=$(shasum -a 256 GameMode-${{ steps.version.outputs.VERSION }}.zip | awk '{print $1}')
      #     VERSION=${{ steps.version.outputs.VERSION }}
      #     # Clone tap, update formula, push
```

### Versioning Convention

- Tag format: `v{MAJOR}.{MINOR}.{PATCH}` — e.g. `v1.2.0`
- Pre-release: `v1.2.0-beta.1`, `v1.2.0-rc.1`
- The tag version must match `CFBundleShortVersionString` in Info.plist
- Consider a script or build step that injects the version from the tag into Info.plist at build time

### Info.plist Version Injection (in build.sh or CI)

```bash
# Inject version from git tag into Info.plist before build
TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.1")
VERSION="${TAG#v}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" GameMode/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" GameMode/Info.plist
```

---

## Part 2 — Installation Methods

### Method A: Homebrew Tap (recommended)

**Setup:**
1. Create repo: `github.com/YOUR_USERNAME/homebrew-gamemode`
2. Add cask formula: `Casks/gamemode.rb`

```ruby
cask "gamemode" do
  version "1.2.0"
  sha256 "ABCDEF1234567890..."

  url "https://github.com/YOUR_USERNAME/GameMode/releases/download/v#{version}/GameMode-#{version}.zip"
  name "GameMode"
  desc "Automatically toggle macOS settings for gaming"
  homepage "https://github.com/YOUR_USERNAME/GameMode"

  app "GameMode.app"

  zap trash: [
    "~/Library/Application Support/GameMode",
    "~/Library/Preferences/com.nikita.GameMode.plist",
  ]
end
```

**User installs with:**
```bash
brew tap YOUR_USERNAME/gamemode
brew install --cask gamemode
```

**Auto-update tap from CI:** The release workflow can push version + SHA changes to the tap repo after each release.

### Method B: curl Install Script

**File: `install.sh` (in repo root)**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="GameMode"
REPO="YOUR_USERNAME/GameMode"
INSTALL_DIR="/Applications"

echo "==> Fetching latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
echo "    Latest version: ${LATEST}"

URL="https://github.com/${REPO}/releases/download/v${LATEST}/${APP_NAME}-${LATEST}.zip"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Downloading ${APP_NAME} v${LATEST}..."
curl -fsSL "$URL" -o "${TMP_DIR}/${APP_NAME}.zip"

echo "==> Installing to ${INSTALL_DIR}..."
unzip -qo "${TMP_DIR}/${APP_NAME}.zip" -d "${TMP_DIR}"

if [ -d "${INSTALL_DIR}/${APP_NAME}.app" ]; then
    echo "    Removing previous version..."
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
fi

mv "${TMP_DIR}/${APP_NAME}.app" "${INSTALL_DIR}/"

echo "==> ${APP_NAME} v${LATEST} installed to ${INSTALL_DIR}/${APP_NAME}.app"
echo "    Run: open '${INSTALL_DIR}/${APP_NAME}.app'"
```

**User installs with:**
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/GameMode/main/install.sh | bash
```

---

## Part 3 — In-App Update Engine

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     UpdateManager                        │
│  (ObservableObject, singleton)                          │
│                                                          │
│  Properties:                                             │
│    @Published availableUpdate: UpdateInfo?               │
│    @Published updateState: UpdateState                   │
│    currentVersion: String  (from Bundle)                │
│                                                          │
│  Methods:                                                │
│    checkForUpdate()         → async, polls GitHub API   │
│    downloadAndInstall()     → download, verify, replace │
│    startPeriodicChecks()    → Timer every 6 hours       │
│    skipVersion(_:)          → user dismisses a version  │
│                                                          │
│  Flow:                                                   │
│    launch → checkForUpdate() → if newer → set           │
│    availableUpdate → AppDelegate observes → updates     │
│    menu + icon badge                                     │
└─────────────────────────────────────────────────────────┘
```

### Data Models

```swift
struct UpdateInfo {
    let version: String          // e.g. "1.3.0"
    let downloadURL: URL         // .zip asset URL from GitHub
    let releaseNotes: String     // body from GitHub release
    let publishedAt: Date
    let htmlURL: URL             // link to release page
}

enum UpdateState {
    case idle
    case checking
    case available(UpdateInfo)
    case downloading(progress: Double)   // 0.0 – 1.0
    case readyToInstall
    case installing
    case failed(Error)
}
```

### Version Check Flow

```
 ┌──────────────────────┐
 │  App launches        │
 │  + every 6 hours     │
 └──────────┬───────────┘
            ▼
 ┌──────────────────────┐
 │  GET github.com/     │
 │  repos/OWNER/REPO/   │
 │  releases/latest     │
 └──────────┬───────────┘
            ▼
 ┌──────────────────────┐
 │  Parse tag_name      │
 │  e.g. "v1.3.0"      │
 │  → "1.3.0"          │
 └──────────┬───────────┘
            ▼
 ┌──────────────────────┐     ┌───────────────┐
 │  Compare with        │────▶│ Same/older    │──▶ Done (no update)
 │  current version     │     └───────────────┘
 │  (CFBundleShort...)  │
 └──────────┬───────────┘
            │ newer
            ▼
 ┌──────────────────────┐
 │  Check skipped       │
 │  versions list       │
 │  (UserDefaults)      │
 └──────────┬───────────┘
            │ not skipped
            ▼
 ┌──────────────────────┐
 │  Set availableUpdate │
 │  → UI updates        │
 └──────────────────────┘
```

### Semantic Version Comparison

```swift
/// Compare two version strings like "1.2.3" vs "1.3.0"
/// Returns true if remote is newer than local
func isNewer(_ remote: String, than local: String) -> Bool {
    let r = remote.split(separator: ".").compactMap { Int($0) }
    let l = local.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(r.count, l.count) {
        let rv = i < r.count ? r[i] : 0
        let lv = i < l.count ? l[i] : 0
        if rv > lv { return true }
        if rv < lv { return false }
    }
    return false
}
```

### Auto-Update Flow

```
 User clicks "Update Available (v1.3.0)"
            │
            ▼
 ┌──────────────────────┐
 │  Download .zip to    │
 │  ~/Library/Caches/   │
 │  GameMode/update.zip │
 └──────────┬───────────┘
            ▼
 ┌──────────────────────┐
 │  Unzip to temp dir   │
 └──────────┬───────────┘
            ▼
 ┌──────────────────────┐
 │  Verify codesign     │  codesign --verify --deep
 │  (if signed)         │
 └──────────┬───────────┘
            ▼
 ┌──────────────────────┐
 │  Replace app bundle  │
 │  1. Move current →   │
 │     .app.old         │
 │  2. Move new → dest  │
 │  3. Delete .app.old  │
 └──────────┬───────────┘
            ▼
 ┌──────────────────────┐
 │  Relaunch            │
 │  Spawn helper script │
 │  that waits for exit │
 │  then opens new app  │
 └──────────────────────┘
```

### Relaunch Strategy

The app cannot replace itself while running. Use a small trampoline:

```swift
func relaunchAfterUpdate() {
    let appPath = Bundle.main.bundlePath
    let script = """
    sleep 1
    open "\(appPath)"
    """
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", script]
    try? task.run()
    NSApp.terminate(nil)
}
```

### File: `GameMode/Core/UpdateManager.swift`

**Responsibilities:**
- `checkForUpdate()` — hits GitHub Releases API, parses JSON, compares versions
- `downloadAndInstall(update:)` — downloads zip, unzips, verifies, replaces, relaunches
- `startPeriodicChecks()` — Timer.scheduledTimer every 6 hours
- `skipVersion(_:)` — adds version to UserDefaults skip list
- `@Published availableUpdate` — observed by AppDelegate for menu/icon updates

**GitHub API response fields used:**
```json
{
  "tag_name": "v1.3.0",
  "name": "GameMode v1.3.0",
  "body": "### What's new\n- ...",
  "html_url": "https://github.com/.../releases/tag/v1.3.0",
  "published_at": "2026-03-15T12:00:00Z",
  "assets": [
    {
      "name": "GameMode-1.3.0.zip",
      "browser_download_url": "https://github.com/.../GameMode-1.3.0.zip"
    }
  ]
}
```

---

## Part 4 — Menu Bar Update Indicator

### Icon States

```
 Normal:           Update available:

  ┌───┐              ┌───┐
  │ 🎮 │              │ 🎮 │
  └───┘              └─┬─┘
                       ↓     ← small down-arrow badge (bottom-right corner)
```

### Implementation Approach

Compose the badge dynamically using `NSImage`:

```swift
func statusBarImage(updateAvailable: Bool) -> NSImage {
    let base = NSImage(systemSymbolName: "gamecontroller.fill",
                       accessibilityDescription: "GameMode")!
    guard updateAvailable else { return base }

    let size = NSSize(width: 18, height: 18)
    let composed = NSImage(size: size)
    composed.lockFocus()

    // Draw base icon
    base.draw(in: NSRect(origin: .zero, size: size))

    // Draw small ↓ badge in bottom-right
    let badge = NSImage(systemSymbolName: "arrow.down.circle.fill",
                        accessibilityDescription: "Update available")!
    let badgeRect = NSRect(x: 11, y: 0, width: 8, height: 8)
    badge.draw(in: badgeRect)

    composed.unlockFocus()
    composed.isTemplate = false  // keep colors for badge
    return composed
}
```

### Menu Layout — Update Available

```
┌─────────────────────────────────────┐
│  ↓ Update Available — v1.3.0       │  ← blue/highlighted, top of menu
│  ─────────────────────────────────  │
│  Game Mode: Off                     │
│  Enable Mouse Boost                 │
│  ─────────────────────────────────  │
│  Settings...                   ⌘,   │
│  ─────────────────────────────────  │
│  Quit GameMode                 ⌘Q   │
└─────────────────────────────────────┘
```

After clicking "Update Available":

```
┌─────────────────────────────────────┐
│  ⟳ Downloading Update... 45%       │  ← disabled, shows progress
│  ─────────────────────────────────  │
│  ...                                │
```

After download completes:

```
┌─────────────────────────────────────┐
│  ⟳ Restart to Update               │  ← click to relaunch
│  ─────────────────────────────────  │
│  ...                                │
```

### AppDelegate Integration Points

```swift
// In rebuildMenu():
if let update = updateManager.availableUpdate {
    switch updateManager.updateState {
    case .available:
        let item = NSMenuItem(
            title: "↓ Update Available — v\(update.version)",
            action: #selector(startUpdate),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)

    case .downloading(let progress):
        let pct = Int(progress * 100)
        let item = NSMenuItem(title: "Downloading Update... \(pct)%", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)

    case .readyToInstall:
        let item = NSMenuItem(
            title: "Restart to Update",
            action: #selector(installUpdate),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)

    default: break
    }
    menu.addItem(.separator())
}
```

---

## Part 5 — Security Considerations

### Codesign Verification

Before replacing the app bundle with a downloaded update:

```swift
func verifyCodesign(at path: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    proc.arguments = ["--verify", "--deep", "--strict", path]
    try? proc.run()
    proc.waitUntilExit()
    return proc.terminationStatus == 0
}
```

### HTTPS Only

All GitHub API calls and downloads go over HTTPS. No HTTP fallback.

### Checksum Verification (optional enhancement)

If you add a `SHA256SUMS` file to each release:
1. Download `SHA256SUMS` alongside the `.zip`
2. Verify the zip's SHA256 matches before extracting
3. Protects against CDN tampering or incomplete downloads

---

## Part 6 — File Structure (new files)

```
GameMode/
├── .github/
│   └── workflows/
│       └── release.yml              ← CI pipeline
├── GameMode/
│   ├── Core/
│   │   ├── UpdateManager.swift      ← update check + download + install
│   │   └── ... (existing)
│   ├── App/
│   │   ├── AppDelegate.swift        ← add update menu items + icon badge
│   │   └── ... (existing)
│   └── ... (existing)
├── install.sh                        ← curl installer script
├── CHANGELOG.md                      ← release notes history
└── ... (existing)
```

**Homebrew tap (separate repo):**
```
homebrew-gamemode/
└── Casks/
    └── gamemode.rb
```

---

## Implementation Order

| Phase | What                              | Depends On |
|-------|-----------------------------------|------------|
| 1     | Version injection in build.sh     | —          |
| 2     | `release.yml` GitHub Action       | Phase 1    |
| 3     | `UpdateManager.swift`             | —          |
| 4     | AppDelegate update UI (menu + icon badge) | Phase 3 |
| 5     | `install.sh`                      | Phase 2    |
| 6     | Homebrew tap repo + formula       | Phase 2    |
| 7     | Notarization step in CI           | Apple Dev account |
| 8     | CHANGELOG.md automation           | Phase 2    |

Phases 1-2 (CI) and 3-4 (in-app) can be built in parallel.
