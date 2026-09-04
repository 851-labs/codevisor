import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - SendAnimation

extension VirtualizedTranscriptScrollView {
  func startPendingSendAnimationIfPossible() {
    guard !isApplyingSendCompletion else { return }
    if sendCompletionSourceScreenYByRowKey != nil {
      completePendingSendPresentationIfPossible()
      return
    }
    guard let request = pendingSendAnimationRequest,
      let rowKey = pendingSendAnimationRowKey
    else { return }
    guard request.destination != .activeTurn || !isActiveProjectionPending,
      initialPositionApplied, bounds.width > 0, bounds.height > 0,
      let host = mountedHosts[rowKey], host.isPresentationReady,
      sendHistoryDestinationIsReady(
        request: request,
        sourceLayout: pendingSendSourceLayout,
        rowKey: rowKey
      )
    else { return }

    // Prewarmed destinations do not own animation consumption, but their
    // full-screen layout is the authoritative endpoint for New Chat's
    // flight layer. Report it before the foreground-only claim gate.
    let usesExternalFlight: Bool
    if let onSendAnimationStarted,
      let target = sendAnimationTarget(in: host, rowKey: rowKey)
    {
      usesExternalFlight = onSendAnimationStarted(request, target)
    } else {
      usesExternalFlight = false
    }
    guard presentationRole == .foreground,
      let claimSendAnimation
    else { return }

    func claimAndClear() -> Bool {
      let claimed = claimSendAnimation(request)
      pendingSendAnimationRequest = nil
      pendingSendAnimationRowKey = nil
      pendingSendSourceLayout = nil
      pendingSendSourceScreenYByRowKey = nil
      return claimed
    }

    func claimAndCompleteWithoutAnimation() {
      let claimed = claimAndClear()
      finishSendPresentation()
      guard claimed else { return }
      onSendAnimationCompleted?(request)
    }

    guard !reduceMotion else {
      claimAndCompleteWithoutAnimation()
      return
    }
    guard host.layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil else {
      // If the bounded pending hold expired before exact geometry was
      // ready, the model row is already visible. Consume the request
      // without hiding that row a second time.
      claimAndCompleteWithoutAnimation()
      return
    }
    guard pendingSendAssistantPresentationIsIntact() else {
      // A bounded assistant hold that has expired is already visible.
      // Never hide it again late merely to run the outgoing flight.
      claimAndCompleteWithoutAnimation()
      return
    }
    guard pendingSendHistoryPresentationIsIntact() else {
      // Existing history has already fallen through to final model
      // geometry. Do not rewind it just to begin a late flight.
      claimAndCompleteWithoutAnimation()
      return
    }
    let sourceLayout = pendingSendSourceLayout
    let sourceScreenYByRowKey = pendingSendSourceScreenYByRowKey
    let bottomSpacerHeight =
      rows.last { $0.id == .bottomSpacer }.flatMap { row in
        if case let .bottomSpacer(height) = row.content { height } else { nil }
      } ?? 0
    let fallbackSourceY = contentOffset.y + bounds.height - bottomSpacerHeight + 48
    // Composer reports its editor frame in the global SwiftUI coordinate
    // space, which maps to window coordinates on iOS. Converting through
    // the canvas gives the row animation the real launch position rather
    // than an estimated offset above the bottom spacer.
    let sourceY =
      sendAnimationSourceFrame.map { sourceFrame in
        canvasView.convert(
          CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
          from: nil
        ).y
      } ?? fallbackSourceY
    guard
      let plan = TranscriptSendAnimationContract.plan(
        sourceY: sourceY,
        targetY: host.frame.minY
      )
    else {
      claimAndCompleteWithoutAnimation()
      return
    }
    let group = TranscriptSendAnimationLayerAnimations.flight(
      plan: plan,
      fadesIn: !usesExternalFlight
    )
    let completion = TranscriptSendAnimationCompletion { [weak self] _ in
      self?.finishSendPresentation(token: request.token, notifyCompletion: true)
    }
    guard claimAndClear() else {
      finishSendPresentation()
      return
    }

    // Swap the first-frame hold for the flight in one display-server
    // transaction. There is no commit where the destination's visible
    // model layer can leak between those two presentation states.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    host.layer.removeAnimation(forKey: TranscriptSendAnimationKeys.flight)
    beginSendPresentation(
      request: request,
      sourceLayout: sourceLayout,
      sourceScreenYByRowKey: sourceScreenYByRowKey
    )
    if usesExternalFlight {
      holdSendPresentation(for: host)
    }
    activeSendAnimationRequest = request
    sendAnimationCompletion = completion
    group.delegate = completion
    host.layer.add(group, forKey: TranscriptSendAnimationKeys.flight)
    CATransaction.commit()
  }

