import AppKit
import CodevisorCore
import CoreGraphics
import Foundation
import QuartzCore

extension ComputerUsePresentationState {
    func startVisibilityMonitoringIfNeeded() {
        guard visibilityTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(visibilityTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    func stopVisibilityMonitoringIfNeeded() {
        guard sessions.isEmpty else { return }
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }

    @objc private func visibilityTimerFired(_ timer: Timer) {
        releaseIdleSessions()
        refreshCursorVisibility()
    }

    @objc func activeSpaceDidChange(_ notification: Notification) {
        refreshCursorVisibility()
    }

    @objc func frontmostApplicationDidChange(_ notification: Notification) {
        refreshCursorVisibility()
    }

    @objc func applicationDidTerminate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        targetTerminated(pid: app.processIdentifier)
    }

    func refreshCursorVisibility() {
        guard !sessions.isEmpty else { return }
        // Backstop for a termination that predates this observer or slipped
        // past the notification: a dead pid can never become visible again.
        let deadPIDs = Set(sessions.values.map(\.pid)).filter { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
            return app.isTerminated
        }
        for pid in deadPIDs { targetTerminated(pid: pid) }
        guard !sessions.isEmpty else { return }
        let visibleWindows = onScreenWindowInfo()
        var sessionsToRestart: [String] = []

        for sessionID in Array(sessions.keys) {
            guard var presentation = sessions[sessionID] else { continue }
            let targetIsVisible = computerUseCursorShouldBeVisible(
                targetWindowID: presentation.targetWindowID,
                targetPID: presentation.pid,
                windowInfo: visibleWindows
            )

            if !targetIsVisible {
                presentation.idleTimer?.invalidate()
                presentation.idleTimer = nil
                presentation.cursorPanel.orderOut(nil)
                sessions[sessionID] = presentation
                continue
            }

            guard let tip = presentation.displayedTip else {
                sessions[sessionID] = presentation
                continue
            }

            if presentation.cursorPanel.isVisible {
                // App activations can rewrite the normal-level WindowServer
                // stack. Re-pin defensively so the overlay stays adjacent to
                // its target rather than becoming globally topmost or buried.
                order(presentation.cursorPanel, relativeTo: presentation.targetWindowID)
                sessions[sessionID] = presentation
                continue
            }

            presentation.cursorPanel.alphaValue = 1
            place(presentation: presentation, tip: tip, rotation: 0, bodyOffset: .zero)
            order(presentation.cursorPanel, relativeTo: presentation.targetWindowID)
            sessions[sessionID] = presentation
            sessionsToRestart.append(sessionID)
        }

        for sessionID in sessionsToRestart {
            startIdleAnimation(sessionID: sessionID)
        }
    }

    func cursorShouldBeVisible(_ presentation: SessionPresentation) -> Bool {
        computerUseCursorShouldBeVisible(
            targetWindowID: presentation.targetWindowID,
            targetPID: presentation.pid,
            windowInfo: onScreenWindowInfo()
        )
    }

    private func onScreenWindowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
    }

    func order(_ panel: NSPanel, relativeTo targetWindowID: CGWindowID?) {
        panel.level = .normal
        if let targetWindowID {
            panel.order(.above, relativeTo: Int(targetWindowID))
        } else {
            panel.orderFrontRegardless()
        }
    }

    func matchingWindow(pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        return windows.compactMap { info -> (id: CGWindowID, overlap: CGFloat)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let candidate = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            let overlap = candidate.intersection(frame)
            return (number.uint32Value, overlap.width * overlap.height)
        }
        .max(by: { $0.overlap < $1.overlap })
        .map(\.id)
    }

    func appKitPoint(fromScreenStatePoint point: CGPoint) -> CGPoint {
        guard let mapping = screenMappings().first(where: { $0.cgFrame.contains(point) }) else {
            return point
        }
        return CGPoint(
            x: mapping.appKitFrame.minX + point.x - mapping.cgFrame.minX,
            y: mapping.appKitFrame.maxY - (point.y - mapping.cgFrame.minY)
        )
    }

    func constrained(_ point: CGPoint) -> CGPoint {
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.main ?? NSScreen.screens.first
        else { return point }
        let frame = screen.visibleFrame
        return CGPoint(
            x: min(frame.maxX - (cursorSize.width - cursorTipAnchor.x), max(frame.minX + cursorTipAnchor.x, point.x)),
            y: min(frame.maxY - (cursorSize.height - cursorTipAnchor.y), max(frame.minY + cursorTipAnchor.y, point.y))
        )
    }

    private func screenMappings() -> [(cgFrame: CGRect, appKitFrame: CGRect)] {
        NSScreen.screens.compactMap { screen in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else { return nil }
            return (CGDisplayBounds(CGDirectDisplayID(number.uint32Value)), screen.frame)
        }
    }
}
