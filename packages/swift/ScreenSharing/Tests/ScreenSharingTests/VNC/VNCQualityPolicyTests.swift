import Testing
@testable import ScreenSharing

struct VNCQualityPolicyTests {
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
    for _ in 0..<5 { #expect(Self.sample(&policy, milliseconds: 41) == nil) }
    var changed: Int?? = nil
    for _ in 0..<10 where changed == nil { changed = Self.sample(&policy, milliseconds: 20) }
    #expect(changed == .some(nil))
    #expect(policy.qualityLevel == nil)
  }

  @Test func aVerySlowLinkGetsTheLowerQuality() {
    var policy = VNCQualityPolicy()
    #expect(Self.sample(&policy, milliseconds: 1000) == nil)
    #expect(Self.sample(&policy, milliseconds: 1000) == nil)
    #expect(Self.sample(&policy, milliseconds: 1000) == .some(4))
    #expect(policy.description == "JPEG 4")
  }

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

  @Test func midSizedUpdatesPoolIntoSamples() {
    var policy = VNCQualityPolicy()
    var decided: [Int??] = []
    for _ in 0..<12 {
      if let change = policy.observe(bytes: 16 * 1024, duration: .milliseconds(200)) { decided.append(change) }
    }
    #expect(decided == [.some(4)])
    #expect((policy.bitsPerSecond ?? 0) < 1_000_000)
  }

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