  func beginSendPresentation(
    request: UserSendAnimationRequest,
    sourceLayout: VirtualTranscriptLayout?,
    sourceScreenYByRowKey: [String: CGFloat]?
  ) {
    finishSendPresentation()
    activeSendAnimationRequest = request
    activeSendSourceLayout = sourceLayout
    let now = CACurrentMediaTime()
    let deadline = sendPresentationLifecycle.begin(token: request.token, at: now)
    scheduleSendPresentationWatchdog(token: request.token, deadline: deadline, now: now)

    if let sourceScreenYByRowKey {
      for (key, host) in mountedHosts {
        guard let previousScreenY = sourceScreenYByRowKey[key] else { continue }
        let translation = TranscriptSendHistoryTransition.translationY(
          fromScreenY: previousScreenY,
          toScreenY: host.convert(host.bounds, to: nil).minY
        )
        guard abs(translation) > 1 else { continue }
        host.layer.removeAnimation(forKey: TranscriptSendAnimationKeys.historyShift)
        host.layer.add(
          TranscriptSendAnimationLayerAnimations.historyShift(translationY: translation),
          forKey: TranscriptSendAnimationKeys.historyShift
        )
      }
    }
    synchronizeSendAssistantVisibility()
  }

  func synchronizePendingSendTargetVisibility() {
    guard !reduceMotion, let request = pendingSendAnimationRequest else { return }
    let key = TranscriptVirtualRow.ID.message(request.messageID).layoutKey
    guard let host = mountedHosts[key],
      host.layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) == nil
    else { return }

