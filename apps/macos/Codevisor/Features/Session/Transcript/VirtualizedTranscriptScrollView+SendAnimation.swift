import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - SendAnimation

extension VirtualizedTranscriptScrollView {
  func sendRowPresentationDidBecomeReady() {
    guard !isDetaching,
      pendingSendAnimationRequest != nil || sendCompletionSourceViewportYByRowKey != nil
    else { return }
    // Never start or finish a flight inside a hosting controller's layout
    // callback: both operations can replace hosts and rebuild the document.
    if presentationDisplayLink != nil {
      requestDisplayFrame()
    } else {
      needsLayout = true
    }
  }

  /// Recreates the reference app's shared-element handoff without moving the
  /// virtual row's authoritative frame: its presentation layer starts at the
  /// bottom chrome's top edge, then eases into the row's final transcript
  /// slot. That origin naturally follows the queue panel while it is visible.
  /// Keeping layout geometry final throughout the flight means streaming and
  /// scroll compensation cannot fight the animation.
  ///
  /// Readiness is local: the destination row must be laid out and the rows
  /// below it measured. It never waits on the harness or on the precise
  /// active projection; both arrive under the flight's deferred projection
  /// and are revealed at completion. `force` (the pending deadline) skips
  /// the tail measurement requirement and flies into the laid-out row.
  func startPendingSendAnimationIfPossible(force: Bool = false) {
    guard !isApplyingSendCompletion else { return }
    if sendCompletionSourceViewportYByRowKey != nil {
      completePendingSendPresentationIfPossible()
      return
    }
    guard let request = pendingSendAnimationRequest,
      let rowKey = pendingSendAnimationRowKey,
      let claimSendAnimation
    else { return }

    func claimAndClear() -> Bool {
      let claimed = claimSendAnimation(request)
      pendingSendAnimationRequest = nil
      pendingSendAnimationRowKey = nil
      pendingSendSourceLayout = nil
      pendingSendSourceViewportYByRowKey = nil
      sendTargetHoldMount = nil
      return claimed
    }

    // Reduced motion still consumes the request exactly once, but it does
    // not need viewport geometry because no presentation flight will run.
    guard !reduceMotion else {
      _ = claimAndClear()
      finishSendPresentation()
      return
    }

    // makeNSView is configured before SwiftUI gives a newly promoted chat
    // real bounds. Its overscan window can still mount the target host at
    // placeholder geometry, so host existence alone is not readiness.
    // Keep the token pending until first-position restoration and a real
    // viewport have completed; layout() calls us again at that boundary.
    guard initialPositionApplied,
      contentView.bounds.width > 0,
      contentView.bounds.height > 0,
      let host = mountedHosts[rowKey],
      host.isPresentationReady,
      force
        || sendHistoryDestinationIsReady(
          request: request,
          sourceLayout: pendingSendSourceLayout,
          rowKey: rowKey
        )
    else { return }

    let sourceLayout = pendingSendSourceLayout
    let sourceViewportYByRowKey = pendingSendSourceViewportYByRowKey
    let bottomSpacerHeight =
      rows.last { $0.id == .bottomSpacer }.flatMap { row -> CGFloat? in
        guard case let .bottomSpacer(height) = row.content else { return nil }
        return height
      } ?? 0
    // The spacer includes 24 pt of transcript breathing room in addition
    // to the measured bottom overlay. Its inverse lands the bubble just
    // above the queue/accessory stack (or the composer when it is alone).
    let sourceY = contentView.bounds.maxY - bottomSpacerHeight + 48
    let travel = sourceY - host.frame.minY

    // Valid geometry can legitimately leave no visible distance to travel.
    // Consume that no-op only after readiness, never during placeholder
    // layout where the same value would incorrectly spend the first send.
    guard travel > 1 else {
      _ = claimAndClear()
      finishSendPresentation()
      return
    }

    guard let layer = host.layer else { return }
    // The holds are owned by this lifecycle and replaced by the flight
    // below; the pending watchdog resolves the request long before their
    // own safety bound. If one is nonetheless missing (a lost watchdog),
    // the model row is already visible and must not be hidden late.
    guard layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil,
      pendingSendAssistantPresentationIsIntact(),
      pendingSendHistoryPresentationIsIntact()
    else {
      _ = claimAndClear()
      finishSendPresentation()
      return
    }

    guard let plan = TranscriptSendAnimationContract.plan(sourceY: sourceY, targetY: host.frame.minY) else {
      _ = claimAndClear()
      finishSendPresentation()
      return
    }
    let group = TranscriptSendAnimationLayerAnimations.flight(plan: plan, fadesIn: true)
    let completion = TranscriptSendAnimationCompletion { [weak self] _ in
      self?.finishSendPresentation(token: request.token)
    }

    // Claim only when the real target host is ready. The controller keeps
    // this claim across representable rebuilds, preventing the same
    // request from replaying on a replacement NSView.
    guard claimAndClear() else {
      finishSendPresentation()
      return
    }

    // Removing the pending hold and adding the flight are one Core
    // Animation commit. The display server can therefore observe either
    // the hold or the flight, never the visible model layer between them.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.removeAnimation(forKey: TranscriptSendAnimationKeys.flight)
    beginSendPresentation(
      request: request,
      sourceLayout: sourceLayout,
      sourceViewportYByRowKey: sourceViewportYByRowKey
    )
    sendAnimationCompletion = completion
    group.delegate = completion
    layer.add(group, forKey: TranscriptSendAnimationKeys.flight)
    CATransaction.commit()
  }

