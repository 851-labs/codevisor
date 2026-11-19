import Foundation

public struct DeviceDataScope {
  public enum Keychain: Equatable, Sendable {
    case everyItem
    case services([String])
  }

  public var directories: [URL]
  public var preserved: [URL]
  public var defaults: UserDefaults
  public var defaultsDomain: String
  public var preservedDefaultsKeys: [String]
  public var keychain: Keychain
  public var marker: URL

  public init(
    directories: [URL],
    preserved: [URL] = [],
    defaults: UserDefaults,
    defaultsDomain: String,
    preservedDefaultsKeys: [String] = [],
    keychain: Keychain,
    marker: URL
  ) {
    self.directories = directories
    self.preserved = preserved
    self.defaults = defaults
    self.defaultsDomain = defaultsDomain
    self.preservedDefaultsKeys = preservedDefaultsKeys
    self.keychain = keychain
    self.marker = marker
  }

  public static func appContainer(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    defaults: UserDefaults = .standard,
    defaultsDomain: String = Bundle.main.bundleIdentifier ?? ""
  ) -> DeviceDataScope {
    let library = home.appendingPathComponent("Library", isDirectory: true)
    return DeviceDataScope(
      directories: [
        home.appendingPathComponent("Documents", isDirectory: true),
        library,
        home.appendingPathComponent("tmp", isDirectory: true),
      ],
      preserved: [library.appendingPathComponent("Preferences", isDirectory: true)],
      defaults: defaults,
      defaultsDomain: defaultsDomain,
      preservedDefaultsKeys: [CodevisorAppVariant.stashedEnvironmentKey],
      keychain: .everyItem,
      marker: pendingMarker(in: library.appendingPathComponent("Application Support", isDirectory: true))
    )
  }

  public static func pendingMarker(in directory: URL) -> URL {
    directory.appendingPathComponent(".device-data-deletion-pending")
  }

  func contains(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    return directories.contains { DeviceDataPath.isWithin(path, $0) }
  }
}

enum DeviceDataPath {
  static func isWithin(_ path: String, _ directory: URL) -> Bool {
    let root = directory.standardizedFileURL.path
    return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }
}
