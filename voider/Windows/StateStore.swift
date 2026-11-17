import Foundation

struct SavedWindow: Codable {
    let pid: Int32
    let workspace: String
    /// Original position if the window was parked off-screen when saved.
    let hiddenFrom: CGPoint?
}

struct SavedState: Codable {
    let activeWorkspace: String
    /// Keyed by CGWindowID (as a string, so the JSON stays a plain object).
    var windows: [String: SavedWindow]
}

/// Persists workspace assignments and hidden-window positions to ~/.config/voider/state.json,
/// so a crash or a killed debug session can't strand windows off-screen.
enum StateStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/voider/state.json")
    }

    static func load() -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    static func save(_ state: SavedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
