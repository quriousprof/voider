import Foundation

struct ConfigError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct VoiderConfig {
    var workspaces: [String]
    var bindings: [(action: Action, binding: KeyBinding)]

    static let defaultWorkspaces = (1...9).map(String.init)

    /// Contents written to ~/.config/voider/voider.toml on first launch.
    static var defaultText: String {
        let names = defaultWorkspaces.map { "\"\($0)\"" }.joined(separator: ", ")
        let focus = defaultWorkspaces.map { "\"workspace \($0)\" = \"alt-\($0)\"" }.joined(separator: "\n")
        let move = defaultWorkspaces.map { "\"move-to-workspace \($0)\" = \"alt-shift-\($0)\"" }.joined(separator: "\n")
        return """
        # voider.toml — configuration for the voider menu bar app

        # Workspace names. Windows start in the first one.
        workspaces = [\(names)]

        # "action" = "modifiers-key"
        # Modifiers: alt, shift, cmd, ctrl. Keys: a-z, 0-9, space, tab, return, escape, arrows, ...
        # Actions: "workspace <name>", "move-to-workspace <name>", "reload-config"
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
            guard Set(workspaces).count == workspaces.count else { throw ConfigError(message: "`workspaces` has duplicates") }
        }

        guard let table = doc.tables["keybindings"] else {
            return try parse(VoiderConfig.defaultText, overridingWorkspaces: workspaces)
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
        return VoiderConfig(workspaces: workspaces, bindings: bindings)
    }

    /// Used when the file has no `[keybindings]` table: default bindings for the given workspaces.
    private static func parse(_ defaults: String, overridingWorkspaces workspaces: [String]) throws -> VoiderConfig {
        var config = try parse(defaults)
        config.workspaces = workspaces
        config.bindings = config.bindings.filter {
            switch $0.action {
            case .focusWorkspace(let ws), .moveToWorkspace(let ws): return workspaces.contains(ws)
            case .reloadConfig: return true
            }
        }
        return config
    }
}
