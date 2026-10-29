import Testing

@testable import CodevisorBench

struct Tier2HPDisplayTests {
  @Test(arguments: [
    ("1920x1080@60 2x Screen Sharing Virtual Display", true),
    ("1920x1080@0 2x Screen Sharing Virtual Display", true),
    ("1920x1080@60 2x", true),
    ("1920x1080@30 2x Screen Sharing Virtual Display", false),
    ("1920x1080@60 1x", false),
    ("1920x1080@60 1x Display 2x", false),
    ("2560x1440@60 2x Screen Sharing Virtual Display", false),
  ])
  func anAppleHPRunCountsOnlyOnA1080pHiDPIDisplayAt60HzOrAnUnknownRate(description: String, counts: Bool) {
    #expect(Tier2Measurement.isHPVirtualDisplay(description) == counts)
  }
}
