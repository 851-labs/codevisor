import Testing

@testable import ScreenSharingRigKit

struct RigClockOffsetTests {
  typealias Sample = RigClockOffset.Sample

  @Test func intervalBracketsTheTrueOffsetWithoutAssumingSymmetry() throws {
    // True offset 1000 s; asymmetric delays: 1 ms out, 5 ms back; host processing 0.5 ms.
    let sample = Sample(
      sentAtSeconds: 10, hostReceivedAtSeconds: 1010.001, hostSentAtSeconds: 1010.0015, receivedAtSeconds: 10.0065)
    let interval = try #require(sample.interval)
    #expect(interval.low <= 1000 && 1000 <= interval.high)
    #expect(abs((interval.high - interval.low) - 0.006) < 1e-9, "width is the round trip minus host processing")
    let offset = try #require(RigClockOffset(samples: [sample]))
    #expect(abs(offset.offsetSeconds - 1000) <= offset.errorSeconds)
    #expect(abs(offset.errorSeconds - 0.003) < 1e-9)
    #expect(offset.sampleCount == 1)
  }

  @Test func tightestSampleWinsAndBadSamplesAreIgnored() throws {
    let wide = Sample(
      sentAtSeconds: 0, hostReceivedAtSeconds: 500.010, hostSentAtSeconds: 500.010, receivedAtSeconds: 0.050)
    let tight = Sample(
      sentAtSeconds: 1, hostReceivedAtSeconds: 501.001, hostSentAtSeconds: 501.001, receivedAtSeconds: 1.002)
    let backwards = Sample(sentAtSeconds: 2, hostReceivedAtSeconds: 502, hostSentAtSeconds: 502, receivedAtSeconds: 1.9)
    let offset = try #require(RigClockOffset(samples: [wide, backwards, tight]))
    #expect(offset.sampleCount == 2)
    #expect(abs(offset.errorSeconds - 0.001) < 1e-9)
    #expect(abs(offset.offsetSeconds - 500) < 0.001)
    #expect(RigClockOffset(samples: [backwards]) == nil)
    #expect(RigClockOffset(samples: []) == nil)
  }

  @Test func imageAgeSubtractsTheCalibratedOffset() throws {
    let offset = try #require(
      RigClockOffset(samples: [
        Sample(sentAtSeconds: 0, hostReceivedAtSeconds: 100, hostSentAtSeconds: 100, receivedAtSeconds: 0)
      ]))
    // Captured at host 105.000 s, presented at viewer 5.080 s → 80 ms old.
    let age = offset.imageAgeSeconds(sourceTimestampNs: 105_000_000_000, presentedAtSeconds: 5.080)
    #expect(abs(age - 0.080) < 1e-9)
  }
}
