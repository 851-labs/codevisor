import Foundation

public enum LocalHerdManServerState: Equatable, Sendable {
    case idle
    case alreadyRunning
    case started
    case unavailable(String)
}

public struct LocalHerdManServerLaunchRequest: Equatable, Sendable {
    public var nodeExecutable: URL
    public var entrypoint: URL
    public var databasePath: String
    public var logURL: URL
    public var host: String
    public var port: Int
    public var name: String
    public var environment: [String: String]
}

struct LocalHerdManServerProcessConfiguration: Equatable {
    var executableURL: URL
    var arguments: [String]
}

@MainActor
public final class LocalHerdManServer {
    public typealias Launcher = @MainActor (LocalHerdManServerLaunchRequest) throws -> Process
    public typealias ServerEnvironmentProvider = @MainActor () async -> [String: String]
    public typealias ListenerTerminator = @MainActor (Int) async -> Void

    private let client: any HerdManServerClienting
    private let config: HerdManServerConfig
    private let entrypoint: URL?
    private let nodeExecutable: URL
    private let databasePath: String
    private let logURL: URL
    private let launcher: Launcher
    private let serverEnvironmentProvider: ServerEnvironmentProvider
    private let staleListenerTerminator: ListenerTerminator
    /// The server is intentionally not terminated with the app; it owns durable
    /// sessions and should keep running so clients can reconnect to live work.
    private var process: Process?
    /// In-flight `ensureRunning()`; concurrent callers (onboarding and the
    /// root view both prepare the machine on first launch) join it instead of
    /// racing past `currentHealth()` and double-launching the server.
    private var ensureTask: Task<LocalHerdManServerState, Never>?

    public private(set) var state: LocalHerdManServerState = .idle

    public init(
        client: any HerdManServerClienting,
        config: HerdManServerConfig = .localDefault,
        entrypoint: URL? = LocalHerdManServer.defaultEntrypoint(),
        nodeExecutable: URL = LocalHerdManServer.defaultNodeExecutable(),
        databasePath: String = LocalHerdManServer.defaultDatabasePath(),
        logURL: URL = LocalHerdManServer.defaultLogURL(),
        serverEnvironmentProvider: @escaping ServerEnvironmentProvider = LocalHerdManServer.defaultServerEnvironment,
        launcher: @escaping Launcher = LocalHerdManServer.launchProcess,
        staleListenerTerminator: @escaping ListenerTerminator = { await LocalHerdManServer.terminateListeners(onPort: $0) }
    ) {
        self.client = client
        self.config = config
        self.entrypoint = entrypoint
        self.nodeExecutable = nodeExecutable
        self.databasePath = databasePath
        self.logURL = logURL
        self.serverEnvironmentProvider = serverEnvironmentProvider
        self.launcher = launcher
        self.staleListenerTerminator = staleListenerTerminator
    }

    @discardableResult
    public func ensureRunning() async -> LocalHerdManServerState {
        if let ensureTask {
            return await ensureTask.value
        }
        let task = Task { await performEnsureRunning() }
        ensureTask = task
        defer { ensureTask = nil }
        return await task.value
    }

    private func performEnsureRunning() async -> LocalHerdManServerState {
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
            state = .unavailable("HerdMan server entrypoint was not found")
            return state
        }

        do {
            let serverEnvironment = await serverEnvironmentProvider()
            let request = LocalHerdManServerLaunchRequest(
                nodeExecutable: nodeExecutable,
                entrypoint: entrypoint,
                databasePath: databasePath,
                logURL: logURL,
                host: Self.bindHost,
                port: port,
                name: Self.serverDisplayName(),
                environment: serverEnvironment
            )
            process = try launcher(request)
            return await waitUntilHealthy(process: process)
        } catch {
            state = .unavailable(String(describing: error))
            return state
        }
    }

    /// Stops the running local server so a newer bundled runtime can take over
    /// on the next launch. Asks politely over HTTP first (the server may not be
    /// a process we own), then force-terminates any owned process that lingers.
    public func shutdown() async {
        try? await client.requestShutdown()
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

    /// The version stamped into the bundled runtime next to its entrypoint.
    /// Nil in development runs (the repo tree has no VERSION file), which
    /// intentionally disables the stale-server replacement there.
    private func bundledServerVersion() -> String? {
        guard let entrypoint else { return nil }
        let versionURL = entrypoint.deletingLastPathComponent().appendingPathComponent("VERSION")
        guard let raw = try? String(contentsOf: versionURL, encoding: .utf8) else { return nil }
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
    /// against a confirmed stale HerdMan server that ignored `POST /v1/shutdown`.
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
                process.terminationHandler = nil
                continuation.resume(returning: [])
            }
        }
    }

    private func currentHealth() async -> ServerHealth? {
        guard let health = try? await client.health(), health.ok else { return nil }
        return health
    }

    /// The server binds every interface so paired remote clients can reach it;
    /// only same-machine connections are exempt from its token auth. The app's
    /// own client still talks to it over loopback (`config.baseURL`).
    static let bindHost = "0.0.0.0"

    /// The server's advertised display name: the Mac's name, so a remote
    /// client's machine list shows "George's MacBook Pro 0.2.0" rather than a
    /// generic label.
    nonisolated static func serverDisplayName() -> String {
        Host.current().localizedName ?? "Local HerdMan"
    }

    private var port: Int {
        config.baseURL.port ?? HerdManServerConfig.localPort
    }

    private func isHealthy() async -> Bool {
        do {
            return try await client.health().ok
        } catch {
            return false
        }
    }

    private func waitUntilHealthy(process: Process?) async -> LocalHerdManServerState {
        for _ in 0..<40 {
            if await isHealthy() {
                state = .started
                return state
            }
            if let process, !process.isRunning {
                state = .unavailable("HerdMan server exited before becoming ready. See \(logURL.path)")
                return state
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        state = .unavailable("Timed out waiting for HerdMan server. See \(logURL.path)")
        return state
    }

    public static func launchProcess(_ request: LocalHerdManServerLaunchRequest) throws -> Process {
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
        for request: LocalHerdManServerLaunchRequest
    ) -> LocalHerdManServerProcessConfiguration {
        let nodeInvocation = request.nodeExecutable.lastPathComponent == "env"
            ? "node"
            : request.nodeExecutable.path
        return LocalHerdManServerProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "-c",
                "exec -a herdman-server \"$0\" \"$@\"",
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
            ]
        )
    }

    public static func defaultEntrypoint() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["HERDMAN_SERVER_ENTRYPOINT"], !override.isEmpty {
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
        if let override = environment["HERDMAN_NODE"], !override.isEmpty {
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
        applicationSupportURL().appendingPathComponent("herdman-server.sqlite").path
    }

    public static func defaultLogURL() -> URL {
        applicationSupportURL().appendingPathComponent("server.log")
    }

    private static func applicationSupportURL() -> URL {
        HerdManAppVariant.applicationSupportURL()
    }
}
