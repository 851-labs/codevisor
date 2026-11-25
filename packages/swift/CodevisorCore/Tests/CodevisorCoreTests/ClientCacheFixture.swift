import CodevisorClient
import Foundation

@testable import CodevisorCore

final class ClientCacheFixture: @unchecked Sendable {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("client-cache-\(UUID().uuidString)", isDirectory: true)
  let chatId = UUID()
  let database: ClientDatabase
  private let clock = Lock(Date(timeIntervalSince1970: 1_800_000_000))

  init() throws {
    database = try ClientDatabase(url: directory.appendingPathComponent(ClientDatabase.fileName))
    try database.migrate()
  }

  var chat: CachedChatKey { CachedChatKey(machineId: "local", chatId: chatId) }

  var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }

  func makeCache(limits: ClientCacheLimits = .standard) throws -> ClientCache {
    try ClientCache(
      database: database, filesDirectory: filesDirectory, limits: limits, auditsWrites: false,
      now: { [clock] in clock.value })
  }

  func advance(by interval: TimeInterval) {
    clock.update { $0.addingTimeInterval(interval) }
  }

  func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  func page(_ sequences: ClosedRange<Int>, cursor: Int, hasMore: Bool, ids: [Int: String] = [:]) -> Data {
    Data(pageJSON(sequences, cursor: cursor, hasMore: hasMore, ids: ids).utf8)
  }

  func opened(_ sequences: ClosedRange<Int>, cursor: Int, hasMore: Bool) -> Data {
    let session = """
      {"id": "\(chatId.uuidString)", "projectId": "\(UUID().uuidString)", "serverId": "local", "harnessId": "codex",
       "title": "Chat", "origin": "codevisor", "createdAt": "2026-09-08T17:45:00Z"}
      """
    return Data(
      """
      {"session": \(session), "transcript": \(pageJSON(sequences, cursor: cursor, hasMore: hasMore, ids: [:])),
       "runtime": {"configOptions": []}}
      """.utf8)
  }

  func cachedSequences(in cache: ClientCache) throws -> (sequences: [Int], nextBefore: String?) {
    guard let data = try cache.transcripts.page(of: chat) else { return ([], nil) }

    let page = try JSONDecoder().decode(ServerTranscriptPage.self, from: data)
    return (page.items.map(\.sequence), page.hasMore ? page.nextBefore : nil)
  }

  static func itemId(_ sequence: Int) -> String {
    String(format: "00000000-0000-4000-8000-%012d", sequence)
  }

  private func pageJSON(_ sequences: ClosedRange<Int>, cursor: Int, hasMore: Bool, ids: [Int: String]) -> String {
    let items = sequences.map { sequence in
      """
      {"id": "\(ids[sequence] ?? Self.itemId(sequence))", "sessionId": "\(chatId.uuidString)",
       "sequence": \(sequence), "role": "\(sequence.isMultiple(of: 2) ? "user" : "assistant")",
       "text": "item \(sequence)", "createdAt": "2026-09-08T17:45:00.000Z", "updatedAt": "2026-09-08T17:45:00.000Z",
       "isGenerating": false, "hasDetails": false, "revision": 1}
      """
    }
    let more = hasMore ? "\"hasMore\": true, \"nextBefore\": \"\(sequences.lowerBound)\"" : "\"hasMore\": false"
    return """
      {"items": [\(items.joined(separator: ","))], "setupActivities": [], "stateUpdates": [], "hasNewer": false,
       \(more), "eventCursor": \(cursor)}
      """
  }
}

private final class Lock<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Value

  init(_ value: Value) { current = value }

  var value: Value { lock.withLock { current } }

  func update(_ change: (Value) -> Value) {
    lock.withLock { current = change(current) }
  }
}
