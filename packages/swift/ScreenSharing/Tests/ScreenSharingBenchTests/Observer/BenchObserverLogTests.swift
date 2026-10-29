import Foundation
import ScreenSharingBench
import Testing

struct BenchObserverLogTests {
  private static let jsonLines = """
    {"clock":"mach_continuous_ns","continuous_minus_absolute_ns":13500,"machine":"tamale","observer_cpu_pct":1.5,\
    "schema":"codevisor.screen-sharing.bench.observer/v1","source":"display 1"}
    {"callback_ns":2000,"pts_ns":1000,"version":42}
    {"callback_ns":3000,"pts_ns":2500,"unreadable":"checksum_mismatch"}

    """

  private static let log = BenchObserverLog(
    header: BenchObserverHeader(
      machine: "tamale", source: "display 1", continuousMinusAbsoluteNs: 13_500, observerCpuPct: 1.5),
    observations: [
      BenchObservation(ptsNs: 1_000, callbackNs: 2_000, reading: .version(42)),
      BenchObservation(ptsNs: 2_500, callbackNs: 3_000, reading: .checksumMismatch),
    ])

  @Test func theLogIsAHeaderLineNamingItsClockThenOneLinePerFrame() throws {
    #expect(String(decoding: try Self.log.jsonLines(), as: UTF8.self) == Self.jsonLines)
    #expect(try BenchObserverLog(jsonLines: Data(Self.jsonLines.utf8)) == Self.log)
  }

  @Test func aLogWithAnotherSchemaIsRejected() {
    let other = Self.jsonLines.replacingOccurrences(of: "observer/v1", with: "observer/v2")

    #expect(throws: BenchObserverLogError.unsupportedSchema("codevisor.screen-sharing.bench.observer/v2")) {
      try BenchObserverLog(jsonLines: Data(other.utf8))
    }
  }
}
