import Foundation
import ScreenSharing

/// The host's half of frame recovery: answer the viewer's keyframe requests
/// (rate limited) and, when the source goes idle, announce the latest capture
/// so the viewer can verify it arrived despite loss no later packet reveals.
@MainActor
final class ScreenSharingSenderRecovery {
  private let metrics: ScreenSharingMetrics
  private let codecFactory: ScreenSharingCodecFactory
  private let frameSender: ScreenSharingFrameSender
  private let idleNotifier: ScreenSharingSourceIdleNotifier
  private var refreshRateLimit = ScreenSharingRefreshRateLimit()
  private let nowNs: @Sendable () -> Int64

  /// `videoRefresh` is the channel contract rather than the WebRTC carrier, and the clock and sleeper are injectable,
  /// so the recovery schedule can be driven as a state machine without a negotiated peer. The defaults are the
  /// production wiring: the shared monotonic clock and `Task.sleep`.
  init(
    metrics: ScreenSharingMetrics, codecFactory: ScreenSharingCodecFactory, frameSender: ScreenSharingFrameSender,
    videoRefresh: any ScreenSharingMessageChannel<ScreenSharingVideoRefreshMessage>,
    nowNs: @escaping @Sendable () -> Int64 = { ScreenSharingMetrics.nowNs },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.metrics = metrics
    self.codecFactory = codecFactory
    self.frameSender = frameSender
    self.nowNs = nowNs
    let monitor = codecFactory.sourceIdleMonitor
    // Announce idle once per activity period so the viewer can verify that
    // the newest frame arrived despite loss that no later packet reveals.
    idleNotifier = ScreenSharingSourceIdleNotifier(
      monitor: monitor,
      evaluated: { metrics.increment("sourceIdleEvaluations") },
      resubmit: {
        metrics.increment("sourceIdleResubmissions")
        metrics.label(
          "sourceIdleState",
          monitor.resubmissionCount >= ScreenSharingSourceIdleMonitor.maximumQuickResubmissions
            ? "re-offering the latest capture at the slow bounded rate" : "re-offering the latest capture")
        frameSender.refreshLatest(reason: "reoffer")
      },
      notify: { [weak videoRefresh] latestTimestampNs in
        guard videoRefresh?.send(.sourceIdle(latestTimestampNs: latestTimestampNs)) == true else {
          metrics.increment("sourceIdleNoticesDeferred")
          return false
        }
        let now = ScreenSharingMetrics.nowNs
        metrics.increment("sourceIdleNotices")
        metrics.label("sourceIdleLatestTimestampNs", String(latestTimestampNs))
        metrics.label("sourceIdleState", "latest capture announced")
        // Host clock only: last capture submission to notice.
        metrics.label("sourceIdleNoticeAtNs", String(now))
        if let submitted = monitor.latestSubmittedNs {
          metrics.observe("sourceIdleNoticeDelay", milliseconds: Double(now - submitted) / 1_000_000)
        }
        return true
      },
      nowNs: nowNs, sleep: sleep)
  }

  /// A frame was submitted: the idle notifier's activity period restarts.
  func activate() { idleNotifier.activate() }

  /// The refresh channel opened: a deferred notice can go out.
  func flush() { idleNotifier.flush() }

  func handle(_ message: ScreenSharingVideoRefreshMessage) {
    guard case .keyframe = message else { return }
    metrics.increment("videoRefreshRequestsReceived")
    guard refreshRateLimit.allow(nowNs: nowNs()) else {
      metrics.increment("videoRefreshRequestsThrottled")
      return
    }
    codecFactory.encoderRefreshRequest.request()
    frameSender.refreshLatest()
  }

  /// The owned tasks to await after close.
  func close() -> [Task<Void, Never>] { [idleNotifier.close()].compactMap { $0 } }
}
