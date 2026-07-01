import ACPAgents
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
    public var environment: [String: String]
}

@MainActor
public final class LocalHerdManServer {
    public typealias Launcher = @MainActor (LocalHerdManServerLaunchRequest) throws -> Process
    public typealias ServerEnvironmentProvider = @MainActor () async -> [String: String]

    private let client: any HerdManServerClienting
    private let config: HerdManServerConfig
    private let entrypoint: URL?
    private let nodeExecutable: URL
    private let databasePath: String
    private let logURL: URL
    private let launcher: Launcher
    private let serverEnvironmentProvider: ServerEnvironmentProvider
    /// The server is intentionally not terminated with the app; it owns durable
    /// sessions and should keep running so clients can reconnect to live work.
    private var process: Process?

    public private(set) var state: LocalHerdManServerState = .idle

    public init(
        client: any HerdManServerClienting,
        config: HerdManServerConfig = .localDefault,
        entrypoint: URL? = LocalHerdManServer.defaultEntrypoint(),
        nodeExecutable: URL = LocalHerdManServer.defaultNodeExecutable(),
        databasePath: String = LocalHerdManServer.defaultDatabasePath(),
        logURL: URL = LocalHerdManServer.defaultLogURL(),
        serverEnvironmentProvider: @escaping ServerEnvironmentProvider = LocalHerdManServer.defaultServerEnvironment,
        launcher: @escaping Launcher = LocalHerdManServer.launchProcess
    ) {
        self.client = client
        self.config = config
        self.entrypoint = entrypoint
        self.nodeExecutable = nodeExecutable
        self.databasePath = databasePath
        self.logURL = logURL
        self.serverEnvironmentProvider = serverEnvironmentProvider
        self.launcher = launcher
    }

    @discardableResult
    public func ensureRunning() async -> LocalHerdManServerState {
        if await isHealthy() {
            state = .alreadyRunning
            return state
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
                host: host,
                port: port,
                environment: serverEnvironment
            )
            process = try launcher(request)
            return await waitUntilHealthy(process: process)
        } catch {
            state = .unavailable(String(describing: error))
            return state
        }
    }

    private var host: String {
        config.baseURL.host ?? "127.0.0.1"
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
        process.executableURL = request.nodeExecutable
        let nodeArguments = request.nodeExecutable.lastPathComponent == "env" ? ["node"] : []
        process.arguments = nodeArguments + [
            request.entrypoint.path,
            "serve",
            "--host", request.host,
            "--port", String(request.port),
            "--db", request.databasePath
        ]
        process.environment = request.environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }

    public static func defaultEntrypoint() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["HERDMAN_SERVER_ENTRYPOINT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let bundledCandidates = [
            Bundle.main.url(forResource: "main", withExtension: "js", subdirectory: "server"),
            Bundle.main.url(forResource: "main", withExtension: "js", subdirectory: "Server"),
            Bundle.main.url(forResource: "herdman-server", withExtension: "js")
        ].compactMap { $0 }
        if let bundled = bundledCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return bundled
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
