import ScreenSharingBench
import Testing

struct BenchFrameArrivalsTests {
  private static let video: UInt32 = 0x1111_1111
  private static let retransmission: UInt32 = 0x2222_2222

  @Test func aFrameCompletesWithItsLastPacketDeliveredBeforeDecoding() {
    var arrivals = BenchFrameArrivals()
    arrivals.record(Self.rtp(ssrc: Self.video, timestamp: 1_000), deliveredAtNs: 10)
    arrivals.record(Self.rtp(ssrc: Self.video, timestamp: 1_000), deliveredAtNs: 12)
    arrivals.record(Self.rtp(ssrc: Self.retransmission, timestamp: 1_000), deliveredAtNs: 20)
    arrivals.record(Self.rtp(ssrc: Self.retransmission, timestamp: 1_000, padding: true), deliveredAtNs: 24)
    arrivals.record(Self.rtcp(timestampBytes: 1_000), deliveredAtNs: 26)
    arrivals.record([0x00, 0x01, 0x00, 0x08] + Array(repeating: 0, count: 16), deliveredAtNs: 28)
    arrivals.record(Self.rtp(ssrc: Self.retransmission, timestamp: 1_000), deliveredAtNs: 40)

    #expect(arrivals.completedNs(rtpTimestamp: 1_000, byNs: 30) == 20, "the retransmission completes the frame")
    #expect(arrivals.completedNs(rtpTimestamp: 2_500, byNs: 30) == nil)
  }

  private static func rtp(ssrc: UInt32, timestamp: UInt32, padding: Bool = false) -> [UInt8] {
    [padding ? 0xA0 : 0x80, 96, 0x00, 0x01] + bytes(timestamp) + bytes(ssrc) + [0xAB, 0xCD]
  }

  private static func rtcp(timestampBytes: UInt32) -> [UInt8] {
    [0x80, 200, 0x00, 0x06] + bytes(timestampBytes) + bytes(video) + Array(repeating: 0, count: 16)
  }

  private static func bytes(_ word: UInt32) -> [UInt8] {
    [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> $0) }
  }
}
