import AppKit

/// Updates Oneshot from GitHub Releases.
///
/// Each release (made with release.sh) carries a ready-built, signed Oneshot-x.y.z.zip. Checking
/// asks GitHub for the latest release and compares its version with this build's; installing
/// downloads the zip, checks it's a validly signed Oneshot, then swaps it in place of this copy and
/// relaunches. Nothing is built on this Mac and nothing happens in the background: both steps are
/// started from the menu.
@MainActor
final class Updater {
    struct Release: Equatable {
        let version: String
        let notes: String
        let download: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing
        case failed(String)
    }

    static let repository = "joebentaylor1995/Oneshot"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let builtCommit = Bundle.main.object(forInfoDictionaryKey: "OneshotCommit") as? String ?? "unknown"

    /// "2.1" or, for a build with a known commit, "2.1 (6857efc)".
    var displayVersion: String {
        builtCommit == "unknown" ? version : "\(version) (\(builtCommit.prefix(7)))"
    }

    /// A short note for the first launch after an update, if the version changed since last time.
    func consumeJustUpdatedMessage() -> String? {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "lastRunVersion")
        defaults.set(version, forKey: "lastRunVersion")
        guard let previous, previous != version else { return nil }
        return "You're now on Oneshot \(version)."
    }

    // MARK: Checking

    func check() async {
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking

        var request = URLRequest(url: Self.latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Oneshot/\(version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            case 404:
                state = .failed("No releases have been published yet.")
                return
            case 403, 429:
                state = .failed("GitHub is limiting requests right now. Try again in a few minutes.")
                return
            case let code:
                state = .failed("GitHub returned an error (\(code)). Try again later.")
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard Self.compare(latest, version) == .orderedDescending else {
                state = .upToDate
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                state = .failed("Oneshot \(latest) doesn't have a download attached yet.")
                return
            }
            state = .available(Release(version: latest, notes: release.body ?? "", download: asset.downloadURL))
        } catch {
            state = .failed("Couldn't reach GitHub. Check your connection and try again.")
        }
    }

    // MARK: Installing

    /// Downloads and verifies the release, then quits; a small helper swaps the app and relaunches it.
    func install(_ release: Release) async {
        guard state != .installing else { return }
        state = .installing
        do {
            let installed = Bundle.main.bundleURL
            try Self.checkCanReplace(installed)

            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("OneshotUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            var request = URLRequest(url: release.download)
            request.setValue("Oneshot/\(version)", forHTTPHeaderField: "User-Agent")
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("The download didn't finish. Try again.")
            }
            let zip = work.appendingPathComponent("Oneshot.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)

            guard await Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else {
                throw UpdateError("The download looks damaged. Try again.")
            }
            let fresh = work.appendingPathComponent("Oneshot.app")
            guard Bundle(url: fresh)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download isn't a copy of Oneshot.")
            }
            guard await Self.runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path]) == 0 else {
                throw UpdateError("The download's signature isn't valid, so it wasn't installed.")
            }
            _ = await Self.runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path])

            try Self.launchSwapper(replacing: installed, with: fresh, workDirectory: work)
            NSApp.terminate(nil)
        } catch let error as UpdateError {
            state = .failed(error.message)
        } catch {
            state = .failed("The update couldn't be installed: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let body: String?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body, assets
        }
    }

    /// Numeric comparison of dotted versions ("2.10" is newer than "2.9").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func checkCanReplace(_ installed: URL) throws {
        let path = installed.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            throw UpdateError("Drag Oneshot into your Applications folder and open it from there, then try again.")
        }
        guard FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            throw UpdateError("Oneshot can't replace itself in \(installed.deletingLastPathComponent().path). Download the update from GitHub instead.")
        }
    }

    /// Starts a detached script that waits for this process to quit, moves the old app aside,
    /// puts the new one in its place (restoring the old one if that fails) and opens it.
    private static func launchSwapper(replacing installed: URL, with fresh: URL, workDirectory: URL) throws {
        func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = workDirectory.appendingPathComponent("Previous.app")
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if mv \(quoted(installed)) \(quoted(old)); then
          if ! mv \(quoted(fresh)) \(quoted(installed)); then mv \(quoted(old)) \(quoted(installed)); fi
        fi
        touch \(quoted(installed))
        open \(quoted(installed))
        sleep 2
        rm -rf \(quoted(workDirectory))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    nonisolated private static func runTool(_ path: String, _ arguments: [String]) async -> Int32 {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return Int32(-1)
            }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}
