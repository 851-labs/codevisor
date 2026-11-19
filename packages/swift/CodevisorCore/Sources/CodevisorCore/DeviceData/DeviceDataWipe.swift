import Foundation

@MainActor
public struct DeviceDataWipe {
  public let scope: DeviceDataScope
  private let keychain: KeychainOperations
  private let fileManager: FileManager

  public init(scope: DeviceDataScope, keychain: KeychainOperations = .live, fileManager: FileManager = .default) {
    self.scope = scope
    self.keychain = keychain
    self.fileManager = fileManager
  }

  public var isPending: Bool {
    fileManager.fileExists(atPath: scope.marker.path)
  }

  public func schedule() throws {
    try fileManager.createDirectory(at: scope.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: scope.marker)
  }

  public func runIfPending() async {
    guard isPending else { return }

    await DeviceDataTeardown.run()
    erase()
  }

  public func erase() {
    removeFiles()
    removeDefaults()
    KeychainWipe(scope: scope.keychain, operations: keychain).run()
    removeMarker()
  }

  private func removeMarker() {
    try? fileManager.removeItem(at: scope.marker)
    var folder = scope.marker.deletingLastPathComponent()
    while isEmptyFolderInsideScope(folder) {
      try? fileManager.removeItem(at: folder)
      folder = folder.deletingLastPathComponent()
    }
  }

  private func isEmptyFolderInsideScope(_ folder: URL) -> Bool {
    let isRoot = scope.directories.contains { $0.standardizedFileURL.path == folder.standardizedFileURL.path }
    let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? ["unreadable"]
    return !isRoot && scope.contains(folder) && contents.isEmpty
  }

  private func removeFiles() {
    let sweep = DirectorySweep(preserved: scope.preserved + [scope.marker], fileManager: fileManager)
    for directory in scope.directories {
      sweep.empty(directory)
    }
  }

  private func removeDefaults() {
    let kept = scope.preservedDefaultsKeys.compactMap { key in scope.defaults.object(forKey: key).map { (key, $0) } }
    scope.defaults.removePersistentDomain(forName: scope.defaultsDomain)
    for (key, value) in kept {
      scope.defaults.set(value, forKey: key)
    }
    scope.defaults.synchronize()
  }
}

private struct DirectorySweep {
  let preserved: [URL]
  let fileManager: FileManager

  func empty(_ directory: URL) {
    let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for child in children {
      sweep(child)
    }
  }

  private func sweep(_ item: URL) {
    if isPreserved(item) { return }
    if holdsPreserved(item) { return empty(item) }

    do {
      try fileManager.removeItem(at: item)
    } catch {
      Log.persistence.error(
        "Failed to delete \(item.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  private func isPreserved(_ item: URL) -> Bool {
    let path = item.standardizedFileURL.path
    return preserved.contains { $0.standardizedFileURL.path == path }
  }

  private func holdsPreserved(_ item: URL) -> Bool {
    preserved.contains { DeviceDataPath.isWithin($0.standardizedFileURL.path, item) }
  }
}
