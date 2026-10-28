import Foundation

final class AssistantMarkdownSegmentCache: @unchecked Sendable {
  struct Key: Hashable {
    let markdown: String
    let attachments: [Attachment]
    let includeUnreferencedAttachments: Bool
    let localImagesPendingCapture: Bool

    var isSettled: Bool { !localImagesPendingCapture }
    var cost: Int { markdown.utf8.count }
  }

  static let shared = AssistantMarkdownSegmentCache()
  private let lock = NSLock()
  private var entries: [Key: [AssistantMarkdownSegment]] = [:]
  private var order: [Key] = []
  private var totalBytes = 0
  private let byteLimit: Int
  private let entryLimit: Int

  init(byteLimit: Int = 8 * 1_024 * 1_024, entryLimit: Int = 1_024) {
    self.byteLimit = max(0, byteLimit)
    self.entryLimit = max(0, entryLimit)
  }

  func segments(for key: Key, segment: (Key) -> [AssistantMarkdownSegment]) -> [AssistantMarkdownSegment] {
    guard key.isSettled, key.cost <= byteLimit, entryLimit > 0 else { return segment(key) }
    if let cached = lock.withLock({ entries[key] }) { return cached }

    let result = segment(key)
    lock.withLock { insert(result, for: key) }
    return result
  }

  private func insert(_ segments: [AssistantMarkdownSegment], for key: Key) {
    guard entries.updateValue(segments, forKey: key) == nil else { return }

    order.append(key)
    totalBytes += key.cost
    while entries.count > entryLimit || totalBytes > byteLimit, !order.isEmpty {
      let oldest = order.removeFirst()
      entries.removeValue(forKey: oldest)
      totalBytes -= oldest.cost
    }
  }
}