  func beginSendPresentation(
    request: UserSendAnimationRequest,
    sourceLayout: VirtualTranscriptLayout?,
    sourceViewportYByRowKey: [String: CGFloat]?
  ) {
    finishSendPresentation()
    activeSendAnimationRequest = request
    activeSendSourceLayout = sourceLayout
    let now = CACurrentMediaTime()
    let deadline = sendPresentationLifecycle.begin(token: request.token, at: now)
    scheduleSendPresentationWatchdog(token: request.token, deadline: deadline, now: now)

    if let sourceViewportYByRowKey {
      for (key, host) in mountedHosts {
        guard let previousViewportY = sourceViewportYByRowKey[key],
          let layer = host.layer
        else { continue }
        let currentViewportY = host.frame.minY - contentView.bounds.minY
        let translation = TranscriptSendHistoryTransition.translationY(
          fromScreenY: previousViewportY,
          toScreenY: currentViewportY
        )
        guard abs(translation) > 1 else { continue }
        layer.removeAnimation(forKey: TranscriptSendAnimationKeys.historyShift)
        layer.add(
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
    guard let host = mountedHosts[key], let layer = host.layer else { return }
    // One hold per host and send. Keyed by host identity rather than by
    // the animation's presence so a later mount pass can never re-hide a
    // row that this lifecycle has already handed to the display.
    let mountID = ObjectIdentifier(host)
    guard sendTargetHoldMount != mountID else { return }
    sendTargetHoldMount = mountID
    layer.removeAnimation(forKey: TranscriptSendAnimationKeys.targetHold)
    layer.add(TranscriptSendAnimationLayerAnimations.opacityHold(), forKey: TranscriptSendAnimationKeys.targetHold)
  }

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
  /// by an expiring hold.
  func resolvePendingSendDeadline(token: UInt64) {
    guard let request = pendingSendAnimationRequest, request.token == token else { return }
    let host = pendingSendAnimationRowKey.flatMap { mountedHosts[$0] }
    switch TranscriptSendAnimationContract.pendingDeadlineResolution(
      targetIsMounted: host != nil,
      targetIsPresentationReady: host?.isPresentationReady == true
    ) {
    case .fly:
      startPendingSendAnimationIfPossible(force: true)
      guard pendingSendAnimationRequest?.token == token else { return }
      interruptSendPresentation()
    case .reveal:
      interruptSendPresentation()
    }
  }

  func synchronizePendingSendHistoryPositions() {
    guard !reduceMotion,
      let sourceViewportYByRowKey = sendCompletionSourceViewportYByRowKey ?? pendingSendSourceViewportYByRowKey
    else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    for (key, host) in mountedHosts {
      guard let sourceViewportY = sourceViewportYByRowKey[key],
        let layer = host.layer
      else { continue }
      let currentViewportY = host.frame.minY - contentView.bounds.minY
      let translation = TranscriptSendHistoryTransition.translationY(
        fromScreenY: sourceViewportY,
        toScreenY: currentViewportY
      )
      let shouldHold = TranscriptSendAnimationContract.shouldHoldHistoryRow(
        phase: .pending,
        rowExistedBeforeSend: true,
        translationY: translation
      )
      guard shouldHold else {
        layer.removeAnimation(forKey: TranscriptSendAnimationKeys.historyHold)
        sendHistoryHoldMounts.removeValue(forKey: key)
        continue
      }

      let mountID = ObjectIdentifier(host)
      if let existing = sendHistoryHoldMounts[key], existing.hostID == mountID {
        if layer.animation(forKey: TranscriptSendAnimationKeys.historyHold) == nil {
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

      layer.add(
        TranscriptSendAnimationLayerAnimations.translationHold(translation),
        forKey: TranscriptSendAnimationKeys.historyHold)
    }
  }

  func synchronizeSendAssistantVisibility() {
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
      guard let row = rowByKey[key],
        TranscriptSendAnimationContract.shouldHoldAssistantRow(
          phase: context.phase,
          rowID: row.id,
          rowExistedBeforeSend: context.sourceLayout?.indexByKey[key] != nil
        ), host.layer != nil
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
      guard let row = rowByKey[key],
        TranscriptSendAnimationContract.shouldHoldAssistantRow(
          phase: .pending,
          rowID: row.id,
          rowExistedBeforeSend: pendingSendSourceLayout?.indexByKey[key] != nil
        )
      else { return true }
      return host.layer?.animation(forKey: TranscriptSendAnimationKeys.assistantHold) != nil
    }
  }

  func pendingSendHistoryPresentationIsIntact() -> Bool {
    guard let sourceViewportYByRowKey = pendingSendSourceViewportYByRowKey else {
      return true
    }
    return mountedHosts.allSatisfy { key, host in
      guard let sourceViewportY = sourceViewportYByRowKey[key] else { return true }
      let currentViewportY = host.frame.minY - contentView.bounds.minY
      let translation = TranscriptSendHistoryTransition.translationY(
        fromScreenY: sourceViewportY,
        toScreenY: currentViewportY
      )
      guard
        TranscriptSendAnimationContract.shouldHoldHistoryRow(
          phase: .pending,
          rowExistedBeforeSend: true,
          translationY: translation
        )
      else { return true }
      return host.layer?.animation(forKey: TranscriptSendAnimationKeys.historyHold) != nil
    }
  }

  func finishSendPresentation() {
    _ = sendPresentationLifecycle.cancel()
    clearSendPresentationVisuals()
  }

  func finishSendPresentation(token: UInt64) {
    guard sendPresentationLifecycle.owns(token: token) else { return }
    if sendCompletionSourceViewportYByRowKey == nil {
      sendCompletionSourceViewportYByRowKey = sendHistoryViewportYByRowKey()
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
    sendCompletionSourceViewportYByRowKey = nil
    // Heights deferred during the flight enter the ledger before the
    // deferred projection replaces their rows, so the aggregate active
    // row's measurement carries into the precise rows that succeed it.
    if !isDetaching { commitPendingMeasurements() }
    applyDeferredSendProjectionIfNeeded()
    if !isDetaching { commitPendingMeasurements() }
    sendPresentationWatchdog?.cancel()
    sendPresentationWatchdog = nil
    for host in mountedHosts.values {
      guard let layer = host.layer else { continue }
      TranscriptSendAnimationLayerAnimations.removeAll(from: layer)
    }
    for host in recycledHosts {
      if let layer = host.layer { TranscriptSendAnimationLayerAnimations.removeAll(from: layer) }
    }
    for host in retiringHosts {
      if let layer = host.layer { TranscriptSendAnimationLayerAnimations.removeAll(from: layer) }
    }
    activeSendAnimationRequest = nil
    activeSendSourceLayout = nil
    sendHistoryHoldMounts.removeAll(keepingCapacity: true)
    sendAssistantHoldMounts.removeAll(keepingCapacity: true)
    sendTargetHoldMount = nil
    sendAnimationCompletion = nil
    // Rows retained for their held presentation can now be reconciled
    // against model geometry on the next frame.
    if !isDetaching { requestMountedRowsUpdate() }
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
    needsLayout = true
  }

  func holdSendPresentation(for host: TranscriptMountedRowHost) {
    guard let layer = host.layer else { return }
    // The model layer is authoritative content state and must never become
    // invisible. This finite presentation animation delays painting only;
    // interruption or expiry reveals the model value automatically.
    layer.opacity = 1
    assert(layer.opacity == 1)
    if layer.animation(forKey: TranscriptSendAnimationKeys.assistantHold) == nil {
      layer.add(
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
      self.finishSendPresentation()
    }
  }

  func interruptSendPresentation() {
    if let pendingSendAnimationRequest, let claimSendAnimation {
      _ = claimSendAnimation(pendingSendAnimationRequest)
    }
    pendingSendAnimationRequest = nil
    pendingSendAnimationRowKey = nil
    pendingSendSourceLayout = nil
    pendingSendSourceViewportYByRowKey = nil
    finishSendPresentation()
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
        hasPendingMeasurement: pendingMeasuredHeights[key] != nil,
        host: mountedHosts[key]
      )
    }
  }

  func sendHistoryViewportYByRowKey() -> [String: CGFloat] {
    Dictionary(
      uniqueKeysWithValues: mountedHosts.map { key, host in
        (key, host.frame.minY - contentView.bounds.minY)
      }
    )
  }
}
