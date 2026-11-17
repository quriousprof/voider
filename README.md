<div align="center">

<img src="voider-logo.png" alt="Voider logo: a chalk comet across the night sky" width="180" />

# Voider

**Virtual workspaces for macOS, living quietly in your menu bar.**

Switch workspaces with `⌥ 1`, send windows away with `⌥ ⇧ 1`. No tiling, no fuss.

![macOS](https://img.shields.io/badge/macOS-26.6%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)
![Config](https://img.shields.io/badge/config-TOML-blue)

</div>

---

## What is Voider?

Voider is a minimal workspace manager for macOS. It gives you virtual workspaces (think "desktops") without taking over your window layout. Your windows stay exactly where you put them. Voider only decides which ones are visible.

- Press `⌥ 2` and only the windows that belong to workspace **2** are on screen.
- Press `⌥ ⇧ 3` and the focused window is sent to workspace **3**.
- The menu bar shows the active workspace, and the menu lists every workspace with the app you were last using in it, like `2 - Spotify`.

Unlike macOS Spaces there are no swipe animations, no full-screen transitions, and switching is instant and keyboard-driven.

## Features

- **Menu bar only.** No Dock icon, no main window.
- **Instant workspace switching** with global hotkeys (Carbon `RegisterEventHotKey`, so no extra permission is needed for the hotkeys themselves).
- **Move windows between workspaces**, optionally following them there (`follow-moved-window`).
- **Follows focus.** Cmd-Tab or click a Dock icon for an app on another workspace and Voider takes you to that workspace.
- **Named workspaces.** Digits and letters, case-insensitive, any order (`["1", "2", "A", "B"]`).
- **Fully configurable** through a single TOML file, with live reload.
- **Crash-safe.** Window assignments are persisted, and windows left off-screen by a crash are recovered on the next launch.
- **Works with Chromium/Electron apps** such as Spotify, which hide their accessibility tree until asked.
- **Single instance.** Launching a new copy replaces the old one.

## How it works

Voider doesn't use macOS Spaces. It tracks every standard window through the Accessibility API and assigns each one to a workspace. To hide a window it **parks it just past the bottom-right corner of the screen**. It doesn't minimize the window or hide the app. Showing a workspace moves its windows back to where they were.

| Piece | Role |
| --- | --- |
| `WindowManager` | Tracks windows, assigns workspaces, hides and shows them, watches focus through `AXObserver` |
| `HotkeyManager` | Registers global hotkeys with Carbon |
| `ConfigManager` / `VoiderConfig` | Creates, loads and validates `~/.config/voider/voider.toml` |
| `TOMLParser` | A small hand-written TOML subset parser (no dependencies) |
| `StateStore` | Persists workspace assignments and parked positions to `state.json` |
| `SingleInstance` | Makes sure only one copy runs, newest launch wins |

## Requirements

- macOS 26.6 or later
- **Accessibility permission.** Voider needs it to see and move other apps' windows. It prompts on first launch and starts working as soon as you grant it.

## Installation

### From a release

1. Download the latest `Voider.dmg` from the [Releases](../../releases) page.
2. Drag **Voider** into `Applications` and open it.
3. When prompted, grant access in **System Settings → Privacy & Security → Accessibility**.

### From source

```sh
git clone <this repo>
open voider.xcodeproj
```

Select the `voider` scheme and press `⌘R`. See [Building a release](#building-a-release) to produce a distributable app.

## Usage

| Shortcut | Action |
| --- | --- |
| `⌥ N` | Switch to workspace `N` |
| `⌥ ⇧ N` | Move the focused window to workspace `N` |
| `⌥ ⇧ R` | Reload the config |

These are the defaults. Every one of them can be changed in the config. Windows start in the first workspace, and new windows join whichever workspace is active.

## Configuration

The first launch creates `~/.config/voider/voider.toml`. Edit it, then choose **Reload Config** from the menu (or press `⌥ ⇧ R`).

```toml
# Workspace names, in order. Windows start in the first one. Omit for 0-9.
workspaces = ["1", "2", "3", "A", "B"]

# Switch to the target workspace after moving a window there.
follow-moved-window = false

# "action" = "modifiers-key"
[keybindings]
"workspace 1" = "alt-1"
"workspace 2" = "alt-2"
"move-to-workspace 1" = "alt-shift-1"
"move-to-workspace 2" = "alt-shift-2"
"reload-config" = "alt-shift-r"
```

| Setting | Description |
| --- | --- |
| `workspaces` | Workspace names, in order. Digits and letters. Case-insensitive (`a` and `A` are the same workspace). Omitted means `0`–`9`. |
| `follow-moved-window` | `true` switches to the destination workspace after moving a window. Global, applies to every workspace. Default `false`. |
| `[keybindings]` | `"action" = "modifiers-key"`. If the table is omitted, `alt-<name>` and `alt-shift-<name>` are bound for every workspace. If present, only its entries are bound. |

**Actions:** `workspace <name>`, `move-to-workspace <name>`, `reload-config`

**Modifiers:** `alt` (or `option`), `shift`, `cmd` (or `command`), `ctrl` (or `control`)

**Keys:** `a`–`z`, `0`–`9`, `space`, `tab`, `return`, `escape`, arrows, and more.

If the config has an error, the last good config stays active and the menu shows what went wrong.

### Files Voider writes

| Path | Purpose |
| --- | --- |
| `~/.config/voider/voider.toml` | Your configuration |
| `~/.config/voider/state.json` | Workspace assignments and parked window positions, used for recovery |
| `~/.config/voider/voider.lock` | Single-instance lock |

## Safety and recovery

- Quitting Voider from the menu puts every hidden window back where it was.
- If Voider is killed (a crash, or stopping it from Xcode), parked windows can't be restored on the spot. On the next launch Voider reads `state.json` and recovers them. A window found off-screen with no saved entry is moved to the top-left of the screen.

## Known limitations

- Windows on other macOS Spaces are invisible to Voider.
- Parking assumes a single monitor (it uses the right-most screen edge).
- There's no config file watcher, so reload manually after editing.
- Window IDs come from the private `_AXUIElementGetWindow` function. It has been stable for years and other window managers rely on it, but it means Voider can't be sold through the Mac App Store. App Sandbox is also off, because Voider has to control other apps and read the real `~/.config`.

## Building a release

To share Voider with people who just want to download and use it, ship a **signed, notarized app in a `.dmg`**. Without notarization, Gatekeeper warns on every other Mac that the app "can't be verified".

**You'll need:** a paid [Apple Developer Program](https://developer.apple.com/programs/) membership and a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates → `+`).

1. **Enable the hardened runtime.** In the `voider` target's *Signing & Capabilities*, add **Hardened Runtime**. Notarization requires it.
2. **Archive.** Choose **Product → Archive** (destination: *Any Mac*).
3. **Export.** In the Organizer, pick the archive and choose **Distribute App → Direct Distribution**. Xcode signs it with your Developer ID, uploads it to Apple for notarization, and exports `voider.app` once Apple approves.
4. **Package.** Create a disk image:
   ```sh
   hdiutil create -volname "Voider" -srcfolder path/to/exported/voider.app \
     -ov -format UDZO Voider.dmg
   ```
   For a nicer drag-to-Applications window, a tool like [`create-dmg`](https://github.com/create-dmg/create-dmg) works well.
5. **Check it.** Verify the result before uploading:
   ```sh
   spctl -a -vv path/to/exported/voider.app   # expect: accepted, source=Notarized Developer ID
   ```
6. **Publish.** Create a GitHub Release, attach `Voider.dmg`, and link it from this README.

Prefer the command line? `xcodebuild archive` and `xcodebuild -exportArchive` do the same thing, and `xcrun notarytool submit Voider.dmg --wait` followed by `xcrun stapler staple Voider.dmg` notarizes a disk image directly.

> Anyone installing a build that isn't notarized has to right-click the app and choose **Open** the first time. That's fine for friends and testers but not for public downloads.

## Project layout

```
voider/
├── MyApp.swift            App entry (MenuBarExtra)
├── AppDelegate.swift      Startup
├── AppController.swift    Wires config, hotkeys and windows together
├── SingleInstance.swift   Newest launch wins
├── Config/                TOML parser, config model, key bindings, loader
├── Hotkeys/               Global hotkeys (Carbon)
├── Windows/               Accessibility helpers, window manager, state persistence
└── UI/                    Menu bar label and menu
```

More detail lives in [`CONTEXT.md`](CONTEXT.md).

## Contributing

Small, focused commits with conventional one-line messages (`feat:`, `fix:`, `chore:`, and so on). Tests use Swift Testing, and window and workspace logic should stay testable without the Accessibility API.
