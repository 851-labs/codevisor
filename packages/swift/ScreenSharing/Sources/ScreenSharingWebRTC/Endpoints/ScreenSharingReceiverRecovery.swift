import Foundation
import ScreenSharing

@MainActor
final class ScreenSharingReceiverRecovery {
  private let metrics: ScreenSharingMetrics
  private let codecFactory: ScreenSharingCodecFactory
  private let refreshRequester: ScreenSharingRefreshRequester
  private let deliveryVerifier: ScreenSharingDeliveryVerifier
  private let requestSendMeasurement = ScreenSharingEncoderRefreshRequest()

  init(
    metrics: ScreenSharingMetrics, codecFactory: ScreenSharingCodecFactory,
    videoRefresh: any ScreenSharingMessageChannel<ScreenSharingVideoRefreshMessage>,
    grace: Duration?, graceExtensions: Int?,
    nowNs: @escaping @Sendable () -> Int64 = { ScreenSharingMetrics.nowNs },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.metrics = metrics
    self.codecFactory = codecFactory
    let requestSendMeasurement = requestSendMeasurement
    refreshRequester = ScreenSharingRefreshRequester(
      available: { [weak videoRefresh] in videoRefresh?.isAvailable == true },
      send: { [weak videoRefresh] in
        guard videoRefresh?.send(.keyframe) == true else { return false }
        metrics.increment("videoRefreshRequestsSent")
        if requestSendMeasurement.consume() {
          metrics.label("sourceIdleRequestSentAtNs", String(ScreenSharingMetrics.nowNs))
        }
        return true
      },
      nowNs: nowNs, sleep: sleep)
    deliveryVerifier = ScreenSharingDeliveryVerifier(
      audit: codecFactory.deliveryAudit, grace: grace ?? ScreenSharingDeliveryVerifier.defaultGrace,
      graceExtensions: graceExtensions ?? ScreenSharingDeliveryVerifier.defaultGraceExtensions,
      refresh: { [refreshSignal = codecFactory.refreshSignal] in
        let now = String(ScreenSharingMetrics.nowNs)
        if refreshSignal.requestUnlessPending() {
          if metrics.increment("sourceIdleRecoveryInitiated") == 1 {
            metrics.label("sourceIdleRecoveryFirstInitiatedAtNs", now)
          }
          metrics.label("sourceIdleRecoveryLatestInitiatedAtNs", now)
        } else {
          if metrics.increment("sourceIdleRefreshAlreadyPending") == 1 {
            metrics.label("sourceIdleRefreshFirstAlreadyPendingAtNs", now)
          }
          metrics.label("sourceIdleRefreshLatestAlreadyPendingAtNs", now)
        }
      },
      report: { [audit = codecFactory.deliveryAudit] outcome in
        let now = ScreenSharingMetrics.nowNs
        func labelTargetDecoded() {
          if let met = audit.targetMetAtTimestampNs { metrics.label("sourceIdleTargetDecodedAtNs", String(met)) }
        }
        switch outcome {
        case .verified:
          metrics.increment("sourceIdleVerified")
          metrics.label("sourceIdleOutcome", "verified at notice")
          labelTargetDecoded()
        case .verifiedAfterGrace:
          metrics.increment("sourceIdleVerifiedAfterGrace")
          metrics.label("sourceIdleOutcome", "verified during grace")
          labelTargetDecoded()
        case .graceExtended:
          metrics.increment("sourceIdleGraceExtensions")
        case .refresh:
          metrics.increment("sourceIdleRefreshRequests")
          metrics.label("sourceIdleOutcome", "refresh requested")
          metrics.label("sourceIdleRefreshDecisionAtNs", String(now))
          requestSendMeasurement.request()
        case .recovered:
          metrics.increment("sourceIdleRecovered")
          metrics.label("sourceIdleOutcome", "recovered after refresh")
          labelTargetDecoded()
        case .retry: metrics.increment("sourceIdleRefreshRetries")
        case .retryExecuted:
          metrics.increment("sourceIdleRetriesExecuted")
          metrics.label("sourceIdleRetryLatestExecutedAtNs", String(now))
        }
      },
      sleep: sleep)
    codecFactory.refreshSignal.onChange { [weak self] event in
      let now = String(ScreenSharingMetrics.nowNs)
      if event.needed {
        if metrics.increment("refreshRecoveryPendingEvents") == 1 {
          metrics.label("refreshRecoveryFirstPendingAtNs", now)
        }
        metrics.label("refreshRecoveryLatestPendingAtNs", now)
      } else {
        if metrics.increment("refreshRecoveryClearedEvents") == 1 {
          metrics.label("refreshRecoveryFirstClearedAtNs", now)
        }
        metrics.label("refreshRecoveryLatestClearedAtNs", now)
      }
      Task { @MainActor in
        self?.refreshRequester.update(event)
        self?.deliveryVerifier.recoveryChanged(event)
      }
    }
  }

  func wake() { refreshRequester.wake() }

  func handle(_ message: ScreenSharingVideoRefreshMessage) {
    guard case .sourceIdle(let latestTimestampNs) = message else { return }
    metrics.increment("sourceIdleNoticesReceived")
    metrics.label("sourceIdleNoticeReceivedAtNs", String(ScreenSharingMetrics.nowNs))
    metrics.label(
      "sourceIdleNoticeDecodedTimestampNs",
      codecFactory.deliveryAudit.latestDecodedTimestampNs.map(String.init) ?? "none")
    metrics.label("sourceIdleNoticeTargetTimestampNs", String(latestTimestampNs))
    deliveryVerifier.noticed(latestTimestampNs: latestTimestampNs)
  }

  var pendingDeliveryVerification: Task<Void, Never>? { deliveryVerifier.pendingGrace }

  func close() -> [Task<Void, Never>] {
    [refreshRequester.close(), deliveryVerifier.close()].compactMap { $0 }
  }
}
