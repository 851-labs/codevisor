import CodevisorTestSupport
import Testing

@testable import ScreenSharing

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
    let label = try #require(snapshot.labels["lastRecorder"])
    #expect((0..<recorders).map { "recorder-\($0)" }.contains(label))
    #expect(try #require(snapshot.traces?["boundary"]).count == 64)
  }

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

  @Test func singleValuesAndPercentilesReadTheSameRecords() throws {
    let metrics = ScreenSharingMetrics()
    #expect(metrics.counter("capturedFrames") == 0)
    #expect(metrics.label("decoderError") == nil)
    metrics.increment("capturedFrames", by: 2)
    metrics.label("decoderError", "bad slice")
    #expect(metrics.counter("capturedFrames") == 2)
    #expect(metrics.label("decoderError") == "bad slice")
    #expect(metrics.counters() == ["capturedFrames": 2])

    for index in 0..<2000 { metrics.observe("decodeMs", milliseconds: index < 200 ? 0 : Double(index)) }
    let snapshot = metrics.snapshot()
    let timing = try #require(snapshot.timings["decodeMs"])
    #expect(timing.count == 1800)
    #expect(timing.p50Ms == 1100 && timing.p95Ms == 1910 && timing.maximumMs == 1999)
    #expect(snapshot.counters == metrics.counters() && snapshot.labels == ["decoderError": "bad slice"])
  }

  @Test func aDurationThatIsNotAFiniteNonNegativeNumberIsNotRecorded() throws {
    let metrics = ScreenSharingMetrics()
    metrics.observe("encode", milliseconds: 5)
    for invalid in [Double.infinity, .nan, -1] { metrics.observe("encode", milliseconds: invalid) }
    let one = try #require(metrics.snapshot().timings["encode"])
    #expect(one.count == 1 && one.maximumMs == 5)

    for value in 1..<2000 { metrics.observe("encode", milliseconds: Double(value)) }
    for invalid in [Double.infinity, .nan, -1] { metrics.observe("encode", milliseconds: invalid) }
    let full = try #require(metrics.snapshot().timings["encode"])
    #expect(full.count == 1800)
    #expect(full.p50Ms == 1100 && full.p95Ms == 1910 && full.maximumMs == 1999)
  }

  @Test func cadenceSamplesOnlyForwardIntervalsAndNeverSpikesOnAClockThatWentBackwards() throws {
    let metrics = ScreenSharingMetrics()
    metrics.event("cadence", atNanoseconds: 1_000_000)
    #expect(metrics.snapshot().timings["cadence"] == nil)
    metrics.event("cadence", atNanoseconds: 3_000_000)
    metrics.event("cadence", atNanoseconds: 3_000_000)
    metrics.event("cadence", atNanoseconds: 1_000_000)
    metrics.event("cadence", atNanoseconds: 2_000_000)
    metrics.event("cadence", atNanoseconds: -5)
    metrics.event("cadence", atNanoseconds: 3_000_000)
    let timing = try #require(metrics.snapshot().timings["cadence"])
    #expect(timing.count == 4)
    #expect(timing.p50Ms == 1)
    #expect(timing.maximumMs == 2)
    metrics.event("other", atNanoseconds: 9_000_000)
    #expect(metrics.snapshot().timings["other"] == nil)
    metrics.event("other", atNanoseconds: 19_000_000)
    #expect(metrics.snapshot().timings["other"]?.count == 1 && metrics.snapshot().timings["other"]?.p50Ms == 10)
    #expect(metrics.snapshot().timings["cadence"]?.count == 4)
  }

  @Test func aDisabledTraceCostsNothingAndAnEnabledOneKeepsOnlyTheNewestEntries() throws {
    let metrics = ScreenSharingMetrics()
    let built = TestSignal()
    metrics.trace(
      "boundary",
      {
        built.signal()
        return "never built"
      }())
    #expect(built.value == 0)
    #expect(metrics.snapshot().traces == nil)

    metrics.enableTracing()
    var evaluated = 0
    for index in 1...100 {
      metrics.trace(
        "boundary",
        {
          evaluated += 1
          return "entry-\(index)"
        }())
    }
    #expect(evaluated == 100, "each enabled trace builds its entry exactly once")
    let traces = try #require(metrics.snapshot().traces?["boundary"])
    #expect(traces.count == 64)
    #expect(traces.first == "entry-37")
    #expect(traces.last == "entry-100")
  }
}
