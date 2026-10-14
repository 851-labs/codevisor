import Foundation

public enum CommandLineTools {
  public static let launcherNames = [
    "codevisor",
    "codevisor-server",
    "codevisor-terminal-proxy",
  ]

  private static let ownedDestinationMarkers = [
    "Codevisor.app/Contents/Resources/",
    "HerdMan.app/Contents/Resources/",
  ]

  public static func ensureInstalled(
    runtimeDirectory: URL? = LocalCodevisorServer.bundledServerRuntimeDirectory(),
    binDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/bin", isDirectory: true),
    fileManager: FileManager = .default
  ) {
    guard let runtimeDirectory else { return }
    let runtimeBin = runtimeDirectory.appendingPathComponent("bin", isDirectory: true)
    for name in launcherNames {
      let source = runtimeBin.appendingPathComponent(name)
      guard fileManager.isExecutableFile(atPath: source.path) else { continue }
      ensureLink(
        at: binDirectory.appendingPathComponent(name),
        to: source,
        fileManager: fileManager
      )
    }
  }

  private static func ensureLink(at link: URL, to source: URL, fileManager: FileManager) {
    if let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
      let resolved = URL(
        fileURLWithPath: destination,
        relativeTo: link.deletingLastPathComponent()
      ).standardizedFileURL.path
      guard resolved != source.path else { return }
      let broken = !fileManager.fileExists(atPath: resolved)
      let owned = ownedDestinationMarkers.contains { resolved.contains($0) }
      guard broken || owned else { return }
    } else if fileManager.fileExists(atPath: link.path) {
      return
    }
    do {
      try fileManager.createDirectory(
        at: link.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? fileManager.removeItem(at: link)
      try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
    } catch {
    }
  }
}
