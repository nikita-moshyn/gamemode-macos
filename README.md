# GameMode

A macOS menu bar app that adjusts your keyboard, shortcuts, gestures, and mouse settings while you play, then restores them when you're done.

GameMode doesn't replace Apple's native Game Mode. It adds the extra controls I kept missing while playing on a Mac with GeForce NOW (GFN) and Steam. Accidentally opening Spotlight in the middle of a game gets old pretty quickly.

## What it does

- Activates when your chosen apps launch and restores your settings after the last one quits.
- Blocks selected system shortcuts and gestures with Input Guard, with an option to use standard F1-F12 keys.
- Applies a separate mouse tracking speed, automatically or from the menu bar.
- Gives you global hotkeys for GameMode controls.
- Saves your original settings for recovery after an interrupted session.

## Development status

GameMode is still in development. Stable releases are intended to be safe for everyday use, with full stability as the goal for `v1.0.0`.

I'd be very happy if you tried the beta builds and shared what works and what doesn't. Beta software can be unstable: features may change, settings may misbehave, and bugs are part of the deal. Stick with stable releases if you'd rather spend your evening playing than reporting a bug.

These docs follow the current source. The [changelog](CHANGELOG.md) lists what's in published releases.

## Install

You need macOS 14 Sonoma or newer.

### Manually

1. Download the app ZIP from the [latest stable release](https://github.com/nikita-moshyn/gamemode-macos/releases/latest). Beta builds are on the [releases page](https://github.com/nikita-moshyn/gamemode-macos/releases).
2. Unzip it and move `GameMode.app` to Applications. Quit an existing copy before replacing it.
3. Open GameMode. Look for the controller icon in your menu bar.

Published builds go through Developer ID signing and Apple notarization in the release workflow.

### Automatic updates

Install the first copy manually. GameMode uses Sparkle to check for and install updates after that. Choose automatic update checks when prompted, or use **Check for Updates** in the menu bar.

For beta and release candidate updates, enable **Receive beta updates** in **Settings > General**. This is off by default. Turning it off keeps your installed version until a newer stable release is available; it doesn't downgrade the app. If your version doesn't have this option, download a beta from the releases page.

This repository doesn't include a Homebrew cask or a standalone installer script.

## Get started

1. Open **Settings** from the menu bar.
2. In **Input Guard**, turn protection on and choose the shortcuts, gestures, and function key behavior you want.
3. In **Auto-Activation**, choose which apps should activate GameMode. GeForce NOW and Steam Games are enabled by default.
4. In **Mouse**, set a tracking speed if you want a gaming preset. You can apply it automatically or switch it on during a session.
5. Grant Accessibility access in **System Settings > Privacy & Security > Accessibility** so Input Guard and global hotkeys can work.

You can also toggle **Game Mode** directly from the menu bar. Enable **Launch at login** in **Settings > General** to keep it available when you sign in.

The [usage guide](docs/USAGE.md) covers settings, permissions, recovery, and removal.

## Build it yourself

Building requires the full Xcode 27 app with Swift 6.4 or newer. Command Line Tools alone aren't enough for the pinned Swift packages.

```bash
git clone https://github.com/nikita-moshyn/gamemode-macos.git
cd gamemode-macos
./build.sh CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation
open build/GameMode.app
```

See [Contributing](CONTRIBUTING.md) for Xcode setup, beta builds, and tests.

## Contributing

I'd love your help, whether that's fixing a bug, trying a beta, or sharing an idea.

Check [issues](https://github.com/nikita-moshyn/gamemode-macos/issues) and [pull requests](https://github.com/nikita-moshyn/gamemode-macos/pulls) first. If your idea or bug is already there, join that issue. If it isn't, open one. When nobody is assigned, leave a comment and feel free to work on it.

The [contributor guide](CONTRIBUTING.md) explains how to get set up and open a PR. Let's build beta software together!

## AI use

If you use AI, you don't need to mention it in your PR. I believe AI is a tool to help developers build better things faster. Use whatever works for you.

Review the code, understand what it does, and test it before opening a PR. You're responsible for what you submit. AI slop is bad for the community, but a powerful tool in the right hands can make a real difference.

## Security

Please report vulnerabilities and security issues [privately through GitHub](https://github.com/nikita-moshyn/gamemode-macos/security/advisories/new). Keep the details out of public issues and PRs. See the [security policy](SECURITY.md) for what to include.

## Documentation

- [Changelog](CHANGELOG.md): changes in published releases.
- [Using GameMode](docs/USAGE.md): settings, permissions, updates, and recovery.
- [Contributing](CONTRIBUTING.md): local builds, tests, and pull requests.
- [Security](SECURITY.md): private vulnerability reports.
- [Architecture](docs/ARCHITECTURE.md): how the app and recovery system work.
- [Releases](docs/RELEASING.md): branches, channels, signing, and publishing.

## License

[MIT](LICENSE). Made by Nikita Moshyn.
