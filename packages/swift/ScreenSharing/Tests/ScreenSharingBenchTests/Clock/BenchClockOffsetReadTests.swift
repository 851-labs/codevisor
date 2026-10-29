import Testing

@testable import ScreenSharingBench

struct BenchClockOffsetReadTests {
  private struct Read: CustomTestStringConvertible, Sendable {
    let name: String
    let before: UInt64
    let continuous: UInt64
    let after: UInt64
    let offsetTicks: UInt64

    var testDescription: String { name }
  }

  private static let reads = [
    Read(name: "never slept, one tick", before: 1_000, continuous: 1_000, after: 1_000, offsetTicks: 0),
    Read(name: "never slept, reads a tick apart", before: 1_000, continuous: 1_001, after: 1_001, offsetTicks: 1),
    Read(
      name: "continuous read before the absolute clock ticked", before: 1_001, continuous: 1_000, after: 1_002,
      offsetTicks: 0),
    Read(name: "after sleeping", before: 1_000, continuous: 5_001_000, after: 1_000, offsetTicks: 5_000_000),
  ]

  @Test(arguments: reads)
  private func theOffsetIsContinuousMinusTheFirstAbsoluteReadAndNeverNegative(_ read: Read) {
    let offset = BenchClockOffsetRead(
      absoluteBefore: read.before, continuous: read.continuous, absoluteAfter: read.after)

    #expect(offset.continuousMinusAbsoluteTicks == read.offsetTicks)
  }
}
