import Foundation

/// The latest page of recently opened chats, kept on disk so a chat can show
/// its history the moment it opens -- even offline, or after the system ended
/// the app -- and update in place when the server's fresh page arrives.
///
/// It stores the open response's bytes as the server sent them. It lives in
/// Caches: the system may clear it, and nothing is lost if it does.
///
/// Every file operation runs on one serial utility queue. Saving and removing
/// return at once (opening a chat saves its page on the main actor); a read
/// waits for every operation queued before it, so it always sees the latest
/// save.
public final class TranscriptPageCache: @unchecked Sendable {
  public static let defaultLimit = 30

  private let directory: URL
  private let limit: Int
  private let fileManager = FileManager.default
  private let queue = DispatchQueue(label: "com.codevisor.transcript-page-cache", qos: .utility)

  public init(directory: URL, limit: Int = TranscriptPageCache.defaultLimit) {
    self.directory = directory
    self.limit = limit
  }

  /// The app's shared cache under the user's Caches directory.
  public static let shared = TranscriptPageCache(
    directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("transcripts", isDirectory: true))

  /// Reads once earlier saves and removals have landed. Suspends rather than
  /// blocking: a `queue.sync` here would park a Swift concurrency thread (a
  /// small, fixed pool) for the whole wait and the disk read.
  public func load(machineId: String, sessionId: UUID) async -> Data? {
    let url = fileURL(machineId: machineId, sessionId: sessionId)
    return await withCheckedContinuation { continuation in
      // `.enforceQoS` lifts queued utility work ahead of it to the reader's priority.
      queue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in
        guard let data = try? Data(contentsOf: url) else { return continuation.resume(returning: nil) }
        // Reading counts as use, so the chats opened most recently stay.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        continuation.resume(returning: data)
      }
    }
  }

  /// Queues the write and the trim that follows it.
  public func store(_ data: Data, machineId: String, sessionId: UUID) {
    let url = fileURL(machineId: machineId, sessionId: sessionId)
    queue.async { [self] in
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
    queue.async { [self] in try? fileManager.removeItem(at: url) }
  }

  public func removeAll() {
    queue.async { [self] in try? fileManager.removeItem(at: directory) }
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
