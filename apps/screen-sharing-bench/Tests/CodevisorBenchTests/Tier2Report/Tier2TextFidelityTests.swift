import Foundation
import ScreenSharingBench
import ScreenSharingBenchScenes
import Testing

@testable import CodevisorBench

struct Tier2TextFidelityTests {
  private static let canvas = BenchSceneCanvas(pixelWidth: 960, pixelHeight: 540, scale: 1)

  @Test func stillsOfTheSameCardsScoreAsIdenticalAndSkipThePhotoCard() async throws {
    let run = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: run) }
    for side in [Tier2TextFidelity.hostStills, Tier2TextFidelity.viewerStills] {
      try await Self.writeStills(versions: [4, 6, 7], to: run.appending(path: side))
    }

    let analysis = try #require(try Tier2TextFidelity.analysis(in: run, canvas: Self.canvas))

    #expect(analysis.textFrames == 1 && analysis.chromaFrames == 1)
    let ssim = try #require(analysis.fidelity.ssimY)
    #expect(abs(ssim - 1) < 1e-6)
    #expect(
      analysis.fidelity
        == BenchTextFidelity(
          psnrY: 100, psnrYText: 100, ssimY: ssim, psnrCbcr: 100, deltaE00Mean: 0, deltaE00P95: 0, oneToOne: true))
  }

  private static func writeStills(versions: [Int], to directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let generator = try BenchSceneGenerator(setup: BenchSceneSetup(scene: .testCards, seed: 1, canvas: canvas))
    for version in versions {
      let frame = try await generator.frame(forVersion: version)
      try StillImage.write(frame.pixelBuffer, to: directory.appending(path: "\(version).png"))
    }
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "tier2-text-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
