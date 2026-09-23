import Testing
@testable import ScreenSharing

/// Lossless on a fast link, JPEG on a slow one (851-2313).
struct VNCQualityPolicyTests {
  /// A 100 KB update that took `milliseconds`: 100 ms is 8.2 Mbit/s, 20 ms is 41 Mbit/s.
  static func sample(_ policy: inout VNCQualityPolicy, milliseconds: Int) -> Int?? {
    policy.observe(bytes: 102_400, duration: .milliseconds(milliseconds))
  }

  @Test func aSlowLinkTurnsJPEGOnAfterThreeSamples() {
    var policy = VNCQualityPolicy()
    #expect(Self.sample(&policy, milliseconds: 100) == nil)
    #expect(Self.sample(&policy, milliseconds: 100) == nil)
    #expect(Self.sample(&policy, milliseconds: 100) == .some(8))
    #expect(policy.qualityLevel == 8 && policy.description == "JPEG 8")
  }

  @Test func aFastLinkStaysLossless() {
    var policy = VNCQualityPolicy()
    for _ in 0..<10 { #expect(Self.sample(&policy, milliseconds: 20) == nil) }
    #expect(policy.qualityLevel == nil && policy.description == "lossless")
  }

  @Test func itGoesBackToLosslessOnlyAboveTheUpperThreshold() {
    var policy = VNCQualityPolicy(qualityLevel: 8)
    // ~20 Mbit/s sits between the thresholds: no change either way.
    for _ in 0..<5 { #expect(Self.sample(&policy, milliseconds: 41) == nil) }
    var changed: Int?? = nil
    for _ in 0..<10 where changed == nil { changed = Self.sample(&policy, milliseconds: 20) }
    #expect(changed == .some(nil))
    #expect(policy.qualityLevel == nil)
  }

  @Test func smallUpdatesAreNotSamples() {
    var policy = VNCQualityPolicy()
    for _ in 0..<10 { #expect(policy.observe(bytes: 1000, duration: .seconds(1)) == nil) }
    #expect(policy.bitsPerSecond == nil)
  }
}
