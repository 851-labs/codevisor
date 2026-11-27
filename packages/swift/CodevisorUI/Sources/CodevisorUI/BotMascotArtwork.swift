import CodevisorClient
import Foundation
@preconcurrency import RiveRuntime

@MainActor
final class BotMascotArtwork {
  static let shared = BotMascotArtwork()
  nonisolated static let version = bundledText("version") ?? "unversioned"

  private var worker: Task<Worker, any Error>?
  private var file: Task<File, any Error>?
  private var colors: Task<BotMascotColorTable, any Error>?

  func riveFile() async throws -> File {
    let task =
      file
      ?? Task {
        try await File(source: .data(try await Self.bundledData("mascot.riv")), worker: try await sharedWorker())
      }
    file = task
    return try await task.value
  }

  func colorTable() async throws -> BotMascotColorTable {
    let task = colors ?? Task { try BotMascotColorTable(json: try await Self.bundledData("rive-colors.json")) }
    colors = task
    return try await task.value
  }

  func values(for mascot: ServerBotMascot) async throws -> BotMascotRiveValues {
    BotMascotRiveValues(mascot, colors: try await colorTable())
  }

  private func sharedWorker() async throws -> Worker {
    let task = worker ?? Task { try await Worker() }
    worker = task
    return try await task.value
  }

  @concurrent
  private nonisolated static func bundledData(_ name: String) async throws -> Data {
    try Data(contentsOf: try bundledURL(name))
  }

  private nonisolated static func bundledText(_ name: String) -> String? {
    guard let url = try? bundledURL(name), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private nonisolated static func bundledURL(_ name: String) throws -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "BotMascotArt") else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "BotMascotArt/\(name)"])
    }
    return url
  }
}