    host.layer.add(
      TranscriptSendAnimationLayerAnimations.opacityHold(), forKey: TranscriptSendAnimationKeys.targetHold)
  }

  func synchronizePendingSendHistoryPositions() {
    guard presentationRole == .foreground,
      !reduceMotion,
      let sourceScreenYByRowKey = sendCompletionSourceScreenYByRowKey ?? pendingSendSourceScreenYByRowKey
    else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    for (key, host) in mountedHosts {
      guard let sourceScreenY = sourceScreenYByRowKey[key] else { continue }
      let currentScreenY = host.convert(host.bounds, to: nil).minY
      let translation = TranscriptSendHistoryTransition.translationY(
        fromScreenY: sourceScreenY,
        toScreenY: currentScreenY
      )
      let shouldHold = TranscriptSendAnimationContract.shouldHoldHistoryRow(
        phase: .pending,
        rowExistedBeforeSend: true,
        translationY: translation
      )
      guard shouldHold else {
        host.layer.removeAnimation(forKey: TranscriptSendAnimationKeys.historyHold)
        sendHistoryHoldMounts.removeValue(forKey: key)
        continue
      }

      let mountID = ObjectIdentifier(host)
      if let existing = sendHistoryHoldMounts[key], existing.hostID == mountID {
        if host.layer.animation(forKey: TranscriptSendAnimationKeys.historyHold) == nil {
          // This mount's bounded hold expired. Its model position is
          // visible now, so reapplying would create the same rewind
          // the pending hold exists to prevent.
          continue
        }
        if abs(existing.translationY - translation) <= 0.5 { continue }
      }
      sendHistoryHoldMounts[key] = SendHistoryHoldMount(
        hostID: mountID,
        translationY: translation
      )

      host.layer.add(
        TranscriptSendAnimationLayerAnimations.translationHold(translation),
        forKey: TranscriptSendAnimationKeys.historyHold)
    }
  }

  func synchronizeSendAssistantVisibility() {
    guard presentationRole == .foreground else { return }
    guard !reduceMotion else { return }
    let context: (phase: TranscriptSendPresentationPhase, sourceLayout: VirtualTranscriptLayout?)
    if activeSendAnimationRequest != nil {
      context = (.active, activeSendSourceLayout)
    } else if pendingSendAnimationRequest != nil {
      context = (.pending, pendingSendSourceLayout)
    } else {
      return
    }
    for (key, host) in mountedHosts {
      guard
        TranscriptSendAnimationContract.shouldHoldAssistantRow(
          phase: context.phase,
          rowIsActive: rowByKey[key]?.id.isActiveRow == true,
          rowExistedBeforeSend: context.sourceLayout?.indexByKey[key] != nil
        )
      else { continue }
      let mountID = ObjectIdentifier(host)
      guard sendAssistantHoldMounts[key] != mountID else { continue }
      sendAssistantHoldMounts[key] = mountID
      holdSendPresentation(for: host)
    }
  }

  func pendingSendAssistantPresentationIsIntact() -> Bool {
    guard pendingSendAnimationRequest != nil else { return true }
    return mountedHosts.allSatisfy { key, host in
      guard
        TranscriptSendAnimationContract.shouldHoldAssistantRow(
          phase: .pending,
          rowIsActive: rowByKey[key]?.id.isActiveRow == true,
          rowExistedBeforeSend: pendingSendSourceLayout?.indexByKey[key] != nil
        )
      else { return true }
      return host.layer.animation(forKey: TranscriptSendAnimationKeys.assistantHold) != nil
    }
  }

  func pendingSendHistoryPresentationIsIntact() -> Bool {
    guard let sourceScreenYByRowKey = pendingSendSourceScreenYByRowKey else {
      return true
    }
    return mountedHosts.allSatisfy { key, host in
      guard let sourceScreenY = sourceScreenYByRowKey[key] else { return true }
      let currentScreenY = host.convert(host.bounds, to: nil).minY
      let translation = TranscriptSendHistoryTransition.translationY(
        fromScreenY: sourceScreenY,
        toScreenY: currentScreenY
      )
      guard
        TranscriptSendAnimationContract.shouldHoldHistoryRow(
          phase: .pending,
          rowExistedBeforeSend: true,
          translationY: translation
        )
      else { return true }
      return host.layer.animation(forKey: TranscriptSendAnimationKeys.historyHold) != nil
    }
  }

  func finishSendPresentation(notifyCompletion: Bool = false) {
    _ = sendPresentationLifecycle.cancel()
    let request = activeSendAnimationRequest
    clearSendPresentationVisuals()
    if notifyCompletion, let request {
      onSendAnimationCompleted?(request)
    }
  }

  func finishSendPresentation(token: UInt64, notifyCompletion: Bool) {
    guard sendPresentationLifecycle.owns(token: token) else { return }
    sendCompletionNotifiesCompletion = sendCompletionNotifiesCompletion || notifyCompletion
    if sendCompletionSourceScreenYByRowKey == nil {
      sendCompletionSourceScreenYByRowKey = sendHistoryScreenYByRowKey()
      sendHistoryHoldMounts.removeAll(keepingCapacity: true)
    }
    completePendingSendPresentationIfPossible()
  }

  func clearSendPresentationVisuals() {
    let wasApplyingCompletion = isApplyingSendCompletion
    isApplyingSendCompletion = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      isApplyingSendCompletion = wasApplyingCompletion
    }
    sendCompletionSourceScreenYByRowKey = nil
    sendCompletionNotifiesCompletion = false
    applyDeferredSendProjectionIfNeeded()
    if !isDetaching { commitPendingMeasurements() }
    sendPresentationWatchdog?.cancel()
    sendPresentationWatchdog = nil
    for host in Array(mountedHosts.values) + Array(parkedHosts.values) {
      TranscriptSendAnimationLayerAnimations.removeAll(from: host.layer)
    }
    activeSendAnimationRequest = nil
    activeSendSourceLayout = nil
    sendHistoryHoldMounts.removeAll(keepingCapacity: true)
    sendAssistantHoldMounts.removeAll(keepingCapacity: true)
    sendAnimationCompletion = nil
  }

  func applyDeferredSendProjectionIfNeeded() {
    guard let deferredSendProjection else { return }
    self.deferredSendProjection = nil
    guard !isDetaching else { return }

    projectedRows = deferredSendProjection.projectedRows
    projectedRowsVersion = deferredSendProjection.projectedRowsVersion
    receivedProjectionRevision = deferredSendProjection.projectionRevision
    activeRows = deferredSendProjection.activeRows
    activeRowsVersion = deferredSendProjection.activeRowsVersion
    let resolution = resolvedRows(
      projectedRows: deferredSendProjection.projectedRows,
      activeRows: deferredSendProjection.activeRows
    )
    activeRowsRange = resolution.activeRange
    _ = applyRows(resolution.rows, layoutFingerprintChanged: false)
    appliedProjectionRevision = deferredSendProjection.projectionRevision
    setNeedsLayout()
  }

  func holdSendPresentation(for host: TranscriptRowHost) {
    // The model layer is authoritative content state and must never become
    // invisible. This finite presentation animation delays painting only;
    // interruption or expiry reveals the model value automatically.
    host.layer.opacity = 1
    assert(host.layer.opacity == 1)
    if host.layer.animation(forKey: TranscriptSendAnimationKeys.assistantHold) == nil {
      host.layer.add(
        TranscriptSendAnimationLayerAnimations.opacityHold(), forKey: TranscriptSendAnimationKeys.assistantHold)
    }
  }

  func scheduleSendPresentationWatchdog(
    token: UInt64,
    deadline: TimeInterval,
    now: TimeInterval
  ) {
    sendPresentationWatchdog?.cancel()
    sendPresentationWatchdog = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(max(0, deadline - now)))
      guard !Task.isCancelled, let self,
        self.sendPresentationLifecycle.isExpired(
          token: token,
          at: CACurrentMediaTime()
        )
      else { return }
      self.finishSendPresentation(notifyCompletion: true)
    }
  }

  func interruptSendPresentation() {
    if presentationRole == .foreground,
      let pendingSendAnimationRequest,
      let claimSendAnimation
    {
      _ = claimSendAnimation(pendingSendAnimationRequest)
    }
    pendingSendAnimationRequest = nil
    pendingSendAnimationRowKey = nil
    pendingSendSourceLayout = nil
    pendingSendSourceScreenYByRowKey = nil
    finishSendPresentation(notifyCompletion: true)
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
    if request.destination == .activeTurn,
      !rows[targetIndex...].contains(where: { $0.id.isPreciselyProjectedActiveRow })
    {
      // The aggregate `.active` bridge can already be mounted and
      // measured while its server-adopted identity is still racing the
      // block projection. Starting from it would defer the real activity
      // row until flight completion, producing estimate -> measurement
      // bottom-pin jitter exactly when "Waiting on harness" appears.
      return false
    }
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
    in host: UIView,
    rowKey: String
  ) -> TranscriptSendAnimationTarget? {
    guard rowByKey[rowKey]?.isUserMessage == true,
      !host.bounds.isEmpty,
      let snapshot = host.snapshotView(afterScreenUpdates: false)
    else { return nil }
    snapshot.isUserInteractionEnabled = false
    snapshot.accessibilityElementsHidden = true
    snapshot.backgroundColor = .clear
    return TranscriptSendAnimationTarget(
      rowFrame: host.convert(host.bounds, to: nil),
      rowSnapshot: snapshot
    )
  }
}
