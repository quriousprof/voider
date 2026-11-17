# Voider — Project Context

Voider is a minimal macOS menu bar workspace manager inspired by [AeroSpace](https://github.com/nikitabobko/AeroSpace). It provides virtual workspaces without tiling.

## Behavior

- Lives in the menu bar only (no Dock icon, no main window).
- `⌥ + N` switches to workspace N; `⌥ + ⇧ + N` moves the focused window to workspace N.
- Only the active workspace's windows are visible; windows in other workspaces are hidden by moving them off-screen (AeroSpace-style), not by minimizing or hiding the app.
- Configured by `~/.config/voider/voider.toml`. The directory and a default config are created on first launch if missing.

## Tech

- Swift / SwiftUI, `MenuBarExtra` scene, macOS 26.6+.
- Default actor isolation: `MainActor`.
- Accessibility API (`AXUIElement`, `AXObserver`) for window enumeration and positioning — requires the user to grant Accessibility permission.
- Carbon `RegisterEventHotKey` for global hotkeys.
- TOML parsing via TOMLKit (SPM).
- App Sandbox must be **disabled** (AX control of other apps + access to `~/.config`).

## Layout

- `voider/` — app sources (see `plans/` for the planned file structure).
- `plans/` — implementation plans (gitignored, local only).

## Conventions

- Swift Testing for unit tests; keep window/workspace state logic testable without AX.
- Small, focused commits with conventional commit messages.
