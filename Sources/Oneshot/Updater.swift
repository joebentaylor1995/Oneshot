import AppKit

/// Keeps Oneshot up to date by building it from GitHub on this Mac.
///
/// A private clone lives in ~/Library/Application Support/Oneshot/Source. Every build is stamped
/// with its git commit (OneshotCommit in Info.plist), so comparing that with origin/main tells us
/// whether a newer version exists. Installing pulls, runs build.sh (which signs with the same local
/// certificate, so permissions survive) and relaunches the app.
@MainActor
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(count: Int, summary: String)
        case updating
        case failed(String)
    }

    static let repositoryURL = "https://github.com/joebentaylor1995/Oneshot.git"
    static let branch = "main"
    private static let checkInterval: TimeInterval = 30 * 60

    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?
    /// True while recording or editing, so automatic installs wait.
    var isBusy: () -> Bool = { false }

    let builtCommit = Bundle.main.object(forInfoDictionaryKey: "OneshotCommit") as? String ?? "unknown"
    let builtSubject = Bundle.main.object(forInfoDictionaryKey: "OneshotCommitSubject") as? String ?? ""
    private var timer: Timer?
    private var installProcess: Process?

    var installsAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    var shortVersion: String {
        builtCommit == "unknown" ? "local build" : String(builtCommit.prefix(7))
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Oneshot", isDirectory: true)
    }

    static var sourceDirectory: URL { supportDirectory.appendingPathComponent("Source", isDirectory: true) }

    static var logURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Oneshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("update.log")
    }

    // MARK: Lifecycle

    func start() {
        Task { await check() }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The commit message of the version that's now running, if it changed since the last launch.
    func consumeJustUpdatedMessage() -> String? {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "lastRunCommit")
        defaults.set(builtCommit, forKey: "lastRunCommit")
        guard let previous, previous != builtCommit, builtCommit != "unknown" else { return nil }
        return builtSubject.isEmpty ? "Oneshot is now on version \(shortVersion)." : builtSubject
    }

    // MARK: Checking

    func check(userInitiated: Bool = false) async {
        switch state {
        case .checking, .updating: return
        default: break
        }
        state = .checking

        let source = Self.sourceDirectory.path
        let script = """
        set -e
        mkdir -p "\(Self.supportDirectory.path)"
        if [ ! -d "\(source)/.git" ]; then
          rm -rf "\(source)"
          git clone --quiet --branch \(Self.branch) "\(Self.repositoryURL)" "\(source)"
        fi
        cd "\(source)"
        git fetch --quiet origin \(Self.branch)
        echo "REMOTE=$(git rev-parse origin/\(Self.branch))"
        echo "SUBJECT=$(git log -1 --format=%s origin/\(Self.branch))"
        echo "COUNT=$(git rev-list --count \(builtCommit)..origin/\(Self.branch) 2>/dev/null || echo 0)"
        """
        let result = await Self.run(script)
        guard result.status == 0 else {
            Self.appendLog("Update check failed:\n\(result.output)")
            state = .failed(Self.describe(result.output))
            return
        }

        var values: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let remote = values["REMOTE"], !remote.isEmpty else {
            state = .failed("Couldn't read the latest version from GitHub.")
            return
        }

        if remote == builtCommit {
            state = .upToDate
            return
        }
        let count = max(1, Int(values["COUNT"] ?? "") ?? 1)
        state = .available(count: count, summary: values["SUBJECT"] ?? "")

        if !userInitiated, installsAutomatically, !isBusy() {
            install()
        }
    }

    // MARK: Installing

    /// Pulls, builds and installs in a separate process. build.sh quits and relaunches Oneshot
    /// once the new build is ready; if anything fails, this copy keeps running.
    func install() {
        guard state != .updating else { return }
        guard Self.hasDeveloperTools else {
            state = .failed("Xcode's command line tools are needed to build updates.")
            return
        }
        state = .updating

        let source = Self.sourceDirectory.path
        let log = Self.logURL.path
        let script = """
        {
          echo ""
          echo "=== Update started $(date) ==="
          set -e
          cd "\(source)"
          git fetch --quiet origin \(Self.branch)
          git reset --hard --quiet origin/\(Self.branch)
          git log -1 --format='Building %h  %s'
          bash build.sh install
          echo "=== Update finished $(date) ==="
        } >> "\(log)" 2>&1
        """
        let process = Self.makeProcess(script)
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                // On success build.sh has already relaunched the new Oneshot and quit this one.
                guard let self, status != 0 else { return }
                self.state = .failed("The update didn't build. This version is still installed.")
            }
        }
        do {
            try process.run()
            installProcess = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func showLog() {
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: Data())
        }
        NSWorkspace.shared.open(Self.logURL)
    }

    // MARK: Helpers

    private static var hasDeveloperTools: Bool {
        FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/swift")
            || FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/swift")
            || FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
    }

    private static func describe(_ output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("authentication") || lower.contains("could not read username") || lower.contains("repository not found") {
            return "Couldn't sign in to GitHub to check for updates."
        }
        if lower.contains("could not resolve host") || lower.contains("unable to access") {
            return "Couldn't reach GitHub. Check your connection."
        }
        return "Couldn't check for updates."
    }

    private static func appendLog(_ text: String) {
        let line = "\n=== \(Date()) ===\n\(text)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    nonisolated private static func makeProcess(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0" // never hang waiting for a password
        process.environment = environment
        return process
    }

    nonisolated private static func run(_ script: String) async -> (status: Int32, output: String) {
        await Task.detached(priority: .utility) {
            let process = makeProcess(script)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (Int32(-1), error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
