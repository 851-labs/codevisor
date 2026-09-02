import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - DisclosureCollapse

extension VirtualizedTranscriptScrollView {
    func automaticallyCollapsedWorkedSections(
        previousRowsByKey: [String: TranscriptVirtualRow]
    ) -> Set<TranscriptWorkedSectionIdentity> {
        let previouslyFixedOpen = Set(
            previousRowsByKey.values.compactMap { row -> TranscriptWorkedSectionIdentity? in
                guard case let .header(_, isFixedExpanded) = row.workedSection?.role,
                    isFixedExpanded
                else { return nil }
                return row.workedSection?.identity
            }
        )
        let nowUserControlled = Set(
            rowByKey.values.compactMap { row -> TranscriptWorkedSectionIdentity? in
                guard case let .header(_, isFixedExpanded) = row.workedSection?.role,
                    !isFixedExpanded
                else { return nil }
                return row.workedSection?.identity
            }
        )
        return previouslyFixedOpen.intersection(nowUserControlled)
    }

    func canAnimateDisclosureCollapse(_ keys: [String]) -> Bool {
        guard !reduceMotion,
            initialPositionApplied,
            window != nil,
            transcriptDocumentView.alphaValue > 0
        else { return false }
        let visibleDocumentRect = NSRect(
            x: 0,
            y: contentView.bounds.minY,
            width: transcriptDocumentView.bounds.width,
            height: contentView.bounds.height
        )
        return keys.contains { key in
            guard let host = mountedHosts[key], host.layer != nil else { return false }
            return host.frame.intersects(visibleDocumentRect)
        }
    }

