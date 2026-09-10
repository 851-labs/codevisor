import Foundation
import MarkdownCore

/// Bounded parser state shared by active and settled projections. Parsing
/// runs outside the lock on the projection worker. Concurrent requests for
/// one source can independently fall back to a full parse; each caller still
/// receives the result for its own immutable input.
final class TranscriptMarkdownParseCache: @unchecked Sendable {
  struct Key: Hashable {
    let messageID: UUID
    let sourceID: String
  }

  static let shared = TranscriptMarkdownParseCache()
  private let lock = NSLock()
  private var entries: [Key: IncrementalMarkdownParser] = [:]
  private var costs: [Key: Int] = [:]
  private var order: [Key] = []
  private var totalBytes = 0
  private let byteLimit: Int
  private let entryLimit: Int

  init(byteLimit: Int = 8 * 1_024 * 1_024, entryLimit: Int = 16) {
    self.byteLimit = max(0, byteLimit)
    self.entryLimit = max(0, entryLimit)
  }

  func parse(_ source: String, messageID: UUID, sourceID: String) -> [MarkdownBlock] {
    let key = Key(messageID: messageID, sourceID: sourceID)
    var parser = lock.withLock {
      let parser = entries.removeValue(forKey: key) ?? IncrementalMarkdownParser()
      totalBytes -= costs.removeValue(forKey: key) ?? 0
      order.removeAll { $0 == key }
      return parser
    }
    let result = parser.parse(source)
    // Include an allowance for the semantic tree as well as source storage.
    let cost = source.utf8.count * 4
    guard cost <= byteLimit, entryLimit > 0 else { return result }
    lock.withLock {
      totalBytes -= costs[key] ?? 0
      entries[key] = parser
      costs[key] = cost
      totalBytes += cost
      order.removeAll { $0 == key }
      order.append(key)
      while entries.count > entryLimit || totalBytes > byteLimit, let oldest = order.first {
        entries.removeValue(forKey: oldest)
        totalBytes -= costs.removeValue(forKey: oldest) ?? 0
        order.removeFirst()
      }
    }
    return result
  }
}
