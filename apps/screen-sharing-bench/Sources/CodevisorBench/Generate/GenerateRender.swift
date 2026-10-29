import Foundation
import ScreenSharingBenchScenes

enum GenerateRender {
  static func run(_ setup: BenchSceneSetup, versions: Range<Int>, pngDirectory: String?) async throws {
    let generator = try BenchSceneGenerator(setup: setup)
    if let pngDirectory {
      try FileManager.default.createDirectory(atPath: pngDirectory, withIntermediateDirectories: true)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for version in versions {
      let frame = try await generator.frame(forVersion: version).pixelBuffer
      let entry = SceneHashLog.Entry(version: version, sha256: try BenchPixelHash.bgra(frame))
      print(String(decoding: try encoder.encode(entry), as: UTF8.self))
      guard let pngDirectory else { continue }

      try GeneratePNG.write(frame, to: "\(pngDirectory)/\(setup.scene.rawValue)-\(version).png")
    }
  }
}
