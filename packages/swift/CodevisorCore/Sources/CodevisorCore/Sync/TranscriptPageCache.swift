import Foundation

/// The latest page of recently opened chats, kept on disk so a chat can show
/// its history the moment it opens -- even offline, or after the system ended
/// the app -- and update in place when the server's fresh page arrives.
///
/// It stores the open response's bytes as the server sent them. It lives in
/// Caches: the system may clear it, and nothing is lost if it does.
public final class TranscriptPageCache: @unchecked Sendable {
  public static let defaultLimit = 30

  private let directory: URL
  private let limit: Int
  private let fileManager = FileManager.default
  private let lock = NSLock()

  public init(directory: URL, limit: Int = TranscriptPageCache.defaultLimit) {
    self.directory = directory
    self.limit = limit
  }

  /// The app's shared cache under the user's Caches directory.
  public static let shared = TranscriptPageCache(
    directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("transcripts", isDirectory: true))

  public func load(machineId: String, sessionId: UUID) -> Data? {
    let url = fileURL(machineId: machineId, sessionId: sessionId)
    return lock.withLock {
      guard let data = try? Data(contentsOf: url) else { return nil }
      // Reading counts as use, so the chats opened most recently stay.
      try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
      return data
    }
  }

  public func store(_ data: Data, machineId: String, sessionId: UUID) {
    let url = fileURL(machineId: machineId, sessionId: sessionId)
    lock.withLock {
      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      } catch {
        Log.persistence.error("Failed to cache a chat page: \(String(describing: error), privacy: .public)")
        return
      }
      trim()
    }
  }

  public func remove(machineId: String, sessionId: UUID) {
    let url = fileURL(machineId: machineId, sessionId: sessionId)
    lock.withLock { try? fileManager.removeItem(at: url) }
  }

  public func removeAll() {
    lock.withLock { try? fileManager.removeItem(at: directory) }
  }

  private func fileURL(machineId: String, sessionId: UUID) -> URL {
    let machine = machineId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? machineId
    return directory.appendingPathComponent("\(machine)_\(sessionId.uuidString.lowercased()).json")
  }

  /// Keeps only the most recently used pages.
  private func trim() {
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
      files.count > limit
    else { return }
    let byAge = files.sorted { lhs, rhs in
      let left =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let right =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      return left < right
    }
    for file in byAge.prefix(files.count - limit) { try? fileManager.removeItem(at: file) }
  }
}
