import Foundation
import Testing

@testable import CodevisorCore

struct TranscriptPageCacheTests {
  func makeCache(limit: Int = 3) -> (TranscriptPageCache, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)")
    return (TranscriptPageCache(directory: directory, limit: limit), directory)
  }

  @Test("A chat's page is kept per machine and read back as stored")
  func roundTrip() {
    let (cache, directory) = makeCache()
    defer { try? FileManager.default.removeItem(at: directory) }
    let chat = UUID()
    cache.store(Data("page".utf8), machineId: "cloud:abc", sessionId: chat)
    #expect(cache.load(machineId: "cloud:abc", sessionId: chat) == Data("page".utf8))
    #expect(cache.load(machineId: "local", sessionId: chat) == nil)
    cache.remove(machineId: "cloud:abc", sessionId: chat)
    #expect(cache.load(machineId: "cloud:abc", sessionId: chat) == nil)
  }

  @Test("Only the most recently used chats are kept")
  func keepsRecent() throws {
    let (cache, directory) = makeCache(limit: 2)
    defer { try? FileManager.default.removeItem(at: directory) }
    let chats = [UUID(), UUID(), UUID()]
    for (offset, chat) in chats.enumerated() {
      cache.store(Data("\(offset)".utf8), machineId: "m", sessionId: chat)
      // Distinct modification times keep the order deterministic.
      let url = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.contains(chat.uuidString.lowercased()) }
      if let url {
        try FileManager.default.setAttributes(
          [.modificationDate: Date(timeIntervalSince1970: Double(offset) * 100)], ofItemAtPath: url.path)
      }
    }
    cache.store(Data("again".utf8), machineId: "m", sessionId: chats[2])
    #expect(cache.load(machineId: "m", sessionId: chats[0]) == nil)
    #expect(cache.load(machineId: "m", sessionId: chats[2]) == Data("again".utf8))
  }
}
