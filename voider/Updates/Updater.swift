import AppKit
import Observation
import Security

/// Self-update from the repo's latest GitHub release: downloads `Voider.dmg`, checks that the app inside
/// is this app, at the release's version, signed with Developer ID by the same team and accepted by
/// Gatekeeper, swaps it in place of the running bundle, and launches it. The new copy then quits this one
/// through `SingleInstance`, which restores hidden windows as on any normal quit.
@Observable
final class Updater {
    struct Release: Equatable {
        let version: String
        let downloadURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        /// `release` is set when an install failed, so the menu can offer the manual download.
        case failed(String, release: Release?)
    }

    private(set) var state: State = .idle
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    @ObservationIgnored private var automaticChecks: Task<Void, Never>?
    @ObservationIgnored private var isChecking = false

    private static let latestReleaseAPI = "https://api.github.com/repos/quriousprof/voider/releases/latest"
    /// The release asset name; RELEASING.md keeps it fixed.
    private static let assetName = "Voider.dmg"

    // MARK: - Checking

    /// Checks quietly shortly after launch and then daily; failures stay silent.
    func startAutomaticChecks() {
        guard automaticChecks == nil else { return }
        automaticChecks = Task {
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await check(userInitiated: false)
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func checkForUpdates() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        if case .installing = state { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        if userInitiated { state = .checking }
        do {
            if let release = try await fetchLatestRelease(),
               release.version.compare(currentVersion, options: .numeric) == .orderedDescending {
                state = .available(release)
            } else if userInitiated {
                state = .upToDate
            }
        } catch {
            if userInitiated { state = .failed("Couldn't check for updates: \(error.localizedDescription)", release: nil) }
        }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    /// The latest published release (GitHub's `latest` skips drafts and prereleases), or nil if it has no DMG.
    private func fetchLatestRelease() async throws -> Release? {
        guard let url = URL(string: Self.latestReleaseAPI) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.expectOK(response)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else { return nil }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return Release(version: version, downloadURL: asset.browserDownloadURL, pageURL: release.htmlURL)
    }

    // MARK: - Installing

    func installUpdate() {
        guard case .available(let release) = state else { return }
        state = .installing(release)
        Task {
            do {
                try await install(release)
            } catch {
                state = .failed("Update failed: \(error.localizedDescription)", release: release)
            }
        }
    }

    private func install(_ release: Release) async throws {
        let fileManager = FileManager.default
        let appURL = Bundle.main.bundleURL
        let folder = appURL.deletingLastPathComponent()
        // Gatekeeper runs quarantined apps opened from Downloads from a read-only random path.
        guard !appURL.path.contains("/AppTranslocation/") else {
            throw UpdateError("Move Voider to the Applications folder, open it from there, and try again.")
        }
        guard fileManager.isWritableFile(atPath: folder.path) else {
            throw UpdateError("No permission to replace Voider in \(folder.path).")
        }
        guard let teamID = Self.teamIdentifier() else {
            throw UpdateError("This copy of Voider isn't signed, so an update can't be verified.")
        }

        // On the app's volume, so the final swap is a rename and can't leave a half-copied app behind.
        let work = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        defer { try? fileManager.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(from: release.downloadURL)
        try Self.expectOK(response)
        let dmg = work.appending(path: Self.assetName)
        try fileManager.moveItem(at: downloaded, to: dmg)

        let mountPoint = work.appending(path: "mount")
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try await Self.run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path)

        let staged = work.appending(path: appURL.lastPathComponent)
        var copyError: Error?
        do {
            let contents = try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("The download doesn't contain an app.")
            }
            try await Self.run("/usr/bin/ditto", newApp.path, staged.path)
        } catch {
            copyError = error
        }
        try? await Self.run("/usr/bin/hdiutil", "detach", mountPoint.path, "-force")
        if let copyError { throw copyError }

        try await Self.verify(staged, release: release, teamID: teamID)

        _ = try fileManager.replaceItemAt(appURL, withItemAt: staged)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw UpdateError("Voider \(release.version) is installed but didn't start. Quit Voider and open it again.")
        }
    }

    /// Refuses anything that isn't this app, at the advertised version, signed with Developer ID by our
    /// team, and accepted by Gatekeeper (notarized).
    private static func verify(_ app: URL, release: Release, teamID: String) async throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The downloaded app isn't Voider.")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == release.version else {
            throw UpdateError("The download is version \(version ?? "?"), expected \(release.version).")
        }

        var code: SecStaticCode?
        var requirement: SecRequirement?
        // Developer ID Application certificate issued to our team.
        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamID)\""
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError("The downloaded app's signature isn't valid.")
        }

        do {
            try await run("/usr/sbin/spctl", "--assess", "--type", "execute", app.path)
        } catch {
            throw UpdateError("Gatekeeper rejected the downloaded app.")
        }
    }

    // MARK: - Helpers

    /// Team ID the running app is signed with; nil for unsigned builds.
    private static func teamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func expectOK(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError("GitHub responded with status \(status).") }
    }

    /// Runs a command-line tool to completion; a non-zero exit status throws.
    private nonisolated static func run(_ path: String, _ arguments: String...) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError("\(URL(filePath: path).lastPathComponent) exited with status \(process.terminationStatus)."))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

nonisolated struct UpdateError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
