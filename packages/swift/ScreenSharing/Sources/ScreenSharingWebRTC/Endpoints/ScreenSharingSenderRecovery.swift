import Foundation
import ScreenSharing

@MainActor
final class ScreenSharingSenderRecovery {
  private let metrics: ScreenSharingMetrics
  private let codecFactory: ScreenSharingCodecFactory
  private let frameSender: ScreenSharingFrameSender
  private let idleNotifier: ScreenSharingSourceIdleNotifier
  private var refreshRateLimit = ScreenSharingRefreshRateLimit()
  private let nowNs: @Sendable () -> Int64

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
    idleNotifier = ScreenSharingSourceIdleNotifier(
      monitor: monitor,
      evaluated: { metrics.increment("sourceIdleEvaluations") },
      resubmit: {
        metrics.increment("sourceIdleResubmissions")
        metrics.label(
          "sourceIdleState",
          monitor.resubmissionCount >= ScreenSharingSourceIdleMonitor.maximumQuickResubmissions
            ? "re-offering the latest capture at the slow bounded rate" : "re-offering the latest capture")
        frameSender.refreshLatest()
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
        metrics.label("sourceIdleNoticeAtNs", String(now))
        if let submitted = monitor.latestSubmittedNs {
          metrics.observe("sourceIdleNoticeDelay", milliseconds: Double(now - submitted) / 1_000_000)
        }
        return true
      },
      nowNs: nowNs, sleep: sleep)
  }

  func activate() { idleNotifier.activate() }

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

  func close() -> [Task<Void, Never>] { [idleNotifier.close()].compactMap { $0 } }
}
