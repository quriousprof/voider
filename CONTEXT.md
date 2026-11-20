# Voider — Project Context

Voider is a minimal macOS menu bar workspace manager. It provides virtual workspaces without tiling.

## Behavior

- Lives in the menu bar only (no Dock icon, no main window). The menu bar title is the active workspace.
- `⌥ + N` switches to workspace N; `⌥ + ⇧ + N` moves the focused window to workspace N (defaults; fully configurable).
- The menu lists each workspace as `<id> - <app name>` (the app owning that workspace's last-focused window, falling back to the lowest window ID; just `<id>` if empty). Only the active workspace's windows are visible. Others are hidden by parking them just past the bottom-right screen corner, not by minimizing or hiding the app.
- Switching to a workspace focuses its last-focused window (remembered per workspace for the session); with none remembered, the workspace's front-most window in WindowServer stacking order.
- Focusing a window from another workspace (Cmd-Tab, Dock click) switches to that workspace. Focus events within 0.5s of a switch are ignored (they come from our own hide/show).
- New windows join the active workspace.
- Moving a window (`move-to-workspace`) parks it in the target workspace. With `follow-moved-window = true` the active workspace switches to the target instead and the moved window stays focused.

## Config: `~/.config/voider/voider.toml`

- Directory and a default file are created on first launch. Reload via menu, or the `reload-config` binding (default `⌥⇧R`). No file watcher yet.
- On a parse error the previous good config stays active and the menu shows the error.
- `workspaces = [...]`: names in order; windows start in the first. Omitted → `0`–`9`.
- `follow-moved-window = true|false` (top-level, global, default `false`): switch to the target workspace after moving a window. A non-bool value is a config error.
- **Workspace names are case-insensitive and always stored uppercase** (`a` and `A` are the same workspace; duplicates collapse, first position wins). This applies to the `workspaces` list, to names inside action strings, and to saved state.
- `[keybindings]`: `"action" = "modifiers-key"`. Actions: `workspace <name>`, `move-to-workspace <name>`, `workspace-back-and-forth` (toggles to the previously active workspace; not persisted), `reload-config`. Modifiers: alt, shift, cmd, ctrl.
- If the `[keybindings]` table is omitted entirely, `alt-<name>` / `alt-shift-<name>` are bound for every workspace whose name is a valid key, plus `alt-tab` for back-and-forth and `alt-shift-r` for reload (dropped if a workspace named `R` claims that combo). If the table is present, only its entries are bound.

## Persistence and recovery

- `~/.config/voider/state.json` is written after every change: active workspace, and per window (keyed by CGWindowID) its pid, workspace, and original position if parked.
- State is loaded in `WindowManager.start()` (not at init, so it runs after any previous instance has exited) and re-adopted as windows are rediscovered (pid must match).
- Nothing is saved until tracking has started, so launching without Accessibility permission can't overwrite saved state.
- A tracked window is only forgotten when its app has quit or the WindowServer (`CGWindowListCopyWindowInfo`) no longer has its ID. AX listings drop windows transiently (after wake, slow apps, Chromium AX rebuilds); forgetting them made the next refresh re-adopt every parked window into the active workspace. Windows missing from the AX listing but still alive are kept, marked `isListed = false`, and skipped when picking a window to focus.
- On wake (`didWake`/`screensDidWake`) and screen changes, a settle pass runs refresh + forced re-park after 1s and again 3s later, since macOS can pull parked windows back on screen while displays reconfigure. `refresh`/`reconcile` do nothing while `NSScreen.screens` is empty.
- Rescue: a window found in the parking area with no valid saved entry is moved to (80, 80). The parked check has ~20px slack for macOS clamping and is unverified against real clamping behavior.
- Quitting normally restores all hidden windows. A killed process (Xcode stop = SIGKILL, crash) can't, so recovery happens on next launch via the state file.

## Single instance

`SingleInstance.claim()` runs first in `applicationDidFinishLaunching`. Newest launch wins: it asks older copies (same bundle ID) to quit, force-quits any that don't within 3s, then takes an exclusive `flock` on `~/.config/voider/voider.lock` (released by the kernel on any exit). If a newer copy already exists, the older one exits immediately (`exit(0)`, no cleanup).

## Tech

- Swift / SwiftUI, `MenuBarExtra` scene, macOS 14+ (`@Observable` and argument-less `activate()` set that floor), default actor isolation `MainActor`, Swift Observation (`@Observable`), async/await (no Combine).
- Accessibility API (`AXUIElement`, `AXObserver`) for window enumeration/positioning; the user must grant Accessibility permission (polled until granted). Window IDs come from private `_AXUIElementGetWindow`.
- Chromium/CEF/Electron apps (e.g. Spotify) keep their AX tree off until asked: `observe()` sets `AXManualAccessibility` on each app, and `focusedWindowID()` falls back to the frontmost app's pid when the system-wide focused-app query is empty. Without this, moving Spotify's window silently did nothing. (`AXEnhancedUserInterface` is never turned on; it can break window animations in other apps. Apps that already have it on get it switched off around our moves, since it makes AX moves animate.)
- Speed: window queries and hide/show moves go through `AXBatch` (`AXHelpers.swift`), one thread per app via `concurrentPerform`, so a switch costs about as much as the slowest app, not the sum of all apps. `switchTo` doesn't do a full refresh (observers keep `tracked` current); it only flushes a pending debounced refresh.
- Focusing uses private SkyLight `_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo` (make-key event), as AltTab/yabai do, resolved with `dlsym` at runtime. `NSRunningApplication.activate()` is only a request since macOS 14 and is denied to non-active callers, which Voider always is; it's kept only as the fallback if the symbols are missing.
- Carbon `RegisterEventHotKey` for global hotkeys (swallows the key; no Accessibility needed for hotkeys).
- TOML: hand-written subset parser (`TOMLParser`), no dependency. Supports comments, `[tables]`, strings, ints, bools, multi-line arrays.
- App Sandbox is **disabled** (AX control of other apps, access to the real `~/.config`). `LSUIElement = YES`.
- The Xcode project uses the new `project.xcproj` format with a folder-synced `voider/` group: new Swift files are picked up automatically. Prefer the Xcode tools for build settings; the exception is `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, which the tool rejects as unknown, so it was added to the target's `build-settings` in `project.xcproj` by hand.

## Layout (`voider/`)

- `MyApp.swift`, `AppDelegate.swift`, `AppController.swift`, `SingleInstance.swift`: entry, startup, wiring.
- `Config/`: `TOMLParser`, `VoiderConfig` (model, defaults, parse), `KeyBinding` (+ `Action`), `ConfigManager` (bootstrap/load).
- `Hotkeys/HotkeyManager.swift`: Carbon hotkeys.
- `Windows/`: `AXHelpers`, `WindowManager` (state, hide/show, observers), `StateStore` (state.json).
- `UI/MenuContent.swift`: menu bar label and menu.
- `Assets.xcassets/AppIcon.appiconset`: app icon (16–1024 px, generated from `voider-logo.png` with `sips`).
- `README.md`: user-facing docs only (features, install, usage, config). Keep developer and release details here, not there.
- `LICENSE`: Apache License 2.0.
- `plans/` is gitignored (local only); `plans/001-voider-mvp.md` is the original plan.

## Distribution

Direct download only. Not App Store eligible (sandbox off, private `_AXUIElementGetWindow` and SkyLight focus calls). Hardened Runtime is enabled (`ENABLE_HARDENED_RUNTIME = YES`, set by hand in `project.xcproj` because the Xcode settings tool silently didn't apply it). No runtime exceptions are needed: AX, Carbon hotkeys and the private AX symbol all work under it.

Release steps (needs a paid Developer Program membership and a Developer ID Application certificate):
1. Product → Archive (destination Any Mac).
2. Organizer → Distribute App → Direct Distribution: signs with Developer ID, notarizes, exports `voider.app`.
3. `hdiutil create -volname "Voider" -srcfolder voider.app -ov -format UDZO Voider.dmg` (or `create-dmg` for a drag-to-Applications window).
4. `spctl -a -vv voider.app` should say `accepted, source=Notarized Developer ID`.
5. Attach `Voider.dmg` to a GitHub Release (the README's install section links to Releases).

CLI alternative: `xcodebuild archive` / `xcodebuild -exportArchive`, then `xcrun notarytool submit Voider.dmg --wait` and `xcrun stapler staple Voider.dmg`.

## Known gaps

- No unit tests yet (no test target); config parsing was checked ad hoc.
- No config file watcher.
- Windows on other macOS Spaces are invisible to Voider.
- Single monitor assumed for parking position (uses the right-most screen edge and primary screen height).

## Conventions

- Swift Testing for unit tests; keep window/workspace logic testable without AX.
- Small, focused commits with conventional single-line messages and no Co-Authored-By lines.
