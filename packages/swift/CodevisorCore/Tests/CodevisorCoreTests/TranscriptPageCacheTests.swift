import Foundation
import Testing

@testable import CodevisorCore

struct TranscriptPageCacheTests {
  func makeCache(limit: Int = 3) -> (TranscriptPageCache, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)")
    return (TranscriptPageCache(directory: directory, limit: limit), directory)
  }

  @Test("A chat's page is kept per machine and read back as stored")
  func roundTrip() async {
    let (cache, directory) = makeCache()
    defer { try? FileManager.default.removeItem(at: directory) }
    let chat = UUID()
    cache.store(Data("page".utf8), machineId: "cloud:abc", sessionId: chat)
    #expect(await cache.load(machineId: "cloud:abc", sessionId: chat) == Data("page".utf8))
    #expect(await cache.load(machineId: "local", sessionId: chat) == nil)
    cache.remove(machineId: "cloud:abc", sessionId: chat)
    #expect(await cache.load(machineId: "cloud:abc", sessionId: chat) == nil)
  }

  @Test("Only the most recently used chats are kept")
  func keepsRecent() async throws {
    let (cache, directory) = makeCache(limit: 2)
    defer { try? FileManager.default.removeItem(at: directory) }
    let chats = [UUID(), UUID(), UUID()]
    for (offset, chat) in chats.prefix(2).enumerated() {
      cache.store(Data("\(offset)".utf8), machineId: "m", sessionId: chat)
      #expect(await cache.load(machineId: "m", sessionId: chat) == Data("\(offset)".utf8))
      let url = try #require(
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .first { $0.lastPathComponent.contains(chat.uuidString.lowercased()) })
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: Double(offset) * 100)], ofItemAtPath: url.path)
    }
    #expect(await cache.load(machineId: "m", sessionId: chats[0]) == Data("0".utf8))
    cache.store(Data("2".utf8), machineId: "m", sessionId: chats[2])
    #expect(await cache.load(machineId: "m", sessionId: chats[1]) == nil)
    #expect(await cache.load(machineId: "m", sessionId: chats[0]) == Data("0".utf8))
    #expect(await cache.load(machineId: "m", sessionId: chats[2]) == Data("2".utf8))
  }
}
