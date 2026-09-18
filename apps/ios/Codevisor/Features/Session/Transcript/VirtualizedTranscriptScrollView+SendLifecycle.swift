import CodevisorCore
import CodevisorUI
import QuartzCore
import TranscriptKit
import UIKit

// MARK: - Send lifecycle

extension VirtualizedTranscriptScrollView {
  /// Arms the pending deadline for a newly received request.
  func beginPendingSendLifecycle(token: UInt64) {
    let now = CACurrentMediaTime()
    let deadline = pendingSendLifecycle.begin(token: token, at: now)
    pendingSendWatchdog?.cancel()
    pendingSendWatchdog = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(max(0, deadline - now)))
      guard !Task.isCancelled, let self,
        self.pendingSendLifecycle.isExpired(token: token, at: CACurrentMediaTime())
      else { return }
      self.resolvePendingSendDeadline(token: token)
    }
  }

  /// The pending deadline passed with the request still unclaimed. Fly into
  /// the laid-out destination if there is one; otherwise reveal the held
  /// model state. Either way the request is consumed here, never dropped
  /// by an expiring hold. Runs from a task continuation, outside any
  /// SwiftUI graph update, so the flight can begin directly.
  func resolvePendingSendDeadline(token: UInt64) {
    guard let request = pendingSendAnimationRequest, request.token == token else { return }
    let host = pendingSendAnimationRowKey.flatMap { mountedHosts[$0] }
    let resolution = TranscriptSendAnimationContract.pendingDeadlineResolution(
      targetIsMounted: host != nil,
      targetIsPresentationReady: host?.isPresentationReady == true
    )
    IOSNavigationDiagnostics.record(
      "transcript.sendAnimation.pendingDeadline", "token=\(token) resolution=\(resolution)")
    if resolution == .fly, !isDetaching {
      beginPendingSendAnimationIfPossible(force: true)
      guard pendingSendAnimationRequest?.token == token else { return }
    }
    if let sessionController {
      UserSendMorphCoordinator.shared.cancelStagedProxy(for: ObjectIdentifier(sessionController))
    }
    interruptSendPresentation()
  }

  func sendHistoryDestinationIsReady(
    request: UserSendAnimationRequest,
    sourceLayout: VirtualTranscriptLayout?,
    rowKey: String
  ) -> Bool {
    guard let targetRow = rowByKey[rowKey],
      TranscriptSendAnimationContract.isEligibleTarget(targetRow, for: request.destination),
      let targetIndex = rows.firstIndex(where: { $0.layoutKey == rowKey })
    else { return false }
    // The aggregate `.active` bridge is a valid tail: it reserves the
    // activity row's known height, and the precise projection that
    // replaces it inherits that measurement at completion.
    guard let sourceLayout,
      sourceLayout.indexByKey[rowKey] == nil,
      request.destination == .activeTurn
        || sourceLayout.keys.contains(where: { $0.hasPrefix("message:") })
    else { return true }
    return rows[targetIndex...].allSatisfy { row in
      let key = row.layoutKey
      guard row.id != .bottomSpacer else { return true }
      return TranscriptMountedWindowReadiness.isPromotable(
        key: key,
        measurements: measurements,
        hasPendingMeasurement: pendingMeasurements[key] != nil,
        host: mountedHosts[key]
      )
    }
  }

  func sendHistoryScreenYByRowKey() -> [String: CGFloat] {
    Dictionary(
      uniqueKeysWithValues: mountedHosts.map { key, host in
        (key, host.convert(host.bounds, to: nil).minY)
      }
    )
  }

  func sendAnimationTarget(
    in host: TranscriptRowHost,
    rowKey: String
  ) -> TranscriptSendAnimationTarget? {
    guard rowByKey[rowKey]?.isUserMessage == true,
      !host.bounds.isEmpty
    else { return nil }
    return TranscriptSendAnimationTarget(
      rowFrame: host.convert(host.bounds, to: nil)
    )
  }
}
