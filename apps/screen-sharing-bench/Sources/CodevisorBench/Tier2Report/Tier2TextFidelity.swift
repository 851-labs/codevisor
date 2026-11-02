import Foundation
import ScreenSharingBench
import ScreenSharingBenchScenes

enum Tier2TextFidelity {
  static let scene = BenchScene.testCards.rawValue
  static let hostStills = "host-stills"
  static let viewerStills = "viewer-stills"

  static func analysis(of files: Tier2RunFiles) throws -> BenchTextFidelityAnalysis? {
    guard files.meta.scene == scene, let resolution = BenchSceneResolution(rawValue: files.meta.resolutionLabel) else {
      return nil
    }

    return try analysis(in: files.directory, canvas: BenchSceneCanvas(resolution))
  }

  static func analysis(in directory: URL, canvas: BenchSceneCanvas) throws -> BenchTextFidelityAnalysis? {
    try BenchTextFidelityAnalysis(captures(in: directory), geometry: BenchTestCardLayout.geometry(of: canvas))
  }

  private static func captures(in directory: URL) throws -> [BenchCardCapture] {
    let host = directory.appending(path: hostStills)
    let viewer = directory.appending(path: viewerStills)
    return try versions(in: host).intersection(versions(in: viewer)).sorted().compactMap { version in
      guard let kind = kind(atVersion: version) else { return nil }

      return BenchCardCapture(
        version: version, kind: kind, reference: try StillImage.read(still(version, in: host)),
        shown: try StillImage.read(still(version, in: viewer)))
    }
  }

  private static func kind(atVersion version: Int) -> BenchCardCapture.Kind? {
    switch BenchTestCard.shown(atVersion: version) {
    case .textLight, .textDark: .text
    case .chroma: .chroma
    case .photo: nil
    }
  }

  private static func versions(in directory: URL) -> Set<Int> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return Set(names.compactMap { Int($0.replacing(".png", with: "")) })
  }

  private static func still(_ version: Int, in directory: URL) -> URL {
    directory.appending(path: "\(version).png")
  }
}
