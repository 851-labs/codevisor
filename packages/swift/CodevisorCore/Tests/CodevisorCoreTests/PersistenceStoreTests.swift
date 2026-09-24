import Foundation
import Testing
@testable import CodevisorCore

@Suite("Persistence stores")
struct PersistenceStoreTests {
  @Test("FileSystemStore persists to a temp directory")
  func fileSystemStore() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileSystemStore(directory: directory)
    try store.saveData(Data([1, 2, 3]), forKey: "sessions")
    // Writes land on a background queue (they must not block the main
    // thread in the app); drain before reading through a fresh store.
    store.flushPendingWrites()

    // A fresh store reading the same directory sees the data.
    #expect(FileSystemStore(directory: directory).loadData(forKey: "sessions") == Data([1, 2, 3]))
  }

  @Test("InMemoryStore reads back written keys")
  func inMemoryStore() throws {
    let store = InMemoryStore()
    #expect(store.loadData(forKey: "missing") == nil)
    try store.saveData(Data([1, 2, 3]), forKey: "k")
    #expect(store.loadData(forKey: "k") == Data([1, 2, 3]))
  }

  @Test("FileSystemStore coalesces saves and removals with the latest operation winning")
  func fileSystemStoreRemoval() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSystemStore(directory: directory)

    try store.saveData(Data([1]), forKey: "draft")
    try store.removeData(forKey: "draft")
    #expect(store.loadData(forKey: "draft") == nil)
    store.flushPendingWrites()
    #expect(FileSystemStore(directory: directory).loadData(forKey: "draft") == nil)

    try store.removeData(forKey: "draft")
    try store.saveData(Data([2]), forKey: "draft")
    store.flushPendingWrites()
    #expect(FileSystemStore(directory: directory).loadData(forKey: "draft") == Data([2]))
  }
}
