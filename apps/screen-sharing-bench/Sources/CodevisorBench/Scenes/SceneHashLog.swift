import Foundation
import ScreenSharingBenchScenes

struct SceneHashLog {
  struct Entry: Codable, Equatable, Sendable {
    let version: Int
    let sha256: String
  }

  let setup: BenchSceneSetup
  let entries: [Entry]

  static func read(from path: String) throws -> SceneHashLog {
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
    guard let header = lines.first else { throw BenchUsageError(message: "\(path) is empty") }

    let decoder = JSONDecoder()
    return SceneHashLog(
      setup: try decoder.decode(BenchSceneSetup.self, from: header),
      entries: try lines.dropFirst().map { try decoder.decode(Entry.self, from: $0) })
  }

  func write(to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let lines = try [encoder.encode(setup)] + entries.map(encoder.encode)
    let text = lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try text.write(toFile: path, atomically: true, encoding: .utf8)
  }
}
