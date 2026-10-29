import ScreenSharingBench
import Testing

struct BenchObserverAgreementTests {
  @Test func agreementIsTheAbsolutePTSDifferenceAndMissesCountOnlyWhileTheOtherObserverRan() throws {
    let first = BenchObservedVersions([
      BenchObservation(ptsNs: 1_000_000, callbackNs: 0, reading: .version(1)),
      BenchObservation(ptsNs: 17_000_000, callbackNs: 0, reading: .version(2)),
      BenchObservation(ptsNs: 33_000_000, callbackNs: 0, reading: .version(3)),
    ])
    let second = BenchObservedVersions([
      BenchObservation(ptsNs: 1_000_000, callbackNs: 0, reading: .version(1)),
      BenchObservation(ptsNs: 33_500_000, callbackNs: 0, reading: .version(2)),
      BenchObservation(ptsNs: 50_000_000, callbackNs: 0, reading: .version(4)),
    ])

    let agreement = BenchObserverAgreement(first, second)

    #expect(agreement.absoluteDeltaMs == BenchDistribution([0, 16.5]))
    #expect(agreement.sharedVersions == 2)
    #expect(agreement.unmatchedVersions == 1)
  }
}
