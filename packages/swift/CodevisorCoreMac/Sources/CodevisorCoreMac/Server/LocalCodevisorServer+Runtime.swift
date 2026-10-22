import CodevisorCore
import Foundation
import Observation

extension LocalCodevisorServer {
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
    let nodeInvocation =
      request.nodeExecutable.lastPathComponent == "env"
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
        "--preferred-port", String(request.port),
        "--db", request.databasePath,
        "--auth", "token",
        "--kind", "local",
        "--name", request.name,
        "--boot-id", request.bootId,
        "--app-owned", "1",
        "--owner-pid", String(request.ownerPid),
      ] + (request.dataUpgradeStatusURL.map { ["--upgrade-status", $0.path] } ?? [])
    )
  }

  public static func defaultEntrypoint() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["CODEVISOR_SERVER_ENTRYPOINT"]
      ?? environment["HERDMAN_SERVER_ENTRYPOINT"], !override.isEmpty
    {
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
      ?? environment["HERDMAN_NODE"], !override.isEmpty
    {
      return URL(fileURLWithPath: override)
    }
    if let bundled = bundledNodeExecutable() {
      return bundled
    }
    let candidates = [
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node",
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
    guard let resourcesURL else { return nil }
    let candidates = [
      resourcesURL.appendingPathComponent("server/\(bundledServerTarget)", isDirectory: true),
      resourcesURL.appendingPathComponent("Server/\(bundledServerTarget)", isDirectory: true),
      resourcesURL.appendingPathComponent("server", isDirectory: true),
      resourcesURL.appendingPathComponent("Server", isDirectory: true),
    ]
    return candidates.first { candidate in
      fileManager.fileExists(atPath: candidate.appendingPathComponent("main.js").path)
        && fileManager.isExecutableFile(atPath: candidate.appendingPathComponent("bin/node").path)
    }
  }

  nonisolated private static let bundledServerTarget = "darwin-arm64"

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

  public static func defaultAppUpdateRequestURL() -> URL {
    CodevisorAppVariant.serverDataDirectoryURL()
      .appendingPathComponent("app-update-request.json")
  }

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
      databaseName,
    ]
    do {
      try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
      let legacyLog = legacyDirectory.appendingPathComponent("server.log")
      let log = logsDirectory.appendingPathComponent("server.log")
      if fileManager.fileExists(atPath: legacyLog.path),
        !fileManager.fileExists(atPath: log.path)
      {
        try fileManager.moveItem(at: legacyLog, to: log)
      }
      for artifact in dataArtifacts {
        let source = legacyDirectory.appendingPathComponent(artifact)
        let destination = dataDirectory.appendingPathComponent(artifact)
        guard fileManager.fileExists(atPath: source.path),
          !fileManager.fileExists(atPath: destination.path)
        else { continue }
        try fileManager.moveItem(at: source, to: destination)
      }
    } catch {
      Log.server.error(
        "Failed to migrate server data to \(dataDirectory.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }
}
