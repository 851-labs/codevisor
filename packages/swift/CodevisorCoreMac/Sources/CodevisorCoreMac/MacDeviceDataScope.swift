import CodevisorCore
import Foundation

@MainActor
public enum MacDeviceDataScope {
  private static let libraryFolders = ["Application Support", "Caches", "HTTPStorages", "WebKit"]

  public static func current(preservingDefaults extraKeys: [String] = []) -> DeviceDataScope {
    let clientData = CodevisorAppVariant.applicationSupportURL()
    return DeviceDataScope(
      directories: appDirectories(clientData: clientData) + bundleDirectories(),
      preserved: [AppInstanceLease.runtimeDirectory()],
      defaults: .standard,
      defaultsDomain: bundleIdentifier,
      preservedDefaultsKeys: machineSetupKeys + extraKeys,
      keychain: .services(KeychainCredentialServices.all),
      marker: DeviceDataScope.pendingMarker(in: clientData)
    )
  }

  private static var bundleIdentifier: String {
    Bundle.main.bundleIdentifier ?? "com.851labs.Codevisor"
  }

  private static var machineSetupKeys: [String] {
    [StandaloneServerPreference.defaultsKey, CodevisorAppVariant.stashedEnvironmentKey]
  }

  private static func appDirectories(clientData: URL) -> [URL] {
    [
      clientData,
      CodevisorAppVariant.cacheURL(),
      CodevisorAppVariant.temporaryURL(),
      library.appendingPathComponent("Caches/transcripts", isDirectory: true),
    ] + [CodevisorAppVariant.legacyApplicationSupportURL()].compactMap { $0 }
  }

  private static func bundleDirectories() -> [URL] {
    let perApp = libraryFolders.map { library.appendingPathComponent("\($0)/\(bundleIdentifier)", isDirectory: true) }
    let savedState = library.appendingPathComponent(
      "Saved Application State/\(bundleIdentifier).savedState", isDirectory: true)
    return perApp + [savedState] + darwinUserCache()
  }

  private static func darwinUserCache() -> [URL] {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return [] }

    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    return [directory.appendingPathComponent(bundleIdentifier, isDirectory: true)]
  }

  private static var library: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
  }
}
