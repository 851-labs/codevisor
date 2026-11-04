import Testing

@testable import ScreenSharingV2

extension ScreenSharingV2RefreshPhase {
  static let everyNanosecond = Self(periodNs: 1, offsetNs: 0)
}

struct ScreenSharingV2RefreshPhaseTests {
  @Test func withoutAFrameTheDueTimeStands() {
    let phase = ScreenSharingV2RefreshPhase(periodNs: 10_000, offsetNs: 2_000)

    #expect(phase.aligned(123_456) == 123_456)
  }

  @Test(arguments: [
    (dueNs: 100_000, alignedNs: 102_000),
    (dueNs: 102_000, alignedNs: 102_000),
    (dueNs: 102_001, alignedNs: 112_000),
    (dueNs: 95_000, alignedNs: 102_000),
    (dueNs: 91_000, alignedNs: 92_000),
  ])
  func aDueTimeMovesToTheOffsetAfterTheNextRefresh(dueNs: Int64, alignedNs: Int64) {
    var phase = ScreenSharingV2RefreshPhase(periodNs: 10_000, offsetNs: 2_000)
    phase.observe(frameAtNs: 100_000)

    #expect(phase.aligned(dueNs) == alignedNs)
  }
}
