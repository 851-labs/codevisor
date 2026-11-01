import ScreenSharingBench
import Testing

struct BenchSimilarityTests {
  private static let width = 32
  private static let height = 24
  private static let ramp = (0..<width * height).map { Float($0 % 251) }

  @Test func anImageComparedWithItselfIsInfinitePSNRAndUnitSSIM() throws {
    #expect(BenchSimilarity.psnr(Self.ramp, Self.ramp) == .infinity)
    #expect(abs(try BenchSimilarity.ssim(Self.ramp, Self.ramp, width: Self.width, height: Self.height) - 1) < 1e-6)
  }

  @Test func anOffsetOfOneLevelIs48Decibels() {
    #expect(abs(BenchSimilarity.psnr(Self.ramp, Self.ramp.map { $0 + 1 }) - 48.13) < 0.01)
  }

  @Test func flatteningDetailLowersSSIM() throws {
    let flat = [Float](repeating: 125, count: Self.ramp.count)

    #expect(try BenchSimilarity.ssim(Self.ramp, flat, width: Self.width, height: Self.height) < 0.1)
  }

  @Test func aMaskCountsOnlyItsPixels() {
    let shown = Self.ramp.enumerated().map { $0.offset == 0 ? $0.element + 10 : $0.element }
    let mask = Self.ramp.indices.map { $0 < 4 }

    #expect(BenchSquaredError(Self.ramp, shown, mask: mask) == BenchSquaredError(sum: 100, count: 4))
  }
}
