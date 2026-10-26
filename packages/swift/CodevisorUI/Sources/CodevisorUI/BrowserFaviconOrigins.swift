import Foundation

nonisolated struct BrowserFaviconOrigins: Codable, Sendable {
  struct Entry: Codable, Sendable {
    var origin: String
    var reference: String
  }

  private(set) var entries: [Entry] = []

  var references: [String: String] {
    Dictionary(entries.map { ($0.origin, $0.reference) }, uniquingKeysWith: { $1 })
  }

  mutating func record(_ reference: String, origin: String, limit: Int) {
    entries.removeAll { $0.origin == origin }
    entries.append(Entry(origin: origin, reference: reference))
    entries.removeFirst(max(0, entries.count - limit))
  }
}
