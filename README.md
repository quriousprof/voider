<div align="center">

<img src="voider-logo.png" alt="Voider logo: a chalk comet across the night sky" width="180" />

# Voider

**Virtual workspaces for macOS, living quietly in your menu bar.**

Switch workspaces with `⌥ 1`, send windows away with `⌥ ⇧ 1`. No tiling, no fuss.

![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)
![Config](https://img.shields.io/badge/config-TOML-blue)
![License](https://img.shields.io/badge/license-Apache%202.0-green)

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
- **One-click updates.** *Check for Updates* in the menu, then *Update and Restart*. Voider also checks quietly once a day.

## How it works

Voider doesn't use macOS Spaces. It tracks every standard window through the Accessibility API and assigns each one to a workspace. To hide a window it **parks it just past the bottom-right corner of the screen**. It doesn't minimize the window or hide the app. Showing a workspace moves its windows back to where they were.

## Requirements

- macOS 14 Sonoma or later
- **Accessibility permission.** Voider needs it to see and move other apps' windows. It prompts on first launch and starts working as soon as you grant it.

## Installation

### From a release

1. Download the latest `Voider.dmg` from the [Releases](../../releases) page.
2. Drag **Voider** into `Applications` and open it.
3. When prompted, grant access in **System Settings → Privacy & Security → Accessibility**.

Later versions install from the menu: **Check for Updates**, then **Update to X and Restart**. Voider downloads the release, checks it's signed and notarized by the same developer, replaces itself and relaunches. Keep Voider in a folder you can write to (like `Applications`) for this to work.

### From source

```sh
git clone <this repo>
open voider.xcodeproj
```

Select the `voider` scheme and press `⌘R`.

## Usage

| Shortcut | Action |
| --- | --- |
| `⌥ N` | Switch to workspace `N` |
| `⌥ ⇧ N` | Move the focused window to workspace `N` |
| `⌥ ⇥` | Toggle between the current and the previous workspace |
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
"workspace-back-and-forth" = "alt-tab"
"reload-config" = "alt-shift-r"
```

| Setting | Description |
| --- | --- |
| `workspaces` | Workspace names, in order. Digits and letters. Case-insensitive (`a` and `A` are the same workspace). Omitted means `0`–`9`. |
| `follow-moved-window` | `true` switches to the destination workspace after moving a window. Global, applies to every workspace. Default `false`. |
| `[keybindings]` | `"action" = "modifiers-key"`. If the table is omitted, `alt-<name>` and `alt-shift-<name>` are bound for every workspace, plus `alt-tab` for back-and-forth. If present, only its entries are bound. |

**Actions:** `workspace <name>`, `move-to-workspace <name>`, `workspace-back-and-forth`, `reload-config`

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
- If Voider is killed (a crash or a force quit), parked windows can't be restored on the spot. On the next launch Voider reads `state.json` and recovers them. A window found off-screen with no saved entry is moved to the top-left of the screen.

## License

Voider is licensed under the [Apache License 2.0](LICENSE).
