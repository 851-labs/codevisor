import Foundation
import Testing
@testable import CodevisorCore

@Suite("Persistence stores")
struct PersistenceStoreTests {
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
