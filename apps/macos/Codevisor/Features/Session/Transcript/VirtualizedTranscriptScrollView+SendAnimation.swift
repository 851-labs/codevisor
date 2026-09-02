import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - SendAnimation

extension VirtualizedTranscriptScrollView {
    /// Recreates the reference app's shared-element handoff without moving the
    /// virtual row's authoritative frame: its presentation layer starts at the
    /// bottom chrome's top edge, then eases into the row's final transcript
    /// slot. That origin naturally follows the queue panel while it is visible.
    /// Keeping layout geometry final throughout the flight means streaming and
    /// scroll compensation cannot fight the animation.
    func startPendingSendAnimationIfPossible() {
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
        guard request.destination != .activeTurn || !isActiveProjectionPending,
            initialPositionApplied,
            contentView.bounds.width > 0,
            contentView.bounds.height > 0,
            let host = mountedHosts[rowKey],
            host.isPresentationReady,
            sendHistoryDestinationIsReady(
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
        // The destination is held from its first mounted frame. If that
        // bounded presentation hold expired before geometry became ready,
        // leave the already-visible row alone instead of hiding it late and
        // producing a second flash.
        guard layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) != nil else {
            _ = claimAndClear()
            finishSendPresentation()
            return
        }
        guard pendingSendAssistantPresentationIsIntact() else {
            // A bounded assistant hold that has expired is already visible.
            // Never hide it again late merely to run the outgoing flight.
            _ = claimAndClear()
            finishSendPresentation()
            return
        }
        guard pendingSendHistoryPresentationIsIntact() else {
            // Existing history has already fallen through to final model
            // geometry. Do not rewind it just to begin a late flight.
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
        guard let host = mountedHosts[key], let layer = host.layer,
            layer.animation(forKey: TranscriptSendAnimationKeys.targetHold) == nil
        else { return }

        // Keep the model layer authoritative and use only a bounded
        // presentation hold. Readiness normally resolves in the following
        // layout passes; if it does not, startPendingSendAnimationIfPossible()
        // consumes the request without a late hide-and-flight transition.
        layer.add(TranscriptSendAnimationLayerAnimations.opacityHold(), forKey: TranscriptSendAnimationKeys.targetHold)
    }

    func synchronizePendingSendHistoryPositions() {
        guard !reduceMotion,
            pendingSendAnimationRequest != nil,
            let sourceViewportYByRowKey = pendingSendSourceViewportYByRowKey
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
            guard
                TranscriptSendAnimationContract.shouldHoldAssistantRow(
                    phase: context.phase,
                    rowIsActive: rowByKey[key]?.id.isActiveRow == true,
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
            guard
                TranscriptSendAnimationContract.shouldHoldAssistantRow(
                    phase: .pending,
                    rowIsActive: rowByKey[key]?.id.isActiveRow == true,
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
        guard sendPresentationLifecycle.complete(token: token) else { return }
        clearSendPresentationVisuals()
    }

    func clearSendPresentationVisuals() {
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
        sendAnimationCompletion = nil
        applyDeferredSendProjectionIfNeeded()
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
            self.finishSendPresentation(token: token)
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
                hasPendingMeasurement: false,
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
