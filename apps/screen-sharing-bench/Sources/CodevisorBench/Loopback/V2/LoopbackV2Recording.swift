import ScreenSharing
import ScreenSharingBench

struct LoopbackV2Recording: LoopbackRecorded {
  let system = BenchSystem.codevisorV2
  let startNs: Int64
  let produced: [BenchVersionEvent]
  let records: [ScreenSharingFrameRecord]
  let barcodes: [Int64: Int?]
  let hostCounters: [String: Int]
  let viewerCounters: [String: Int]
  let hostMedia: [String: Double]
  let viewerMedia: [String: Double]
  let mailboxDrops: Int
  let taps: (host: V2MediaTap, viewer: V2MediaTap)
  let timingFrames: [BenchTimingFrame] = []
  let qualityLevel = 0
  let codecFailure: String? = nil

  func frames(arrivals: BenchFrameArrivals, clockOffsetNs: Int64) -> [BenchFrameTimestamps] {
    var seen = Set<Int64>()
    return records.compactMap { record in
      guard let host = record.host, seen.insert(record.sourceTimestampNs).inserted else { return nil }

      let viewer = record.viewer
      return BenchFrameTimestamps(
        sourceNs: host.sckDisplayTimeNs, captureCallbackNs: host.captureCallbackNs,
        encodeSubmitNs: host.encodeSubmitNs, encodeOutputNs: host.encodeOutputNs, decodeInputNs: viewer.decodeInputNs,
        decodeOutputNs: viewer.decodeOutputNs, renderCommitNs: viewer.renderCommitNs, onGlassNs: viewer.onGlassNs,
        frameCompleteNs: viewer.decodeInputNs, media: media(record.sourceTimestampNs, completeNs: viewer.decodeInputNs))
    }
  }

  private func media(_ sourceNs: Int64, completeNs: Int64) -> BenchMediaFrameTimestamps? {
    guard let receipt = taps.viewer.receipt(sourceNs: sourceNs), let sent = taps.host.sentFrame(receipt.key) else {
      return nil
    }

    let firstOutNs = sent.queuedUs.map { sent.sendNs + Int64($0) * 1000 }
    return BenchMediaFrameTimestamps(
      sendNs: sent.sendNs, firstPacketOutNs: firstOutNs,
      lastPacketOutNs: firstOutNs.flatMap { first in sent.sendingUs.map { first + Int64($0) * 1000 } },
      firstPacketInNs: completeNs - Int64(receipt.assemblingUs) * 1000, recovery: receipt.recovery)
  }

  var drops: BenchResult.Drops {
    BenchResult.Drops(
      network: max(0, hostCounters["encodedFrames", default: 0] - viewerCounters["decodedFrames", default: 0]),
      jitter: mailboxDrops,
      encoder: hostCounters["captureReplacedBeforeEncode", default: 0]
        + hostCounters["encoderDroppedFrames", default: 0],
      capture: hostCounters["captureTransitionDrops", default: 0] + hostCounters["captureTimestampDrops", default: 0])
  }

  var codecErrors: Int {
    hostCounters["encodeErrors", default: 0] + viewerCounters["decodeErrors", default: 0]
  }

  var media: BenchMediaCounters? {
    V2MediaCounters.make(host: hostCounters, viewer: viewerCounters, hostMedia: hostMedia, viewerMedia: viewerMedia)
  }

  func bypassedTheRelay(_ relay: BenchRelayReport) -> Bool {
    Double(relay.media.bytes) < hostMedia["bytes_sent", default: 0]
  }
}
