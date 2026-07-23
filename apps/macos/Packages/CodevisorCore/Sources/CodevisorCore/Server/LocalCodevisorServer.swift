import Foundation
import Observation

public enum LocalCodevisorServerState: Equatable, Sendable {
    case idle
    case alreadyRunning
    case started
    case unavailable(String)
}

public struct LocalCodevisorServerLaunchRequest: Equatable, Sendable {
    public var nodeExecutable: URL
    public var entrypoint: URL
    public var databasePath: String
    public var logURL: URL
    public var host: String
    public var port: Int
    public var name: String
    public var environment: [String: String]
    public var dataUpgradeStatusURL: URL? = nil
}

public struct LocalDataUpgradeProgress: Codable, Equatable, Sendable {
    public var state: String
    public var id: String
    public var name: String
    public var completed: Int
    public var total: Int
    public var error: String?

    public init(
        state: String,
        id: String,
        name: String,
        completed: Int,
        total: Int,
        error: String? = nil
    ) {
        self.state = state
        self.id = id
        self.name = name
        self.completed = completed
        self.total = total
        self.error = error
    }

    public var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct LocalCodevisorServerProcessConfiguration: Equatable {
    var executableURL: URL
    var arguments: [String]
}

@MainActor
@Observable
public final class LocalCodevisorServer {
    public typealias Launcher = @MainActor (LocalCodevisorServerLaunchRequest) throws -> Process
    public typealias ServerEnvironmentProvider = @MainActor () async -> [String: String]
    public typealias ListenerTerminator = @MainActor (Int) async -> Void

    private let client: any CodevisorServerClienting
    private let config: CodevisorServerConfig
    private let entrypoint: URL?
    private let nodeExecutable: URL
    private let databasePath: String
    private let logURL: URL
    private let dataUpgradeStatusURL: URL
    private let computerUseBridge: ComputerUseBridge?
    private let launcher: Launcher
    private let serverEnvironmentProvider: ServerEnvironmentProvider
    private let staleListenerTerminator: ListenerTerminator
    /// The server is intentionally not terminated with the app; it owns durable
    /// sessions and should keep running so clients can reconnect to live work.
    private var process: Process?
    /// In-flight `ensureRunning()`; concurrent callers (onboarding and the
    /// root view both prepare the machine on first launch) join it instead of
    /// racing past `currentHealth()` and double-launching the server.
    private var ensureTask: Task<LocalCodevisorServerState, Never>?

    public private(set) var state: LocalCodevisorServerState = .idle
    /// Sidecar progress remains available while the new server is performing
    /// its blocking migration and therefore cannot answer HTTP yet.
    public private(set) var dataUpgradeProgress: LocalDataUpgradeProgress?

    /// Invoked when the bundled server exits asking the app to take over the
    /// update: a remote client triggered a server update, but a server that
    /// lives inside the .app bundle can't replace that bundle, so it hands the
    /// update back here. The app runs its full update (swap bundle + relaunch).
    public var onUpdateRequested: (@MainActor () -> Void)?

    /// Exit status the bundled server uses to ask the app to perform the
    /// update instead of self-swapping a standalone runtime. Must match
    /// `APP_UPDATE_HANDOFF_EXIT_CODE` in apps/server/src/main.ts.
    public static let updateHandoffExitStatus: Int32 = 85

    public init(
        client: any CodevisorServerClienting,
        config: CodevisorServerConfig = .localDefault,
        entrypoint: URL? = LocalCodevisorServer.defaultEntrypoint(),
        nodeExecutable: URL = LocalCodevisorServer.defaultNodeExecutable(),
        databasePath: String = LocalCodevisorServer.defaultDatabasePath(),
        logURL: URL = LocalCodevisorServer.defaultLogURL(),
        dataUpgradeStatusURL: URL = LocalCodevisorServer.defaultDataUpgradeStatusURL(),
        computerUseBridge: ComputerUseBridge? = nil,
        serverEnvironmentProvider: @escaping ServerEnvironmentProvider = LocalCodevisorServer.defaultServerEnvironment,
        launcher: @escaping Launcher = LocalCodevisorServer.launchProcess,
        staleListenerTerminator: @escaping ListenerTerminator = { await LocalCodevisorServer.terminateListeners(onPort: $0) }
    ) {
        self.client = client
        self.config = config
        self.entrypoint = entrypoint
        self.nodeExecutable = nodeExecutable
        self.databasePath = databasePath
        self.logURL = logURL
        self.dataUpgradeStatusURL = dataUpgradeStatusURL
        self.computerUseBridge = computerUseBridge
        self.serverEnvironmentProvider = serverEnvironmentProvider
        self.launcher = launcher
        self.staleListenerTerminator = staleListenerTerminator
    }

