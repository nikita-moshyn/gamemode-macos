# Using GameMode

GameMode lives in your menu bar. Open the controller icon for the Game Mode switch, Mouse Preset, settings, and update checks.

## Set it up

1. Open **Settings** from the menu bar.
2. In **Input Guard**, turn protection on and select the shortcuts and gestures you want to block. Enable standard function keys if you want F1-F12 without the media controls.
3. In **Auto-Activation**, enable the applications you play with.
4. In **Mouse**, choose a tracking speed and whether to apply it automatically.
5. In **General**, enable **Launch at login** if you want GameMode to start when you sign in.

Input Guard is off by default on a fresh install. Selecting an app for automatic activation doesn't turn protection on; choose the changes you want first.

## Permissions

Grant GameMode access in **System Settings > Privacy & Security > Accessibility** for Input Guard and global hotkeys. You can check its status and request access from **Settings > System > Permissions**.

Notifications are optional. Allow them if you'd like a message when Game Mode turns on or off.

In beta builds, automatic Low Power Mode changes require administrator approval. That prompt is separate from Accessibility access.

## Automatic activation

GeForce NOW and Steam Games are enabled by default. You can also enable presets for other launchers and emulators.

- **Add App** lets you choose an application yourself.
- **Scan for Games** looks in `/Applications` and `~/Applications` for apps marked as games. Detected games start disabled until you choose them.
- **Steam Games** matches individual Steam game apps. Keeping the Steam launcher open alone doesn't activate GameMode.

GameMode stays active while any enabled app is running. It restores your settings after the last one quits. For GeForce NOW, this follows the client application, so quit the client when you're finished playing.

Use the **Game Mode** switch in the menu bar whenever you want manual control.

## Input Guard

Turn on the **Input Guard** master switch, then choose the system shortcuts and gestures to block during Game Mode. The function key option uses F1-F12 as standard keys while the mode is active.

Switching Input Guard off keeps your selections for later. Your original settings are saved before changes are applied and used for restoration afterward.

## Mouse preset

In **Settings > Mouse**, turn on **Enable Mouse Preset** and choose a tracking speed. The preset applies to all mice connected to your Mac.

Enable **Apply automatically with Game Mode** to apply it at the start of a session. Otherwise, turn on Game Mode and use **Mouse Preset** in the menu bar or **Apply Preset** in settings.

Your normal tracking speed is captured before the preset is first applied. Turning the preset or Game Mode off restores that speed. The menu bar hides the mouse control when Game Mode is off or mouse presets are disabled.

## Hotkeys

Open **Settings > Hotkeys** to record shortcuts for GameMode actions. Enable the ones you want to use and grant Accessibility access so they work while another app is focused.

## Displays in beta builds

In the current source, **Settings > Displays** is available in beta Release builds and local Debug builds. Earlier stable releases included older display controls; see the [changelog](../CHANGELOG.md) for your version.

Choose the displays and applications that should use the maximum available refresh rate. External displays need a compatible fixed refresh rate mode. The built-in ProMotion fallback depends on macOS and the display; it can't guarantee a particular refresh rate.

You can also enable automatic Low Power Mode changes with a battery threshold. This requires administrator approval. GameMode saves the previous power settings for restoration when the session ends.

## Updates and beta testing

Use **Check for Updates** in the menu bar or **Settings > General**. Sparkle handles update checks and installation. It offers automatic checks when first configured.

**Receive beta updates** is off by default. Enable it in **General** to receive newer beta and release candidate builds as well as stable releases. Downloading a beta manually doesn't enable this preference.

If your installed version doesn't have this preference, download a beta from [GitHub Releases](https://github.com/nikita-moshyn/gamemode-macos/releases).

Turning beta updates off keeps your installed version until a newer stable build is available. To return sooner, turn off Game Mode, quit the app, and replace it with the [latest stable download](https://github.com/nikita-moshyn/gamemode-macos/releases/latest).

## When something gets stuck

### Input Guard or hotkeys don't work

Check Accessibility access in **Settings > System**. If macOS shows an old copy of GameMode in its Accessibility list after you replace or rebuild the app, remove that entry, add the current app from Applications, and reopen it.

Also check that Input Guard is enabled, the relevant shortcuts are selected, and the app appears active in the menu bar.

### Settings weren't restored

Reopen GameMode so it can recover the interrupted session. Recovery on launch and restoration before shutdown or restart are enabled by default.

If recovery needs attention, open **Review Recovery** from the menu bar or **Settings > System > Recovery**:

1. Choose **Retry Recovery** to restore saved values. When no recovery is pending, the button is called **Restore Saved Settings**.
2. If restoration still fails, check the message and any required permissions before trying again.
3. As a last resort, set your preferred normal settings in macOS, then choose **Use Current Settings as Normal**. This ends recovery and stops using the previous saved values for automatic restoration.

Keep the recovery files in `~/Library/Application Support/GameMode/` while recovery is pending. They contain the original settings the app needs.

### Saved configuration can't be read

Open **Settings > System** and review the message. Finish any pending recovery first. **Reset Saved Configuration** resets GameMode preferences; it doesn't restore macOS settings. It's available once Game Mode is off and recovery has finished.

For other problems, [open an issue](https://github.com/nikita-moshyn/gamemode-macos/issues) with the app version, macOS version, and steps to reproduce it. The [contributor guide](../CONTRIBUTING.md#report-a-bug) explains how to collect logs.

Report vulnerabilities and security concerns privately, following the [security policy](../SECURITY.md).

## Uninstall

1. Turn off Game Mode and let restoration finish. Resolve any pending recovery first.
2. Disable **Launch at login** in **Settings > General**, then quit GameMode.
3. Move `GameMode.app` from Applications to the Trash.

Saved preferences remain on your Mac if you reinstall later.
