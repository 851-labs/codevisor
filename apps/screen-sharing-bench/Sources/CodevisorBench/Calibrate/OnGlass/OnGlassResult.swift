import ScreenSharing
import ScreenSharingBench

struct OnGlassResult: Encodable {
  private struct PresentedFrame {
    let version: Int
    let viewer: ScreenSharingViewerTimestamps
  }

  let check = "on-glass"
  let clock = BenchObserverHeader.continuousClock
  let framesFed: Int
  let framesRecorded: Int
  let onGlassSources: [String: Int]
  let versionsObserved: Int
  let onGlassMinusObserverMs: BenchDistribution?
  let displayLinkTargetMinusObserverMs: BenchDistribution?
  let presentedTimeMinusObserverMs: BenchDistribution?
  let observerAgreement: ObserverAgreementResult

  init(fed versions: [Int64: Int], records: [ScreenSharingFrameRecord], logs: ObserverPair.Logs, sources: [String]) {
    let observed = BenchObservedVersions(logs.barcode)
    let frames = records.compactMap { record in
      versions[record.sourceTimestampNs].map { PresentedFrame(version: $0, viewer: record.viewer) }
    }
    framesFed = versions.count
    framesRecorded = frames.count
    onGlassSources = Dictionary(grouping: frames) { $0.viewer.onGlassSource?.rawValue ?? "none" }.mapValues(\.count)
    versionsObserved = observed.firstPtsNs.count
    let offsetNs = logs.continuousMinusAbsoluteNs
    onGlassMinusObserverMs = Self.errorsMs(frames, observed, offsetNs) { $0.onGlassNs }
    displayLinkTargetMinusObserverMs = Self.errorsMs(frames, observed, offsetNs) { $0.displayLinkTargetNs }
    presentedTimeMinusObserverMs = Self.errorsMs(frames, observed, offsetNs) {
      $0.onGlassSource == .presentedTime ? $0.onGlassNs : nil
    }
    observerAgreement = ObserverAgreementResult(sources: sources, logs: logs)
  }

  private static func errorsMs(
    _ frames: [PresentedFrame], _ observed: BenchObservedVersions, _ offsetNs: Int64,
    absoluteNs: (ScreenSharingViewerTimestamps) -> Int64?
  ) -> BenchDistribution? {
    var estimatedNs: [Int: Int64] = [:]
    for frame in frames {
      guard let estimate = absoluteNs(frame.viewer) else { continue }

      estimatedNs[frame.version] = estimate + offsetNs
    }
    return BenchDistribution(observed.delaysMs(since: estimatedNs).map { -$0 })
  }
}
