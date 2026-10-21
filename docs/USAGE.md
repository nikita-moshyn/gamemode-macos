# Using GameMode

GameMode lives in your menu bar. Open the controller icon for the Game Mode switch, Mouse Preset, settings, and update checks.

## Set it up

1. Open **Settings** from the menu bar.
2. In **Input Guard**, turn protection on and select the shortcuts and gestures you want to block. Choose your function-key profile in the same **Input Guard** page.
3. In **Auto-Activation**, enable the applications you play with.
4. In **Mouse**, choose a tracking speed and whether to apply it automatically.
5. In **General**, enable **Launch at login** if you want GameMode to start when you sign in.

Input Guard is off by default on a fresh install. Selecting an app for automatic activation doesn't turn protection on; choose the changes you want first.

Use the sidebar to choose a settings pane. Back and Forward retrace the panes and pages you visit; their keyboard shortcuts are **⌘[** and **⌘]**. Settings reopens to your most recently selected pane.

## Permissions

Grant GameMode access in **System Settings > Privacy & Security > Accessibility** for Input Guard and global hotkeys. You can check its status and request access from **Settings > System > Permissions**.

Notifications are optional. Allow them if you'd like a message when Game Mode turns on or off.

GameMode sets up crash recovery automatically. **Settings > System > Recovery** shows whether it is on. If permission is needed, choose **Allow in System Settings…** and allow GameMode in **Login Items & Extensions**. Recovery runs independently of **Launch at login**. Shortcut blocking works without this permission because macOS stops it when GameMode exits.

In beta builds, automatic Low Power Mode changes require administrator approval. That prompt is separate from Accessibility access.

## Automatic activation

GeForce NOW and Steam Games are enabled by default. You can also enable presets for other launchers and emulators.

- **Add App** opens the Add Applications page. Choose applications there, then use Back to return to Auto-Activation.
- **Scan for Games** looks in `/Applications` and `~/Applications` for apps marked as games. Detected games start disabled until you choose them.
- **Steam Games** matches individual Steam game apps. Keeping the Steam launcher open alone doesn't activate GameMode.

GameMode stays active while any enabled app is running. It restores your settings after the last one quits. For GeForce NOW, this follows the client application, so quit the client when you're finished playing.

Use the **Game Mode** switch in the menu bar whenever you want manual control.

## Input Guard

Turn on the **Input Guard** master switch, then choose the system shortcuts and gestures to block during Game Mode. Your function-key profile follows the same master switch.

Switching Input Guard off keeps your selections for later. Your original settings are saved before changes are applied and used for restoration afterward.

### Function keys

Choose **Function Keys** in **Settings > Input Guard**:

- **Keep normal behavior** leaves your keys unchanged.
- **Standard F1–F12** uses function keys during Game Mode.
- **Brightness and volume** uses media keys during Game Mode.

This choice follows the Input Guard switch and is saved only in GameMode. Your normal macOS keyboard preference stays intact.

## Recovery

GameMode automatically restores settings when gaming ends, on quit, and after a crash. Crash recovery covers function keys, gestures, mouse speed, display modes, and power settings that GameMode changed. Shortcut blocking and display activity overlays disappear when the app exits and do not need saved recovery records.

Open **Settings > System > Recovery** to see your saved settings. **Restore Settings** ends Game Mode and retries any unfinished recovery. Newer choices made in macOS Keyboard Settings are kept. If a display is disconnected, its restoration waits until it is available. Power recovery may require administrator approval; the background helper leaves that item pending for the app while recovering other settings.

### Export and recover from a file

Choose **Export…** on the Recovery page. This saves two items in your chosen folder:

- A **.gamemoderecovery** file containing your saved settings.
- **GameMode Recovery.app**, a standalone app with the same recovery screen.

While Game Mode is active, the export contains your original settings. Keep both items if you want to recover after removing GameMode.

Choose **Recover from File…**, review the saved settings, select the ones you want, and choose **Restore Selected Settings**. Opening a file does not change anything. Files work for the same user on the same Mac that created them.

You can also open **GameMode Recovery.app** without GameMode installed. Quit GameMode before restoring with the standalone app. It can finish pending recovery or restore a reviewed file, including when local recovery data is damaged. No Terminal commands are needed.

## Mouse preset

In **Settings > Mouse**, turn on **Enable Mouse Preset** and choose a tracking speed. The preset applies to all mice connected to your Mac.

Enable **Apply automatically with Game Mode** to apply it at the start of a session. Otherwise, turn on Game Mode and use **Mouse Preset** in the menu bar or **Apply Preset** in settings.

Your normal tracking speed is captured before the preset is first applied. Turning the preset or Game Mode off restores that speed. The menu bar hides the mouse control when Game Mode is off or mouse presets are disabled.

## Hotkeys

Open **Settings > Hotkeys** to record shortcuts for GameMode actions. Enable the ones you want to use and grant Accessibility access so they work while another app is focused.

Use the checkbox beside an action to enable it. Double-click its key combination on the right to enter a new shortcut, or select a row and press Return. Escape cancels editing; Delete clears the shortcut. **Restore Defaults** resets only these hotkeys.

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

Open **Review Recovery** from the menu bar, or go to **Settings > System > Recovery**.

1. Choose **Restore Settings** to retry unfinished recovery.
2. Check any message about a disconnected display or required permission.
3. If you have an exported file, choose **Recover from File…** and review it before restoring.
4. If you have already set everything correctly in macOS, **Keep Current Settings…** ends pending recovery after confirmation.

### Saved configuration can't be read

Open **Settings > System** and review the message. Finish any pending recovery first. **Reset Saved Configuration** resets GameMode preferences; it doesn't restore macOS settings. It's available once Game Mode is off and recovery has finished.

### Function keys turn back on while Game Mode is off

Older betas saved the standard-function-key option in a preference specific to your Mac. That value survives reboots and can override your normal keyboard preference. Current versions change the live keyboard mode temporarily.

Previously enabled legacy cleanup continues automatically through the shared recovery engine. It removes the old forced-on override only when the saved normal preference explicitly selects media keys. Managed or unreadable preferences are left alone. No permanent gaming override is created by current versions.

Keep only one current copy of GameMode running; an older beta can recreate the override. If settings still need attention, open the Recovery page.

For other problems, [open an issue](https://github.com/nikita-moshyn/gamemode-macos/issues) with the app version, macOS version, and steps to reproduce it. The [contributor guide](../CONTRIBUTING.md#report-a-bug) explains how to collect logs.

Report vulnerabilities and security concerns privately, following the [security policy](../SECURITY.md).

## Uninstall

1. Turn off Game Mode and let restoration finish. Resolve any pending recovery first.
2. Choose **Export…** in **Settings > System > Recovery** to keep your settings and a standalone recovery app.
3. Disable **Launch at login** in **Settings > General**, then quit GameMode.
4. Move `GameMode.app` from Applications to the Trash. You can disable its background item in macOS **Login Items & Extensions** after recovery is complete.

Saved preferences and recovery records remain on your Mac if you reinstall later. If the app was deleted before restoration finished, open your exported **GameMode Recovery.app**.
