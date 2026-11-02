import Foundation
import ScreenSharingBench
import Testing

@testable import CodevisorBench

struct Tier2V2ReadingsTests {
  private static let viewer = """
    {"counters": {"decodedFrames": 547, "skippedFrames": 2, "recovered.retransmission": 3,
      "recovered.forwardErrorCorrection": 1},
     "media": {"nacks_sent": 4, "frames_received": 547},
     "timings": {"assemble": {"count": 547, "p50_ms": 1.2, "p95_ms": 2.5, "maximum_ms": 9}},
     "timeline": {"stages": {
       "capture": {"count": 540, "p50_ms": 0, "p95_ms": 2.3, "maximum_ms": 2.8},
       "hostQueue": {"count": 540, "p50_ms": 0.07, "p95_ms": 0.08, "maximum_ms": 0.09},
       "encode": {"count": 540, "p50_ms": 11.8, "p95_ms": 12.8, "maximum_ms": 13},
       "jitterBuffer": {"count": 540, "p50_ms": 0, "p95_ms": 0, "maximum_ms": 0},
       "decode": {"count": 540, "p50_ms": 2.6, "p95_ms": 3, "maximum_ms": 3.7},
       "renderQueue": {"count": 540, "p50_ms": 0.3, "p95_ms": 0.6, "maximum_ms": 14},
       "present": {"count": 540, "p50_ms": 29.6, "p95_ms": 32.4, "maximum_ms": 33}}}}
    """
  private static let host = """
    {"counters": {"captureReplacedBeforeEncode": 5, "admissionDeferrals": 2, "encodedLTRRefreshes": 3,
      "encodedKeyFrames": 1},
     "media": {"frames_sent": 547, "frames_lost": 1, "packets_retransmitted": 6, "parity_packets_sent": 7,
      "estimate_kbps": 352000, "rtt_ms": 0.79},
     "timings": {"sendQueue": {"count": 547, "p50_ms": 0.2, "p95_ms": 0.4, "maximum_ms": 1},
      "send": {"count": 547, "p50_ms": 0.9, "p95_ms": 1.8, "maximum_ms": 4}}}
    """

  @Test func theViewerTimelineAndTheHostTimingsGiveTheStages() throws {
    let stages = try #require(
      Tier2V2Readings.stages(viewer: try Self.object(Self.viewer), host: try Self.object(Self.host), engineV2: true))

    #expect(stages.captureQueue == BenchDistribution(count: 540, p50: 0.07, p95: 0.08, max: 0.09))
    #expect(
      [stages.encode, stages.decodeQueue, stages.decode, stages.present].map { $0?.p50 } == [11.8, 0, 2.6, 29.6])
    #expect([stages.media?.queue, stages.media?.send, stages.media?.assemble].map { $0?.p50 } == [0.2, 0.9, 1.2])
  }

  @Test func theCountersComeFromBothSidesOfTheSession() throws {
    let counters = Tier2V2Readings.counters(viewer: try Self.object(Self.viewer), host: try Self.object(Self.host))

    #expect(
      counters
        == BenchMediaCounters(
          framesSent: 547, framesLost: 1, tilesSkipped: 2, droppedBeforeEncode: 5, admissionDeferrals: 2, nacksSent: 4,
          packetsRetransmitted: 6, parityPackets: 7, fecRepairs: 1, nackRepairs: 3, ltrRefreshes: 3, keyframes: 1,
          capacityKbps: 352_000, roundTripMs: 0.79))
  }

  private static func object(_ json: String) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
  }
}
