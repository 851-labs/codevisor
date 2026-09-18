import CodevisorTestSupport
import Testing

@testable import ScreenSharing

/// Metrics are written from the capture queue, the encoder, the render loop and the main actor at
/// once, and read while all of that is happening. Losing a count would make a diagnostic lie, so the
/// totals here are exact rather than approximate.
struct ScreenSharingMetricsConcurrencyTests {
  @Test func everyRecorderOnEveryQueueIsCountedExactlyOnce() async throws {
    let metrics = ScreenSharingMetrics()
    metrics.enableTracing()
    let recorders = 16
    let perRecorder = 100
    let parked = TestSignal()
    let release = TestSignal()

    await withTaskGroup(of: Void.self) { group in
      for recorder in 0..<recorders {
        group.addTask {
          // Every recorder parks on one gate, so the writes genuinely overlap instead of finishing
          // in whatever order the pool happened to start them.
          parked.signal()
          await release.wait()
          for index in 0..<perRecorder {
            metrics.increment("frames")
            metrics.increment("bytes", by: 3)
            metrics.observe("encodeMs", milliseconds: Double(index % 10))
            metrics.event("cadence", atNanoseconds: Int64(index + 1) * 1_000_000)
            metrics.label("lastRecorder", "recorder-\(recorder)")
            metrics.trace("boundary", "recorder-\(recorder)-\(index)")
          }
        }
      }
      await parked.wait(for: recorders)
      release.signal()
    }

    let snapshot = metrics.snapshot()
    #expect(snapshot.counters["frames"] == recorders * perRecorder)
    #expect(snapshot.counters["bytes"] == recorders * perRecorder * 3)
    let encode = try #require(snapshot.timings["encodeMs"])
    #expect(encode.count == recorders * perRecorder)
    #expect(encode.maximumMs == 9)
    // A label is last-writer-wins, but it must be one recorder's whole value, never a torn one.
    let label = try #require(snapshot.labels["lastRecorder"])
    #expect((0..<recorders).map { "recorder-\($0)" }.contains(label))
    // The trace ring stays at its bound under contention rather than growing past it.
    #expect(try #require(snapshot.traces?["boundary"]).count == 64)
  }

  /// `increment` returns the post-increment value so a caller can label a first occurrence without a
  /// second lock. Under contention that means exactly one recorder may see each value.
  @Test func theValueReturnedByIncrementIsUniquePerCaller() async {
    let metrics = ScreenSharingMetrics()
    let recorders = 32
    let parked = TestSignal()
    let release = TestSignal()

    let observed = await withTaskGroup(of: Int.self) { group in
      for _ in 0..<recorders {
        group.addTask {
          parked.signal()
          await release.wait()
          return metrics.increment("starts")
        }
      }
      await parked.wait(for: recorders)
      release.signal()
      var values: [Int] = []
      for await value in group { values.append(value) }
      return values
    }
    #expect(Set(observed) == Set(1...recorders))
    #expect(metrics.snapshot().counters["starts"] == recorders)
  }

  /// Cadence is measured between events of one stage on one clock. A repeated timestamp is a real
  /// zero interval; a clock that jumps backwards must rebase instead of recording the jump.
  @Test func cadenceSamplesOnlyForwardIntervalsAndNeverSpikesOnAClockThatWentBackwards() throws {
    let metrics = ScreenSharingMetrics()
    metrics.event("cadence", atNanoseconds: 1_000_000)
    // The first event only establishes a baseline; there is nothing yet to measure against.
    #expect(metrics.snapshot().timings["cadence"] == nil)
    metrics.event("cadence", atNanoseconds: 3_000_000)
    metrics.event("cadence", atNanoseconds: 3_000_000)
    metrics.event("cadence", atNanoseconds: 1_000_000)
    metrics.event("cadence", atNanoseconds: 2_000_000)
    metrics.event("cadence", atNanoseconds: -5)
    metrics.event("cadence", atNanoseconds: 3_000_000)
    let timing = try #require(metrics.snapshot().timings["cadence"])
    // 2 ms, 0 ms, (rebase), 1 ms, (rejected), 1 ms.
    #expect(timing.count == 4)
    #expect(timing.p50Ms == 1)
    #expect(timing.maximumMs == 2)
    // Stages are independent: one stage's baseline never measures against another's.
    metrics.event("other", atNanoseconds: 9_000_000)
    #expect(metrics.snapshot().timings["other"] == nil)
  }

  @Test func aDisabledTraceCostsNothingAndAnEnabledOneKeepsOnlyTheNewestEntries() throws {
    let metrics = ScreenSharingMetrics()
    let built = TestSignal()
    #expect(!metrics.isTracing)
    metrics.trace(
      "boundary",
      {
        built.signal()
        return "never built"
      }())
    // The autoclosure is the whole point of the gate: nothing is formatted on a media path.
    #expect(built.value == 0)
    #expect(metrics.snapshot().traces == nil)

    metrics.enableTracing()
    for index in 1...100 { metrics.trace("boundary", "entry-\(index)") }
    let traces = try #require(metrics.snapshot().traces?["boundary"])
    #expect(traces.count == 64)
    #expect(traces.first == "entry-37")
    #expect(traces.last == "entry-100")
  }
}
