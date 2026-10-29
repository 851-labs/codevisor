import ScreenSharingBench
import Testing

struct BenchTimingFrameCheckTests {
  private static let ms: Int64 = 1_000_000

  @Test func aTimingFrameReadsWebRTCsStatisticAndSkipsUnconvertedOnes() throws {
    let converted = [
      "2895095789", "15814777", "15814778", "15814790", "15814790", "15814790", "15814777", "15814777", "15814791",
      "15814791", "15814820", "15814822", "15814829", "0", "1",
    ]
    let frame = try #require(BenchTimingFrame(statisticsValue: converted.joined(separator: ",")))

    #expect(frame.rtpTimestamp == 2_895_095_789)
    #expect([frame.encodeMs, frame.decodeMs, frame.captureToDecodedMs] == [12, 2, 45])
    #expect(
      BenchTimingFrame(
        statisticsValue: "2894960969,-8,-8,-2,-2,-1,-8,-8,15813287,15813287,15813349,15813351,15813358,0,1") == nil)
    #expect(BenchTimingFrame(statisticsValue: "1,2,3") == nil)
  }

  @Test(arguments: [(encodeMs: 12.0, agrees: true), (encodeMs: 6.0, agrees: false)])
  func eachTimingFrameIsComparedWithTheFrameCapturedAtTheSameTime(encodeMs: Double, agrees: Bool) throws {
    let timing = try #require(
      BenchTimingFrame(statisticsValue: "1,100,100,\(100 + encodeMs),0,0,0,0,0,0,140,142,150,0,1"))
    let offsetNs = 5 * Self.ms
    let matching = Self.frame(sourceNs: 100 * Self.ms + offsetNs + 2 * Self.ms)
    let others = [Self.frame(sourceNs: 60 * Self.ms), Self.frame(sourceNs: 120 * Self.ms + offsetNs)]

    let check = try #require(
      BenchTimingFrameCheck(timingFrames: [timing], frames: others + [matching], timingClockOffsetNs: offsetNs))

    #expect(check.count == 1)
    #expect(check.encode.deltaP50Ms == 12 - encodeMs)
    #expect([check.decode.deltaP50Ms, check.captureToDecoded.deltaP50Ms] == [0, 0])
    #expect(check.agrees == agrees)
  }

  @Test func timingFramesWithNoFrameCapturedNearbyAreLeftOut() throws {
    let timing = try #require(BenchTimingFrame(statisticsValue: "1,100,100,112,0,0,0,0,0,0,140,142,150,0,1"))

    let check = BenchTimingFrameCheck(
      timingFrames: [timing], frames: [Self.frame(sourceNs: 109 * Self.ms)], timingClockOffsetNs: 0)

    #expect(check == nil)
  }

  private static func frame(sourceNs: Int64) -> BenchFrameTimestamps {
    BenchFrameTimestamps(
      sourceNs: sourceNs, captureCallbackNs: sourceNs, encodeSubmitNs: sourceNs, encodeOutputNs: sourceNs + 12 * ms,
      decodeInputNs: sourceNs + 40 * ms, decodeOutputNs: sourceNs + 42 * ms, renderCommitNs: sourceNs + 43 * ms)
  }
}
