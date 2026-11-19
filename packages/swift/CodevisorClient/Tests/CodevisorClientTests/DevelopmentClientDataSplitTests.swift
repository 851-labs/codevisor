import Foundation
import Testing

@testable import CodevisorClient

@Suite("Dev client data split")
struct DevelopmentClientDataSplitTests {
  @Test("Moves the app's files into its own folder and leaves the dev server's where they are")
  func movesOnlyClientData() throws {
    let shared = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: shared) }
    for path in [
      "client.sqlite", "ClientAssets/DraftAttachments/a.json", "codevisor-server.sqlite", "browser/profiles/x",
    ] {
      try write(path, in: shared)
    }

    DevelopmentClientDataSplit.run(sharedDirectory: shared, fileManager: .default)

    let client = DevelopmentClientDataSplit.clientDirectory(in: shared)
    #expect(exists("client.sqlite", in: client))
    #expect(exists("ClientAssets/DraftAttachments/a.json", in: client))
    #expect(!exists("client.sqlite", in: shared))
    #expect(exists("codevisor-server.sqlite", in: shared))
    #expect(exists("browser/profiles/x", in: shared))
  }

  @Test("Never replaces client data already in its own folder")
  func keepsExistingClientData() throws {
    let shared = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: shared) }
    try write("client.sqlite", in: shared, contents: "old")
    try write("Client/client.sqlite", in: shared, contents: "current")

    DevelopmentClientDataSplit.run(sharedDirectory: shared, fileManager: .default)

    let current = try String(contentsOf: shared.appendingPathComponent("Client/client.sqlite"), encoding: .utf8)
    #expect(current == "current")
  }

  private func write(_ path: String, in directory: URL, contents: String = "data") throws {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  private func exists(_ path: String, in directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
  }
}
