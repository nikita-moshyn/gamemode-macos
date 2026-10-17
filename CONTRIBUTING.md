# Contributing to GameMode

I'd love your help. Code, bug reports, ideas, and time spent testing beta builds all count.

For vulnerabilities or security concerns, follow the [security policy](SECURITY.md) and report privately through GitHub. Keep those details out of public issues and PRs.

## Pick something to work on

1. Search existing [issues](https://github.com/nikita-moshyn/gamemode-macos/issues) and [pull requests](https://github.com/nikita-moshyn/gamemode-macos/pulls) for the same problem or idea.
2. If there's already an issue, add what you've found there. Otherwise, open one with a clear description.
3. If nobody is assigned, leave a comment saying you'd like to work on it. For a larger change, discuss the approach in the issue first.
4. Fork the repository and create your branch from `develop`. Open your PR against `develop` when it's ready.

## Report a bug

Include your GameMode version and channel, macOS version, Mac model, and steps to reproduce it. Explain what you expected and what happened instead. For input or display problems, include the keyboard, mouse, or display involved.

Logs help when a setting fails to apply or restore. In **Settings > System > Diagnostics**, enable logging, choose a level, and open Console. Filter by process `GameMode`, reproduce the problem, and include the relevant messages after checking them for personal information.

## Build locally

You need macOS 14 or newer and the full Xcode 27 app with Swift 6.4 or newer. The pinned Composable Architecture packages require that toolchain. Select it in **Xcode > Settings > Locations > Command Line Tools**.

To try the current development branch:

```bash
git clone --branch develop https://github.com/nikita-moshyn/gamemode-macos.git
cd gamemode-macos
./build.sh CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
open build/GameMode.app
```

The build script uses `xcodebuild`, resolves the pinned Swift packages, and copies the Release build to `build/GameMode.app`. The command above uses ad hoc signing, so you don't need the maintainer's signing certificate. `-skipMacroValidation` lets package macros build without an interactive Xcode trust prompt.

To include beta features in a Release build:

```bash
./build.sh --channel beta CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
```

For Xcode development, open `GameMode.xcodeproj`, select the **GameMode** scheme, and use your own signing team. Allow the package macros when prompted. Debug builds include beta features automatically; the channel still defaults to stable. The [release guide](docs/RELEASING.md#feature-flags) explains the difference.

Local builds use the same app identity and preferences as the released app. Quit any running copy before launching a local build. macOS may ask you to grant Accessibility access again after rebuilding with ad hoc signing.

## Run tests

Run the Swift tests with the stable feature set used in CI:

```bash
xcodebuild \
    -project GameMode.xcodeproj \
    -scheme GameMode \
    -configuration Debug \
    -derivedDataPath build/DerivedData \
    -destination 'platform=macOS' \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipMacroValidation \
    GAMEMODE_CHANNEL=stable \
    GAMEMODE_DEBUG_FEATURES= \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    test
```

Run it again with `GAMEMODE_CHANNEL=beta` to cover beta features. Keeping `GAMEMODE_DEBUG_FEATURES=` makes each run use that channel's shipped feature set. You can also run tests in Xcode with **Product > Test**; ordinary Debug builds include all beta features.

For release tooling changes:

```bash
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/release.py validate-appcast appcast.xml
```

CI builds Release and runs Swift tests for both stable and beta. Both must pass for the required **build** check. Documentation changes need a diff review and a check that links, commands, and setting names are correct.

## Open a pull request

Push your branch to your fork, then open a pull request with `develop` as the base branch. Keep it focused on one problem, explain what changes for the user, link the issue, and say how you checked it. For behavior involving permissions, input devices, or displays, include the Mac and macOS version you tested and anything you couldn't verify.

## Code conventions

Keep application decisions in the reducers and system work behind the existing dependency clients. SwiftUI views present state and send actions. The [architecture guide](docs/ARCHITECTURE.md) shows where things live.

When changing system settings, save the original values before applying changes and preserve recovery on failure. Add tests for changed behavior, including restoration when relevant. Tests must use controlled dependencies rather than changing the developer's live system settings.

For beta features, add the condition to `GAMEMODE_BETA_FEATURES` in `Config/FeatureFlags.xcconfig` and guard both the UI and the code that applies changes. Keep recovery available in every channel so a stable build can restore settings left by a beta.

Use this header for new Swift files. Fill in the filename, your name, the creation date (`DD/MM/YYYY`), and the current year. Keep Nikita Moshyn in the copyright line:

```swift
//
//  FILENAME.swift
//  GameMode
//
//  Created by AUTHOR on DATE.
//  Copyright © YEAR Nikita Moshyn. All rights reserved.
//

import Foundation
```

Preserve the original header, including its author, creation date, and copyright year, when editing an existing file. Leave exactly one blank line between the header and the first line of code.

Describe the user-visible change in your PR so it can go into the [changelog](CHANGELOG.md). Leave version bumps, changelog entries, signing credentials, and publication to the maintainer.

[AI use](README.md#ai-use) is welcome; review and test what you submit.
