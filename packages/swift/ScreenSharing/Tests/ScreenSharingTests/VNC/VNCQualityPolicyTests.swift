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

  /// 851-2329: a very slow link (100 KB in a second, 0.8 Mbit/s) gets quality 4.
  @Test func aVerySlowLinkGetsTheLowerQuality() {
    var policy = VNCQualityPolicy()
    #expect(Self.sample(&policy, milliseconds: 1000) == nil)
    #expect(Self.sample(&policy, milliseconds: 1000) == nil)
    #expect(Self.sample(&policy, milliseconds: 1000) == .some(4))
    #expect(policy.description == "JPEG 4")
  }

  /// From quality 8 a link that drops below 2 Mbit/s goes to 4; back to 8 only above 3 Mbit/s.
  @Test func theSlowLinkTierHasItsOwnHysteresis() {
    #expect(VNCQualityPolicy.level(for: 1_500_000, current: 8) == 4)
    #expect(VNCQualityPolicy.level(for: 2_500_000, current: 4) == 4)
    #expect(VNCQualityPolicy.level(for: 2_500_000, current: 8) == 8)
    #expect(VNCQualityPolicy.level(for: 3_500_000, current: 4) == 8)
    #expect(VNCQualityPolicy.level(for: 20_000_000, current: 4) == 8)
    #expect(VNCQualityPolicy.level(for: 30_000_000, current: 4) == nil)
    #expect(VNCQualityPolicy.level(for: 20_000_000, current: nil) == nil)
    #expect(VNCQualityPolicy.level(for: 10_000_000, current: nil) == 8)
  }

  /// 851-2329: mid-sized updates (a window drag's 16 KB each, 200 ms apiece on a
  /// 0.66 Mbit/s link) pool into 64 KB samples, so a slow link is still noticed.
  @Test func midSizedUpdatesPoolIntoSamples() {
    var policy = VNCQualityPolicy()
    var decided: [Int??] = []
    for _ in 0..<12 {
      if let change = policy.observe(bytes: 16 * 1024, duration: .milliseconds(200)) { decided.append(change) }
    }
    #expect(decided == [.some(4)])
    #expect((policy.bitsPerSecond ?? 0) < 1_000_000)
  }

  /// 851-2331: one large update (a first full frame, 256 KB over 2.6 s: 0.8 Mbit/s) weighs four samples and settles it.
  @Test func oneLargeFrameCanDecide() {
    var policy = VNCQualityPolicy()
    #expect(policy.observe(bytes: 256 * 1024, duration: .milliseconds(2600)) == .some(4))
  }

  @Test func smallUpdatesAreNotSamples() {
    var policy = VNCQualityPolicy()
    for _ in 0..<10 { #expect(policy.observe(bytes: 1000, duration: .seconds(1)) == nil) }
    #expect(policy.bitsPerSecond == nil)
  }
}
