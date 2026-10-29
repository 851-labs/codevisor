import Foundation
import ScreenSharingBenchScenes

enum GenerateCheck {
  struct Summary: Encodable {
    let scene: BenchScene
    let seed: UInt64
    let canvas: BenchSceneCanvas
    let checked: Int
    let matched: Int
    let mismatched: [Int]

    func json() throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
  }

  static func run(_ log: SceneHashLog) async throws -> Summary {
    let generator = try BenchSceneGenerator(setup: log.setup)
    var mismatched: [Int] = []
    for entry in log.entries {
      let frame = try await generator.frame(forVersion: entry.version).pixelBuffer
      if try BenchPixelHash.bgra(frame) != entry.sha256 { mismatched.append(entry.version) }
    }
    return Summary(
      scene: log.setup.scene, seed: log.setup.seed, canvas: log.setup.canvas, checked: log.entries.count,
      matched: log.entries.count - mismatched.count, mismatched: mismatched)
  }
}
