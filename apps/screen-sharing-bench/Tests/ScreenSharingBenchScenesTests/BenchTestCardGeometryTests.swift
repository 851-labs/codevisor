import ScreenSharingBench
import ScreenSharingBenchScenes
import Testing

struct BenchTestCardGeometryTests {
  private static let canvas = BenchSceneCanvas(pixelWidth: 960, pixelHeight: 540, scale: 1)
  private static let geometry = BenchTestCardLayout.geometry(of: canvas)

  @Test(arguments: [0, 1, 2])
  func theGeneratorsCardsRegisterAtTheOriginAndMatchThemselves(version: Int) async throws {
    let card = try await Self.card(version: version)
    let kind: BenchCardCapture.Kind = BenchTestCard.shown(atVersion: version) == .chroma ? .chroma : .text
    let analysis = try #require(
      try BenchTextFidelityAnalysis(
        [BenchCardCapture(version: version, kind: kind, reference: card, shown: card)], geometry: Self.geometry))

    #expect(
      BenchRegistration.register(BenchLumaImage(BenchYCbCrPlanes(card)), geometry: Self.geometry) == .registered(.zero))
    #expect(analysis.fidelity.oneToOne == true)
  }

  @Test func theChromaTilesMaskTheirColouredText() async throws {
    let card = try await Self.card(version: 2)
    let mask = BenchCardMasks.colouredText(card, tiles: Self.geometry.chromaTiles)
    let tileArea = Self.geometry.chromaTiles.reduce(0) { $0 + $1.width * $1.height }

    #expect(Self.geometry.chromaTiles.count == 6)
    #expect((tileArea / 100...tileArea / 3).contains(mask.count { $0 }))
  }

  private static func card(version: Int) async throws -> BenchRGBImage {
    let generator = try BenchSceneGenerator(setup: BenchSceneSetup(scene: .testCards, seed: 1, canvas: canvas))
    return try BenchRGBImage(bgraPixelBuffer: try await generator.frame(forVersion: version).pixelBuffer)
  }
}
