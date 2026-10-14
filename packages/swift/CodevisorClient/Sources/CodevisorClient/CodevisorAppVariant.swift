import Foundation

public enum CodevisorAppVariant: Sendable {
  public static let productionPort = 49_361
  public static let developmentPort = 49_362

  private static let stashedEnvironmentKey = "dev.launchEnvironment"

  private static let resolvedEnvironment: [String: String] = {
    let live = ProcessInfo.processInfo.environment
    guard isDevelopment else { return live }
    let resolution = resolvedDevelopmentEnvironment(
      live: live,
      stashed: UserDefaults.standard.dictionary(forKey: stashedEnvironmentKey)
        as? [String: String]
    )
    if let stash = resolution.stash {
      UserDefaults.standard.set(stash, forKey: stashedEnvironmentKey)
    }
    return resolution.environment
  }()

  static func resolvedDevelopmentEnvironment(
    live: [String: String],
    stashed: [String: String]?
  ) -> (environment: [String: String], stash: [String: String]?) {
    let devPrefixes = ["CODEVISOR_", "HERDMAN_"]
    let isConfigured =
      live["CODEVISOR_DEV_INSTANCE_ID"] != nil
      || live["HERDMAN_DEV_INSTANCE_ID"] != nil
    if isConfigured {
      let stash = live.filter { pair in
        devPrefixes.contains { pair.key.hasPrefix($0) }
      }
      return (live, stash)
    }
    guard let stashed, !stashed.isEmpty else { return (live, nil) }
    return (live.merging(stashed) { liveValue, _ in liveValue }, nil)
  }

  private static var environment: [String: String] {
    resolvedEnvironment
  }

  public static var isDevelopment: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  public static var localServerPort: Int {
    guard isDevelopment else { return productionPort }
    return (environment["CODEVISOR_DEV_PORT"] ?? environment["HERDMAN_DEV_PORT"])
      .flatMap(Int.init) ?? developmentPort
  }

  public static var developmentWorktreeName: String {
    guard isDevelopment else { return "" }
    return environment["CODEVISOR_DEV_WORKTREE"]
      ?? environment["HERDMAN_DEV_WORKTREE"]
      ?? "default"
  }

  public static var developmentInstanceID: String? {
    guard isDevelopment else { return nil }
    return environment["CODEVISOR_DEV_INSTANCE_ID"]
      ?? environment["HERDMAN_DEV_INSTANCE_ID"]
  }

  public static var developmentIconColorHex: String {
    guard isDevelopment else { return "#000000" }
    return environment["CODEVISOR_DEV_ICON_COLOR"] ?? "#0088ff"
  }

  public static var developmentSparkleFeedURL: String? {
    guard isDevelopment,
      let value = environment["CODEVISOR_DEV_SPARKLE_FEED_URL"],
      !value.isEmpty
    else { return nil }
    return value
  }

  public static var enablesSparkleUpdater: Bool {
    !isDevelopment || developmentSparkleFeedURL != nil
  }

  public struct DevelopmentCloud: Sendable, Equatable {
    public let url: URL

    public init(url: URL) {
      self.url = url
    }
  }

  public static var developmentCloud: DevelopmentCloud? {
    guard isDevelopment else { return nil }
    return developmentCloud(from: environment)
  }

  static func developmentCloud(from environment: [String: String]) -> DevelopmentCloud? {
    guard let raw = environment["CODEVISOR_DEV_CLOUD_URL"], !raw.isEmpty,
      let url = URL(string: raw)
    else { return nil }
    return DevelopmentCloud(url: url)
  }

  public static var applicationSupportDirectoryName: String {
    guard isDevelopment else { return "Codevisor" }
    guard let developmentInstanceID, !developmentInstanceID.isEmpty else {
      return "Codevisor Development"
    }
    return "Codevisor Development/\(developmentInstanceID)"
  }

  public static func applicationSupportURL(fileManager: FileManager = .default) -> URL {
    if isDevelopment,
      let override = environment["CODEVISOR_DEV_DATA_DIR"]
        ?? environment["HERDMAN_DEV_DATA_DIR"],
      !override.isEmpty
    {
      return createdDirectory(
        at: URL(fileURLWithPath: override, isDirectory: true),
        fileManager: fileManager
      )
    }
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? Self.homeDirectory(fileManager: fileManager).appendingPathComponent("Library/Application Support")
    return createdDirectory(
      at: base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true),
      fileManager: fileManager
    )
  }

  public static func cacheURL(fileManager: FileManager = .default) -> URL {
    if isDevelopment,
      let override = environment["CODEVISOR_DEV_CACHE_DIR"],
      !override.isEmpty
    {
      return createdDirectory(
        at: URL(fileURLWithPath: override, isDirectory: true),
        fileManager: fileManager
      )
    }
    let base =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return createdDirectory(
      at: base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true),
      fileManager: fileManager
    )
  }

  public static func legacyApplicationSupportURL(
    fileManager: FileManager = .default
  ) -> URL? {
    guard !isDevelopment else { return nil }
    let base =
      fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      ?? Self.homeDirectory(fileManager: fileManager)
      .appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("HerdMan", isDirectory: true)
  }

  public static func serverDataDirectoryURL(fileManager: FileManager = .default) -> URL {
    guard !isDevelopment else { return applicationSupportURL(fileManager: fileManager) }
    return createdDirectory(
      at: Self.homeDirectory(fileManager: fileManager)
        .appendingPathComponent(".codevisor/data", isDirectory: true),
      fileManager: fileManager
    )
  }

  public static func serverLogsDirectoryURL(fileManager: FileManager = .default) -> URL {
    if isDevelopment,
      let override = environment["CODEVISOR_DEV_LOGS_DIR"],
      !override.isEmpty
    {
      return createdDirectory(
        at: URL(fileURLWithPath: override, isDirectory: true),
        fileManager: fileManager
      )
    }
    guard !isDevelopment else { return applicationSupportURL(fileManager: fileManager) }
    return createdDirectory(
      at: Self.homeDirectory(fileManager: fileManager)
        .appendingPathComponent(".codevisor/logs", isDirectory: true),
      fileManager: fileManager
    )
  }

  private static func homeDirectory(fileManager: FileManager) -> URL {
    #if os(macOS)
      fileManager.homeDirectoryForCurrentUser
    #else
      URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    #endif
  }

  private static func createdDirectory(at directory: URL, fileManager: FileManager) -> URL {
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      Log.persistence.error(
        "Failed to create data directory \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
    return directory
  }
}