    /// The automatic settlement path retains only pixels that are already in
    /// the virtual window. One shared mask retracts them under the header while
    /// the canonical row set is already collapsed, matching the old local
    /// disclosure without measuring or mounting any additional content.
    func startAutomaticDisclosureCollapse(keys: [String]) {
        let hosts = keys.compactMap { key -> (String, TranscriptMountedRowHost)? in
            guard let host = mountedHosts.removeValue(forKey: key) else { return nil }
            return (key, host)
        }
        guard !hosts.isEmpty else { return }

        let presentationFrame = hosts.reduce(CGRect.null) { partial, entry in
            partial.union(entry.1.frame)
        }
        let container = TranscriptDisclosureCollapseContainer(frame: presentationFrame)
        container.wantsLayer = true
        container.setAccessibilityHidden(true)
        transcriptDocumentView.addSubview(container, positioned: .above, relativeTo: nil)

        for (_, host) in hosts {
            host.onHeightChange = nil
            host.setAccessibilityHidden(true)
            let frame = host.frame.offsetBy(
                dx: -presentationFrame.minX,
                dy: -presentationFrame.minY
            )
            host.removeFromSuperviewWithoutNeedingDisplay()
            host.frame = frame
            container.addSubview(host)
        }

        guard let layer = container.layer else {
            for (key, host) in hosts {
                host.removeFromSuperviewWithoutNeedingDisplay()
                storeDetachedHost(host, for: key)
            }
            container.removeFromSuperviewWithoutNeedingDisplay()
            return
        }

        let token = UUID()
        disclosureCollapsePresentations[token] = DisclosureCollapsePresentation(
            container: container,
            hosts: hosts
        )

        let mask = CAShapeLayer()
        mask.frame = container.bounds
        mask.fillColor = NSColor.black.cgColor
        mask.isGeometryFlipped = true
        let fullPath = CGPath(rect: container.bounds, transform: nil)
        let collapsedPath = CGPath(
            rect: CGRect(x: 0, y: 0, width: container.bounds.width, height: 0),
            transform: nil
        )
        mask.path = collapsedPath
        layer.mask = mask

        let clip = CABasicAnimation(keyPath: "path")
        clip.fromValue = fullPath
        clip.toValue = collapsedPath
        clip.duration = Self.disclosureExitDuration
        clip.timingFunction = disclosureTimingFunction
        clip.fillMode = .forwards
        clip.isRemovedOnCompletion = false
        mask.add(clip, forKey: Self.disclosureExitMaskAnimationKey)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.disclosureExitDuration
        fade.timingFunction = disclosureTimingFunction
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.opacity = 0
        layer.add(fade, forKey: Self.disclosureExitAnimationKey)

        disclosureExitTasks[token] = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(Self.disclosureExitDuration)
            )
            guard !Task.isCancelled else { return }
            self?.finishDisclosureCollapsePresentation(token: token)
        }
    }

    func finishDisclosureCollapsePresentation(token: UUID) {
        disclosureExitTasks.removeValue(forKey: token)?.cancel()
        guard let presentation = disclosureCollapsePresentations.removeValue(forKey: token) else {
            return
        }
        presentation.container.layer?.mask?.removeAnimation(
            forKey: Self.disclosureExitMaskAnimationKey
        )
        presentation.container.layer?.removeAnimation(forKey: Self.disclosureExitAnimationKey)
        presentation.container.removeFromSuperviewWithoutNeedingDisplay()
        for (key, host) in presentation.hosts {
            host.removeFromSuperviewWithoutNeedingDisplay()
            storeDetachedHost(host, for: key)
        }
        if !retiringHosts.isEmpty { requestDisplayFrame() }
    }

    func finishAllDisclosureCollapsePresentations() {
        for token in Array(disclosureCollapsePresentations.keys) {
            finishDisclosureCollapsePresentation(token: token)
        }
    }

    func presentedOriginY(for host: TranscriptMountedRowHost) -> CGFloat {
        host.layer?.presentation()?.frame.minY ?? host.frame.minY
    }

    /// The virtual layout and hit-testing geometry stay final throughout the
    /// transition. Core Animation carries only the bounded set of mounted rows
    /// from their old visual origins to those final frames, matching the
    /// disclosure body's exit instead of making the following content jump.
    func animatePendingDisclosureCollapse() {
        guard let startingOrigins = pendingDisclosureCollapseOrigins else { return }
        pendingDisclosureCollapseOrigins = nil
        guard !reduceMotion else { return }

        for (key, startingOriginY) in startingOrigins {
            guard let host = mountedHosts[key], let layer = host.layer else { continue }
            let translation = startingOriginY - host.frame.minY
            guard abs(translation) > 0.5 else { continue }

            layer.removeAnimation(forKey: Self.disclosureCollapseAnimationKey)
            let movement = CABasicAnimation(keyPath: "transform.translation.y")
            movement.fromValue = translation
            movement.toValue = 0
            movement.duration = Self.disclosureExitDuration
            movement.timingFunction = disclosureTimingFunction
            layer.add(movement, forKey: Self.disclosureCollapseAnimationKey)
        }
    }

    func performAnchoredDisclosureChange(
        in rowKey: String,
        change: @escaping () -> Void
    ) {
        guard initialPositionApplied,
            virtualLayout.indexByKey[rowKey] != nil
        else {
            change()
            return
        }

        beginDisclosureViewportAnchor()
        change()
    }

    func beginDisclosureViewportAnchor() {
        guard initialPositionApplied else { return }
        disclosureAnchorReleaseTask?.cancel()
        let anchor = TranscriptDisclosureViewportAnchor(
            id: UUID(),
            viewportTop: contentView.bounds.minY
        )
        disclosureViewportAnchor = anchor
        disclosureAnchorReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                self?.disclosureViewportAnchor?.id == anchor.id
            else { return }
            self?.disclosureViewportAnchor = nil
            self?.disclosureAnchorReleaseTask = nil
        }
    }

    func cancelDisclosureViewportAnchor() {
        disclosureAnchorReleaseTask?.cancel()
        disclosureAnchorReleaseTask = nil
        disclosureViewportAnchor = nil
    }
}
