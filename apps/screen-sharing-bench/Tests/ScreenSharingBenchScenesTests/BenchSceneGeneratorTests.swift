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

  @Test(arguments: BenchScene.allCases.filter { $0 != .testCards && $0 != .input })
  func withTheBottomBarcodeEveryFrameAlsoShowsItsVersionInTheBottomLeftCorner(scene: BenchScene) async throws {
    let generator = try BenchSceneGenerator(
      setup: BenchSceneSetup(scene: scene, seed: 7, canvas: Self.canvas), bottomBarcode: true)
    let standard = BenchBarcodeLayout.standard
    let bottom = BenchBarcodeLayout(y: Self.canvas.pixelHeight - standard.height, blockSize: standard.blockSize)

    for version in Self.versions {
      let frame = try await generator.frame(forVersion: version)
      #expect(try BenchBarcode.read(frame.pixelBuffer, layout: bottom) == .version(version), "\(scene.rawValue)")
      #expect(try BenchBarcode.read(frame.pixelBuffer) == .version(version), "\(scene.rawValue)")
    }
  }

  @Test func withoutTheBottomBarcodeTheBottomLeftCornerIsLeftToTheScene() async throws {
    let generator = try BenchSceneGenerator(setup: BenchSceneSetup(scene: .scroll, seed: 7, canvas: Self.canvas))
    let standard = BenchBarcodeLayout.standard
    let bottom = BenchBarcodeLayout(y: Self.canvas.pixelHeight - standard.height, blockSize: standard.blockSize)

    let frame = try await generator.frame(forVersion: 37)

    #expect(try BenchBarcode.read(frame.pixelBuffer, layout: bottom) != .version(37))
  }
}
