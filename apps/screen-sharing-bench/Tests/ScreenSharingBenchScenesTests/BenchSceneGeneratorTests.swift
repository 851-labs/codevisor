import ScreenSharingBench
import ScreenSharingBenchScenes
import Testing

struct BenchSceneGeneratorTests {
  private static let canvas = BenchSceneCanvas(pixelWidth: 960, pixelHeight: 540, scale: 1)
  private static let versions = [0, 1, 37, 180, 901, 4_321, 0xFF_FFFF]

  @Test(arguments: BenchScene.allCases)
  func everyFrameShowsItsVersionInTheBarcodeAboveTheContent(scene: BenchScene) async throws {
    let generator = try BenchSceneGenerator(setup: BenchSceneSetup(scene: scene, seed: 7, canvas: Self.canvas))

    for version in Self.versions {
      let frame = try await generator.frame(forVersion: version)
      #expect(try BenchBarcode.read(frame.pixelBuffer) == .version(version), "\(scene.rawValue) v\(version)")
    }
  }
}
