import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceFileTransfers {
  private(set) var running: [UUID: String] = [:]
  private(set) var failure: String?

  var latestRunning: String? { running.values.sorted().first }

  func upload(_ urls: [URL], into directory: String, client: any CodevisorServerClienting) async -> [String] {
    await perform(Self.label("Uploading", urls.map(\.lastPathComponent))) {
      var placed: [String] = []
      for url in urls {
        placed.append(try await WorkspaceFileTransferOperations.upload(url, into: directory, client: client))
      }
      return placed
    } ?? []
  }

  func download(_ entries: [ServerFileEntry], client: any CodevisorServerClienting) async {
    let saved = await perform(Self.label("Downloading", entries.map(\.name))) {
      var saved: [URL] = []
      for entry in entries {
        saved.append(try await Self.saveToDownloads(entry, client: client))
      }
      return saved
    }
    saved?.forEach(DownloadsFolder.announce)
  }

  func copy(_ entries: [ServerFileEntry], isLocal: Bool, client: any CodevisorServerClienting) async {
    let staged = await perform(Self.label("Copying", entries.map(\.name))) {
      try await FileClipboard.stage(entries, isLocal: isLocal, client: client)
    }
    guard let staged else { return }

    FileClipboard.write(staged)
  }

  func report(_ message: String) {
    failure = message
  }

  func dismissFailure() {
    failure = nil
  }

  func perform<Value>(_ label: String, _ work: () async throws -> Value) async -> Value? {
    let id = UUID()
    running[id] = label
    failure = nil
    defer { running[id] = nil }
    do {
      return try await work()
    } catch {
      failure = error.localizedDescription
      return nil
    }
  }

  static func label(_ verb: String, _ names: [String]) -> String {
    guard names.count == 1, let only = names.first else { return "\(verb) \(names.count) items" }
    return "\(verb) \(only)"
  }

  private static func saveToDownloads(
    _ entry: ServerFileEntry, client: any CodevisorServerClienting
  ) async throws -> URL {
    let staging = try DownloadsFolder.stagingDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let fetched = try await WorkspaceFileTransferOperations.materialize(entry, into: staging, client: client)
    return try DownloadsFolder.place(fetched, isFolder: entry.isDirectory)
  }
}
