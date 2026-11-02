import Testing

@testable import CodevisorBench

struct EncodeLabSimilarityTests {
  private static let ramp = (0..<32 * 24).map { Float($0 % 251) }

  @Test func identicalPlanesReportTheCappedPSNR() {
    #expect(EncodeLabSimilarity.psnr(Self.ramp, Self.ramp) == EncodeLabSimilarity.identicalPSNR)
    #expect(EncodeLabSimilarity.psnr([Self.ramp], [Self.ramp]) == EncodeLabSimilarity.identicalPSNR)
  }
}
