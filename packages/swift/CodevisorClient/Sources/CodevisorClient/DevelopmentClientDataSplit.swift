import Foundation

enum DevelopmentClientDataSplit {
  static let clientDirectoryName = "Client"

  static let clientEntries = [
    "client.sqlite",
    "client.sqlite-wal",
    "client.sqlite-shm",
    "ClientAssets",
    "ComposerAttachments",
    "MigrationRecovery",
    "FileDrafts",
    "Chromium-v2",
    "sounds",
    "ghostty-resources",
  ]

  static func clientDirectory(in sharedDirectory: URL) -> URL {
    sharedDirectory.appendingPathComponent(clientDirectoryName, isDirectory: true)
  }

  static func run(sharedDirectory: URL, fileManager: FileManager) {
    let client = clientDirectory(in: sharedDirectory)
    guard needsSplit(sharedDirectory: sharedDirectory, client: client, fileManager: fileManager) else { return }

    do {
      try fileManager.createDirectory(at: client, withIntermediateDirectories: true)
      for entry in clientEntries {
        try move(entry, from: sharedDirectory, to: client, fileManager: fileManager)
      }
    } catch {
      Log.persistence.error(
        "Failed to move dev client data into its own folder: \(String(describing: error), privacy: .public)"
      )
    }
  }

  private static func needsSplit(sharedDirectory: URL, client: URL, fileManager: FileManager) -> Bool {
    let oldDatabase = sharedDirectory.appendingPathComponent("client.sqlite")
    let newDatabase = client.appendingPathComponent("client.sqlite")
    return fileManager.fileExists(atPath: oldDatabase.path) && !fileManager.fileExists(atPath: newDatabase.path)
  }

  private static func move(_ entry: String, from source: URL, to destination: URL, fileManager: FileManager) throws {
    let from = source.appendingPathComponent(entry)
    let to = destination.appendingPathComponent(entry)
    guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { return }

    try fileManager.moveItem(at: from, to: to)
  }
}