    @discardableResult
    public func ensureRunning() async -> LocalCodevisorServerState {
        if let ensureTask {
            return await ensureTask.value
        }
        let task = Task { await performEnsureRunning() }
        ensureTask = task
        defer { ensureTask = nil }
        return await task.value
    }

    private func performEnsureRunning() async -> LocalCodevisorServerState {
        let computerUseConfiguration: ComputerUseBridge.Configuration?
        do {
            computerUseConfiguration = try computerUseBridge?.start()
        } catch {
            computerUseConfiguration = nil
            Log.server.error(
                "Computer Use bridge failed to start: \(String(describing: error), privacy: .public)"
            )
        }
        if let health = await currentHealth() {
            // A durable server left behind by an older app install keeps
            // serving across upgrades (`brew upgrade` replaces the bundle but
            // never touches the process). Replace it when the bundled runtime
            // is newer; the database lives outside the bundle, so the new
            // runtime picks it up and runs its own migrations.
            guard let bundledVersion = bundledServerVersion(),
                  AppUpdateModel.isVersion(bundledVersion, newerThan: health.version)
            else {
                state = .alreadyRunning
                return state
            }
            await stopStaleServer()
            if await isHealthy() {
                // The stale server survived both the shutdown request and the
                // signal; keep using it rather than failing outright.
                state = .alreadyRunning
                return state
            }
        }

        if let process, process.isRunning {
            return await waitUntilHealthy(process: process)
        }

        guard let entrypoint else {
            state = .unavailable("Codevisor server entrypoint was not found")
            return state
        }

        // Relocate pre-canonical server state now that no server is serving
        // it: any healthy-but-stale server was stopped above, and the launch
        // below opens the database at the canonical path.
        if databasePath == Self.defaultDatabasePath() {
            Self.migrateLegacyServerData()
        }

        do {
            var serverEnvironment = await serverEnvironmentProvider()
            // Marks this server as launched by (and living inside) the app
            // bundle, so its self-updater hands app-bundle updates back to us
            // instead of swapping a standalone runtime the next app launch
            // would discard.
            serverEnvironment["CODEVISOR_APP_HOSTED"] = "1"
            if let computerUseConfiguration {
                serverEnvironment["CODEVISOR_COMPUTER_USE_SOCKET"] = computerUseConfiguration.socketPath
                serverEnvironment["CODEVISOR_COMPUTER_USE_TOKEN"] = computerUseConfiguration.token
            }
            let request = LocalCodevisorServerLaunchRequest(
                nodeExecutable: nodeExecutable,
                entrypoint: entrypoint,
                databasePath: databasePath,
                logURL: logURL,
                host: Self.bindHost,
                port: port,
                name: Self.serverDisplayName(),
                environment: serverEnvironment,
                dataUpgradeStatusURL: dataUpgradeStatusURL
            )
            let launched = try launcher(request)
            process = launched
            observeTermination(of: launched)
            return await waitUntilHealthy(process: launched)
        } catch {
            state = .unavailable(String(describing: error))
            return state
        }
    }

    /// Stops the running local server so a newer bundled runtime can take over
    /// on the next launch. Asks politely over HTTP first (the server may not be
    /// a process we own), then force-terminates any owned process that lingers.
    public func shutdown() async {
        do {
            try await client.requestShutdown()
        } catch {
            // Expected when the server is already gone; termination follows.
            Log.server.debug(
                "Shutdown request failed: \(String(describing: error), privacy: .public)"
            )
        }
        for _ in 0..<20 {
            if !(await isHealthy()) { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        state = .idle
    }

    /// Watches the launched server for the update-handoff exit status, hopping
    /// to the main actor to invoke `onUpdateRequested`. Any other exit (a
    /// normal shutdown SIGTERM, a crash) is ignored — only the agreed status
    /// means "the app should update itself."
    private func observeTermination(of process: Process) {
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.handleTermination(status: status)
            }
        }
    }

    private func handleTermination(status: Int32) {
        guard status == Self.updateHandoffExitStatus else { return }
        onUpdateRequested?()
    }

