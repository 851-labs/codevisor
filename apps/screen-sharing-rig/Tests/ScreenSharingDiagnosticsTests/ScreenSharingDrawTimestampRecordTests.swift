import Testing

import ScreenSharing
@testable import ScreenSharingDiagnostics

@Suite struct ScreenSharingDrawTimestampRecordTests {
  @Test func recordsFirstDrawStartPerCodeSkipsRepeatsAndTruncatesAtTheLimit() {
    var record = ScreenSharingDrawTimestampRecord(limit: 3)
    let first = record.record(code: 0, startedAtSeconds: 100.000)
    let redraw = record.record(code: 0, startedAtSeconds: 100.004)  // redraw of the same code: first start kept
    let second = record.record(code: 1, startedAtSeconds: 100.017)
    let skipped = record.record(code: 3, startedAtSeconds: 100.051)  // skipped code 2 is simply absent
    #expect(first && !redraw && second && skipped)
    #expect(!record.truncated)
    let overLimit = record.record(code: 4, startedAtSeconds: 100.067)  // limit reached
    #expect(!overLimit)
    #expect(record.truncated && record.samples.count == 3)
    #expect(record.samples[0] == .init(code: 0, startedAtSeconds: 100.000))
    #expect(record.samples.map(\.code) == [0, 1, 3])
  }

  @Test func codeTimeMappingFollowsTheWorkloadSequenceAndAPausedWorkloadAddsNoEntries() {
    // The code drawn at time t is floor((t - start) * fps); a frozen (paused) workload keeps redrawing
    // the same code, which must not add samples. Draw starts are placed mid-slot so the expected
    // codes do not depend on floating-point rounding at slot boundaries.
    var sequence = ScreenSharingWorkloadSequence(framesPerSecond: 60, startedAtSeconds: 200)
    var record = ScreenSharingDrawTimestampRecord()
    for tick in 0..<5 {
      let t = 200 + (Double(tick) + 0.5) / 60  // mid-slot draw start: floor is exactly `tick`
      record.record(code: sequence.drawn(atSeconds: t), startedAtSeconds: t)
    }
    #expect(record.samples.map(\.code) == [0, 1, 2, 3, 4])
    sequence.freezeAtLastDrawn(atSeconds: 200.09)
    for tick in 5..<10 {
      let t = 200 + (Double(tick) + 0.5) / 60  // mid-slot draw start: floor is exactly `tick`
      record.record(code: sequence.drawn(atSeconds: t), startedAtSeconds: t)
    }
    #expect(record.samples.count == 5 && record.samples.last?.code == 4 && !record.truncated)
    #expect(ScreenSharingDrawTimestampRecord.defaultLimit == 20_000)
  }
}
