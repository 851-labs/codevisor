import Testing

@testable import CodevisorBench

struct EncodeLabSimilarityTests {
  private static let width = 32
  private static let height = 24
  private static let ramp = (0..<width * height).map { Float($0 % 251) }

  @Test func identicalPlanesScoreAsIdentical() throws {
    #expect(EncodeLabSimilarity.psnr(Self.ramp, Self.ramp) == EncodeLabSimilarity.identicalPSNR)
    #expect(abs(try EncodeLabSimilarity.ssim(Self.ramp, Self.ramp, width: Self.width, height: Self.height) - 1) < 1e-6)
  }

  @Test func anOffsetOfOneLevelIs48Decibels() {
    let shifted = Self.ramp.map { $0 + 1 }

    #expect(abs(EncodeLabSimilarity.psnr(Self.ramp, shifted) - 48.13) < 0.01)
  }

  @Test func flatteningDetailLowersSSIM() throws {
    let flat = [Float](repeating: 125, count: Self.ramp.count)

    #expect(try EncodeLabSimilarity.ssim(Self.ramp, flat, width: Self.width, height: Self.height) < 0.1)
  }
}
