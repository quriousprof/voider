import Foundation
import Observation

/// Owns ~/.config/voider/voider.toml: creates it on first launch and (re)loads it.
@Observable
final class ConfigManager {
    let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voider", isDirectory: true)
    var fileURL: URL { directoryURL.appendingPathComponent("voider.toml") }

    private(set) var config: VoiderConfig
    /// Set when the last load failed; the previous good config stays active.
    private(set) var lastError: String?

    init() {
        // The default text is known-good, so this cannot fail.
        config = (try? VoiderConfig.parse(VoiderConfig.defaultText))
            ?? VoiderConfig(workspaces: VoiderConfig.defaultWorkspaces, bindings: [])
    }

    /// Creates the config directory and a default file if either is missing, then loads it.
    func bootstrap() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try VoiderConfig.defaultText.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            lastError = "Couldn't create config: \(error.localizedDescription)"
            return
        }
        load()
    }

    func load() {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            config = try VoiderConfig.parse(text)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
