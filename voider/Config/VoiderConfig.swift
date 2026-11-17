import Foundation

struct ConfigError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct VoiderConfig {
    var workspaces: [String]
    var bindings: [(action: Action, binding: KeyBinding)]
    /// When true, moving a window to another workspace also switches to that workspace.
    var followMovedWindow = false

    static let defaultWorkspaces = (0...9).map(String.init)

    /// Contents written to ~/.config/voider/voider.toml on first launch.
    static var defaultText: String {
        let names = defaultWorkspaces.map { "\"\($0)\"" }.joined(separator: ", ")
        let focus = defaultWorkspaces.map { "\"workspace \($0)\" = \"alt-\($0.lowercased())\"" }.joined(separator: "\n")
        let move = defaultWorkspaces.map { "\"move-to-workspace \($0)\" = \"alt-shift-\($0.lowercased())\"" }.joined(separator: "\n")
        return """
        # voider.toml — configuration for the voider menu bar app

        # Workspace names (digits and letters work, e.g. ["1", "2", "A", "B"]).
        # Windows start in the first one. If omitted, workspaces 0-9 are used.
        workspaces = [\(names)]

        # Switch to the target workspace after moving a window there (applies to every workspace).
        follow-moved-window = false

        # "action" = "modifiers-key"
        # Modifiers: alt, shift, cmd, ctrl. Keys: a-z, 0-9, space, tab, return, escape, arrows, ...
        # Actions: "workspace <name>", "move-to-workspace <name>", "reload-config"
        # If this whole table is omitted, alt-<name> / alt-shift-<name> are bound for every workspace.
        [keybindings]
        \(focus)
        \(move)
        "reload-config" = "alt-shift-r"

        """
    }

    static func parse(_ text: String) throws -> VoiderConfig {
        let doc: TOMLDocument
        do { doc = try TOMLParser.parse(text) } catch { throw ConfigError(message: "voider.toml \(error.localizedDescription)") }

        var workspaces = defaultWorkspaces
        if let value = doc.root["workspaces"] {
            guard case .array(let items) = value else { throw ConfigError(message: "`workspaces` must be an array") }
            workspaces = try items.map { item in
                switch item {
                case .string(let name): return name
                case .int(let number): return String(number)
                default: throw ConfigError(message: "`workspaces` entries must be strings")
                }
            }
            guard !workspaces.isEmpty else { throw ConfigError(message: "`workspaces` must not be empty") }
            // Names are case-insensitive, so `a` and `A` collapse into one workspace (first position wins).
            var seen = Set<String>()
            workspaces = workspaces.map(Action.normalize(workspace:)).filter { seen.insert($0).inserted }
        }

        var follow = false
        if let value = doc.root["follow-moved-window"] {
            guard case .bool(let flag) = value else { throw ConfigError(message: "`follow-moved-window` must be true or false") }
            follow = flag
        }

        guard let table = doc.tables["keybindings"] else {
            return VoiderConfig(workspaces: workspaces, bindings: defaultBindings(for: workspaces), followMovedWindow: follow)
        }

        var bindings: [(Action, KeyBinding)] = []
        for (name, value) in table.sorted(by: { $0.key < $1.key }) {
            guard case .string(let combo) = value else { throw ConfigError(message: "keybinding `\(name)` must be a string") }
            guard let action = Action(name) else { throw ConfigError(message: "unknown action `\(name)`") }
            switch action {
            case .focusWorkspace(let ws), .moveToWorkspace(let ws):
                guard workspaces.contains(ws) else { throw ConfigError(message: "`\(name)`: no workspace named `\(ws)`") }
            case .reloadConfig:
                break
            }
            guard let binding = KeyBinding(combo) else { throw ConfigError(message: "`\(name)`: invalid key `\(combo)`") }
            bindings.append((action, binding))
        }
        return VoiderConfig(workspaces: workspaces, bindings: bindings, followMovedWindow: follow)
    }

    /// `alt-<name>` focuses and `alt-shift-<name>` moves, for every workspace whose name is a valid key.
    /// Workspace bindings win over `alt-shift-r` (reload) if a workspace is named `r`.
    static func defaultBindings(for workspaces: [String]) -> [(action: Action, binding: KeyBinding)] {
        var result: [(action: Action, binding: KeyBinding)] = []
        var used = Set<KeyBinding>()
        func add(_ action: Action, _ combo: String) {
            guard let binding = KeyBinding(combo), used.insert(binding).inserted else { return }
            result.append((action, binding))
        }
        for name in workspaces { add(.focusWorkspace(name), "alt-\(name)") }
        for name in workspaces { add(.moveToWorkspace(name), "alt-shift-\(name)") }
        add(.reloadConfig, "alt-shift-r")
        return result
    }
}
