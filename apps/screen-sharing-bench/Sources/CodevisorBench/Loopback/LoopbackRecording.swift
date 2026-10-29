import ScreenSharing
import ScreenSharingBench

struct LoopbackRecording {
  let startNs: Int64
  let produced: [BenchVersionEvent]
  let readings: LoopbackInstruments.Readings
  let hostCounters: [String: Int]
  let viewerCounters: [String: Int]
  let codecFailure: String?
  let jitterDrops: Int

  var frames: [BenchFrameTimestamps] {
    readings.records.compactMap { record in
      guard let host = record.host else { return nil }

      let viewer = record.viewer
      return BenchFrameTimestamps(
        sourceNs: host.sckDisplayTimeNs, captureCallbackNs: host.captureCallbackNs,
        encodeSubmitNs: host.encodeSubmitNs, encodeOutputNs: host.encodeOutputNs, decodeInputNs: viewer.decodeInputNs,
        decodeOutputNs: viewer.decodeOutputNs, renderCommitNs: viewer.renderCommitNs, onGlassNs: viewer.onGlassNs)
    }
  }

  var codecErrors: Int {
    hostCounters["encodeErrors", default: 0] + viewerCounters["decodeErrors", default: 0]
  }

  var drops: BenchResult.Drops {
    BenchResult.Drops(
      network: max(0, hostCounters["encodedFrames", default: 0] - viewerCounters["decodedFrames", default: 0]),
      jitter: jitterDrops,
      encoder: hostCounters["encoderBackpressureDrops", default: 0] + hostCounters["encoderDroppedFrames", default: 0],
      capture: hostCounters["captureTransitionDrops", default: 0] + hostCounters["captureTimestampDrops", default: 0])
  }

  func unreadableFraction(of produced: [BenchVersionEvent]) -> Double {
    let checked = produced.compactMap { event in readings.barcodes[event.ns].map { $0 == event.version } }
    guard !checked.isEmpty else { return 0 }

    return Double(checked.count { !$0 }) / Double(checked.count)
  }
}
