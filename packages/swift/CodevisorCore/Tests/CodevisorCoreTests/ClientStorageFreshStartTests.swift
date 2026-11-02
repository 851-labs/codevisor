import Foundation
import Testing

@testable import CodevisorCore

@Suite("Client storage fresh start")
struct ClientStorageFreshStartTests {
  @Test("Starts fresh only when neither the client database nor legacy data exists")
  func startsFreshWithoutStoredData() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codevisor-fresh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("data", isDirectory: true)
    let legacy = root.appendingPathComponent("legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #expect(ClientStorageBootstrap.startsFresh(directory: directory, legacyDirectory: legacy))

    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    #expect(!ClientStorageBootstrap.startsFresh(directory: directory, legacyDirectory: legacy))

    _ = try ClientDatabase(url: directory.appendingPathComponent(ClientDatabase.fileName))
    #expect(!ClientStorageBootstrap.startsFresh(directory: directory, legacyDirectory: nil))
  }
}