    /// The version stamped into the bundled runtime next to its entrypoint.
    /// Nil in development runs (the repo tree has no VERSION file), which
    /// intentionally disables the stale-server replacement there.
    private func bundledServerVersion() -> String? {
        guard let entrypoint else { return nil }
        let versionURL = entrypoint.deletingLastPathComponent().appendingPathComponent("VERSION")
        let raw: String
        do {
            raw = try String(contentsOf: versionURL, encoding: .utf8)
        } catch {
            // Expected in development runs, where no VERSION file is stamped.
            Log.server.debug(
                "No bundled server VERSION file: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Stops a healthy-but-outdated server: politely over HTTP first, then —
    /// for servers that predate the shutdown endpoint — by signalling whatever
    /// still listens on the port.
    private func stopStaleServer() async {
        await shutdown()
        guard await isHealthy() else { return }
        await staleListenerTerminator(port)
        for _ in 0..<20 {
            if !(await isHealthy()) { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Sends SIGTERM to processes listening on the port. Only ever invoked
    /// against a confirmed stale Codevisor server that ignored `POST /v1/shutdown`.
    nonisolated public static func terminateListeners(onPort port: Int) async {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for pid in await listeningPids(onPort: port) where pid != ownPid {
            kill(pid, SIGTERM)
        }
    }

    nonisolated private static func listeningPids(onPort port: Int) async -> [pid_t] {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let pids = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                continuation.resume(returning: pids)
            }
            do {
                try process.run()
            } catch {
                Log.server.debug(
                    "lsof probe for port listeners failed: \(String(describing: error), privacy: .public)"
                )
                process.terminationHandler = nil
                continuation.resume(returning: [])
            }
        }
    }

    private func currentHealth() async -> ServerHealth? {
        do {
            let health = try await client.health()
            return health.ok ? health : nil
        } catch {
            // Expected when no server is running yet; launch follows.
            Log.server.debug(
                "Health probe failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// The server binds every interface so paired remote clients can reach it;
    /// only same-machine connections are exempt from its token auth. The app's
    /// own client still talks to it over loopback (`config.baseURL`).
    static let bindHost = "0.0.0.0"

    /// The server's advertised display name: the Mac's name, so a remote
    /// client's machine list shows "George's MacBook Pro 0.2.0" rather than a
    /// generic label.
    nonisolated static func serverDisplayName() -> String {
        Host.current().localizedName ?? "Local Codevisor"
    }

    private var port: Int {
        config.baseURL.port ?? CodevisorServerConfig.localPort
    }

    private func isHealthy() async -> Bool {
        do {
            return try await client.health().ok
        } catch {
            return false
        }
    }

    private func waitUntilHealthy(process: Process?) async -> LocalCodevisorServerState {
        // Breaking data upgrades are allowed to take minutes. Progress comes
        // from the sidecar, so this wait is bounded generously without making
        // the UI appear frozen.
        for _ in 0..<2400 {
            refreshDataUpgradeProgress()
            if await isHealthy() {
                refreshDataUpgradeProgress()
                state = .started
                return state
            }
            if let process, !process.isRunning {
                state = .unavailable("Codevisor server exited before becoming ready. See \(logURL.path)")
                return state
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        state = .unavailable("Timed out waiting for Codevisor server. See \(logURL.path)")
        return state
    }

    private func refreshDataUpgradeProgress() {
        // A missing status file is the normal no-upgrade-running case (and
        // this polls, so it stays unlogged); a file that exists but doesn't
        // decode hides real upgrade progress.
        guard let data = try? Data(contentsOf: dataUpgradeStatusURL) else { return }
        do {
            dataUpgradeProgress = try JSONDecoder().decode(LocalDataUpgradeProgress.self, from: data)
        } catch {
            Log.server.debug(
                "Failed to decode data-upgrade progress: \(String(describing: error), privacy: .public)"
            )
        }
    }

    public static func launchProcess(_ request: LocalCodevisorServerLaunchRequest) throws -> Process {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: request.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: request.logURL.path) {
            _ = fileManager.createFile(atPath: request.logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: request.logURL)
        try logHandle.seekToEnd()

        let process = Process()
        let configuration = processConfiguration(for: request)
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = request.environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }

    static func processConfiguration(
        for request: LocalCodevisorServerLaunchRequest
    ) -> LocalCodevisorServerProcessConfiguration {
        let nodeInvocation = request.nodeExecutable.lastPathComponent == "env"
            ? "node"
            : request.nodeExecutable.path
        return LocalCodevisorServerProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "-c",
                "exec -a codevisor-server \"$0\" \"$@\"",
                nodeInvocation,
                request.entrypoint.path,
                "serve",
                "--host", request.host,
                "--port", String(request.port),
                "--db", request.databasePath,
                // Network binds require a token from remote clients (loopback is
                // exempt), and --kind keeps the server identifying as this
                // machine's local server despite the 0.0.0.0 bind.
                "--auth", "token",
                "--kind", "local",
                "--name", request.name
            ] + (request.dataUpgradeStatusURL.map { ["--upgrade-status", $0.path] } ?? [])
        )
    }

    public static func defaultEntrypoint() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CODEVISOR_SERVER_ENTRYPOINT"]
            ?? environment["HERDMAN_SERVER_ENTRYPOINT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let bundledRuntimeDirectory = bundledServerRuntimeDirectory() {
            let entrypoint = bundledRuntimeDirectory.appendingPathComponent("main.js")
            if FileManager.default.fileExists(atPath: entrypoint.path) {
                return entrypoint
            }
        }

        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = directory.appendingPathComponent("apps/server/dist/main.js")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated public static func defaultNodeExecutable() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CODEVISOR_NODE"]
            ?? environment["HERDMAN_NODE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = bundledNodeExecutable() {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    nonisolated public static func bundledServerRuntimeDirectory(
        fileManager: FileManager = .default,
        resourcesURL: URL? = Bundle.main.resourceURL
    ) -> URL? {
        // Plain path arithmetic, not `Bundle.url(forResource:)`: that API
        // returns nil for resource directories in release bundles, which left
        // production installs unable to find the runtime at all.
        guard let resourcesURL else { return nil }
        let candidates = [
            resourcesURL.appendingPathComponent("server/\(bundledServerTarget)", isDirectory: true),
            resourcesURL.appendingPathComponent("Server/\(bundledServerTarget)", isDirectory: true),
            resourcesURL.appendingPathComponent("server", isDirectory: true),
            resourcesURL.appendingPathComponent("Server", isDirectory: true)
        ]
        return candidates.first { candidate in
            fileManager.fileExists(atPath: candidate.appendingPathComponent("main.js").path)
                && fileManager.isExecutableFile(atPath: candidate.appendingPathComponent("bin/node").path)
        }
    }

    nonisolated private static var bundledServerTarget: String {
        #if arch(x86_64)
            "darwin-x64"
        #else
            "darwin-arm64"
        #endif
    }

    nonisolated private static func bundledNodeExecutable(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let runtimeDirectory = bundledServerRuntimeDirectory(fileManager: fileManager) else {
            return nil
        }
        let executable = runtimeDirectory.appendingPathComponent("bin/node")
        return fileManager.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    public static func defaultServerEnvironment() async -> [String: String] {
        let probe = EnvironmentProbe()
        let path = await probe.resolvedPath()
        // Finder-launched production apps inherit a minimal PATH, so the Node
        // server must receive the same login-shell PATH that local ACP discovery
        // used before discovery moved server-side.
        return probe.resolvedEnvironment(path: path)
    }

    public static func defaultDatabasePath() -> String {
        CodevisorAppVariant.serverDataDirectoryURL()
            .appendingPathComponent("codevisor-server.sqlite").path
    }

    public static func defaultLogURL() -> URL {
        CodevisorAppVariant.serverLogsDirectoryURL().appendingPathComponent("server.log")
    }

    public static func defaultDataUpgradeStatusURL() -> URL {
        CodevisorAppVariant.serverDataDirectoryURL().appendingPathComponent("data-upgrade.json")
    }

    /// One-time move of server state from the pre-canonical Application
    /// Support location into ~/.codevisor, the layout shared with standalone
    /// installs. Only ever invoked right before launching a server against the
    /// default paths — never while a server may still be serving the old
    /// location. The database moves last so an interrupted migration resumes
    /// on the next launch instead of stranding sidecar files.
    static func migrateLegacyServerData(
        from legacyDirectory: URL = CodevisorAppVariant.applicationSupportURL(),
        toData dataDirectory: URL = CodevisorAppVariant.serverDataDirectoryURL(),
        logs logsDirectory: URL = CodevisorAppVariant.serverLogsDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        guard legacyDirectory.standardizedFileURL != dataDirectory.standardizedFileURL else {
            return
        }
        let databaseName = "codevisor-server.sqlite"
        guard fileManager.fileExists(atPath: legacyDirectory.appendingPathComponent(databaseName).path),
              !fileManager.fileExists(atPath: dataDirectory.appendingPathComponent(databaseName).path)
        else { return }

        let dataArtifacts = [
            "codevisor-server.sqlite-shm",
            "codevisor-server.sqlite-wal",
            "data-upgrade.json",
            "attachments",
            "server-updates",
            "harness-profiles",
            "harness-secrets",
            "mcp-secret-key",
            databaseName
        ]
        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let legacyLog = legacyDirectory.appendingPathComponent("server.log")
            let log = logsDirectory.appendingPathComponent("server.log")
            if fileManager.fileExists(atPath: legacyLog.path),
               !fileManager.fileExists(atPath: log.path) {
                try fileManager.moveItem(at: legacyLog, to: log)
            }
            for artifact in dataArtifacts {
                let source = legacyDirectory.appendingPathComponent(artifact)
                let destination = dataDirectory.appendingPathComponent(artifact)
                guard fileManager.fileExists(atPath: source.path),
                      !fileManager.fileExists(atPath: destination.path) else { continue }
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            Log.server.error(
                "Failed to migrate server data to \(dataDirectory.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
