import Foundation

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

  public static let shared = TranscriptPageCache(
    directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("transcripts", isDirectory: true))

  public func load(machineId: String, sessionId: UUID) async -> Data? {
    let url = fileURL(machineId: machineId, sessionId: sessionId)
    return await withCheckedContinuation { continuation in
      queue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in
        guard let data = try? Data(contentsOf: url) else { return continuation.resume(returning: nil) }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        continuation.resume(returning: data)
      }
    }
  }

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
