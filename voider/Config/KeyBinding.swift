import Carbon.HIToolbox

/// A key combination such as `alt-shift-1`, expressed in Carbon hotkey terms.
struct KeyBinding: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Parses `modifier-...-key`. Modifiers: alt/option, shift, cmd/command, ctrl/control.
    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard let keyName = parts.last, let code = Self.keyCodes[keyName] else { return nil }

        var modifiers: UInt32 = 0
        for name in parts.dropLast() {
            switch name {
            case "alt", "option", "opt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            default: return nil
            }
        }
        self.keyCode = code
        self.modifiers = modifiers
    }

    /// ANSI virtual key codes by name.
    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26,
        "minus": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "k": 40, "semicolon": 41, "comma": 43, "n": 45, "m": 46,
        "period": 47, "tab": 48, "space": 49, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}

/// Something a hotkey can trigger.
enum Action: Equatable {
    case focusWorkspace(String)
    case moveToWorkspace(String)
    /// Toggles between the current and the previously active workspace.
    case workspaceBackAndForth
    case reloadConfig

    /// Workspace names are case-insensitive: `a` and `A` are the same workspace, stored as `A`.
    static func normalize(workspace name: String) -> String { name.uppercased() }

    /// Parses `workspace N`, `move-to-workspace N`, `workspace-back-and-forth` or `reload-config`.
    init?(_ text: String) {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        switch (parts.first, parts.count) {
        case ("workspace", 2): self = .focusWorkspace(Self.normalize(workspace: parts[1]))
        case ("move-to-workspace", 2): self = .moveToWorkspace(Self.normalize(workspace: parts[1]))
        case ("workspace-back-and-forth", 1): self = .workspaceBackAndForth
        case ("reload-config", 1): self = .reloadConfig
        default: return nil
        }
    }
}
