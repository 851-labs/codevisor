import AppKit
import CodevisorCore
import CoreGraphics
import Foundation
import QuartzCore

/// Software-cursor presentation plus the native ScreenCaptureKit sharing
/// lifecycle. Pointer movement is rendered in a separate, click-through
/// window and never changes the user's hardware cursor position.
enum ComputerUsePresentation {
    /// - Parameter resuming: true when the caller is deliberately re-observing
    ///   the app (`get_app_state`), which clears a transient stop so the agent
    ///   can carry on. Actions never clear it: a click fired at a stopped app
    ///   must fail loudly rather than silently resurrect the session.
    static func requireControlAllowed(
        sessionID: String,
        pid: pid_t,
        resuming: Bool = false
    ) throws {
        let key = ComputerUseShareKey(sessionID: sessionID, pid: pid)
        guard ComputerUseRevocations.shared.contains(key) else { return }
        if ComputerUseRevocations.shared.isPermanent(key) {
            throw ComputerUsePresentationError(
                "Computer Use for this app was stopped from the Codevisor menu bar. Start a new session to control it again."
            )
        }
        guard resuming else {
            throw ComputerUsePresentationError(
                "Computer Use sharing for this app was interrupted. Call get_app_state to resume, then retry."
            )
        }
        ComputerUseRevocations.shared.clearTransient(key)
    }

    static func activate(
        sessionID: String,
        agentLabel: String?,
        appName: String,
        pid: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect
    ) {
        performOnMain {
            ComputerUsePresentationState.shared.activate(
                sessionID: sessionID,
                agentLabel: agentLabel,
                appName: appName,
                pid: pid,
                windowID: windowID,
                windowFrame: windowFrame
            )
        }
    }

    /// Deliberately synchronous: the virtual cursor reaches and hovers over
    /// the target before the bridge posts the actual app event.
    static func moveCursor(sessionID: String, to point: CGPoint, pulse: Bool = false) {
        performOnMain {
            ComputerUsePresentationState.shared.moveCursor(
                sessionID: sessionID,
                to: point,
                pulse: pulse
            )
        }
    }

    static func end(sessionID: String) {
        performOnMain {
            ComputerUsePresentationState.shared.end(sessionID: sessionID)
        }
    }

    static func endAll() {
        performOnMain {
            ComputerUsePresentationState.shared.endAll()
        }
    }

    private static func performOnMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { body() }
            }
        }
    }
}

enum ComputerUseCursorMetrics {
    static let windowSize = CGSize(width: 126, height: 126)
    static let tipAnchor = CGPoint(x: 60.35, y: 70.3)
    static let pointerSize = CGSize(width: 15, height: 17)
    static let artworkRotation = 32 * CGFloat.pi / 180
}

/// Saturated mid-tones that stay legible over both light and dark app content
/// while remaining distinguishable from one another at pointer size.
enum ComputerUseCursorPalette {
    static let colors: [NSColor] = [
        NSColor(calibratedRed: 0.35, green: 0.34, blue: 0.84, alpha: 1), // indigo
        NSColor(calibratedRed: 0.83, green: 0.32, blue: 0.31, alpha: 1), // coral
        NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.45, alpha: 1), // teal
        NSColor(calibratedRed: 0.80, green: 0.47, blue: 0.13, alpha: 1), // amber
        NSColor(calibratedRed: 0.61, green: 0.31, blue: 0.73, alpha: 1), // purple
        NSColor(calibratedRed: 0.17, green: 0.47, blue: 0.82, alpha: 1), // blue
        NSColor(calibratedRed: 0.78, green: 0.31, blue: 0.60, alpha: 1), // magenta
        NSColor(calibratedRed: 0.42, green: 0.56, blue: 0.14, alpha: 1)  // olive
    ]

    static func color(at index: Int) -> NSColor {
        guard !colors.isEmpty else { return .black }
        return colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// How long a session may sit without issuing a tool call before its screen
/// sharing, cursor and menu bar entry are dropped.
///
/// Attachment used to last as long as the chat did, so a conversation left
/// open kept a window shared — indicator lit, cursor parked on screen — long
/// after the agent stopped working. Re-attaching costs the model nothing (it
/// happens implicitly on the next call, off the critical path), so the only
/// thing a longer window buys is fewer indicator blinks. A minute clears the
/// gaps between tool calls within a turn while still ending an idle share
/// promptly.
public let computerUseIdleReleaseAfter: TimeInterval = 60

/// Sessions whose last tool call is older than the idle window.
func computerUseIdleSessions(
    lastActivity: [String: Date],
    now: Date,
    releaseAfter: TimeInterval = computerUseIdleReleaseAfter
) -> [String] {
    lastActivity
        .filter { now.timeIntervalSince($0.value) >= releaseAfter }
        .map(\.key)
        .sorted()
}

/// FNV-1a; deterministic across launches so the same session prefers the same
/// cursor color every time it appears.
func computerUseStableHash(_ value: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for byte in value.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16_777_619
    }
    return hash
}

/// Deterministic palette assignment: a session always prefers the index its
/// hash selects, and only probes forward when a *concurrently active* session
/// already occupies that color. With every color taken, stability wins over
/// uniqueness so the session keeps its own hash color.
func computerUseCursorColorIndex(
    sessionID: String,
    takenIndices: Set<Int>,
    paletteCount: Int = ComputerUseCursorPalette.colors.count
) -> Int {
    guard paletteCount > 0 else { return 0 }
    let preferred = Int(computerUseStableHash(sessionID) % UInt32(paletteCount))
    guard takenIndices.contains(preferred), takenIndices.count < paletteCount else {
        return preferred
    }
    var candidate = preferred
    for _ in 0..<paletteCount {
        candidate = (candidate + 1) % paletteCount
        if !takenIndices.contains(candidate) { return candidate }
    }
    return preferred
}

/// Keep the cursor's visual hotspot at the exact event coordinate. The
/// transparent glow window is intentionally allowed to extend beyond a screen
/// edge; clamping the whole window would move the pointer away from the click.
func computerUseCursorPanelOrigin(for tip: CGPoint) -> CGPoint {
    CGPoint(
        x: tip.x - ComputerUseCursorMetrics.tipAnchor.x,
        y: tip.y - ComputerUseCursorMetrics.tipAnchor.y
    )
}

/// Rotate the pointer around its visual center while translating the rotated
/// artwork back just enough to keep its hotspot on the event coordinate.
func computerUseTipPreservingRotation(
    tip: CGPoint,
    pivot: CGPoint,
    angle: CGFloat
) -> CGAffineTransform {
    var transform = CGAffineTransform.identity
    transform = transform.translatedBy(x: pivot.x, y: pivot.y)
    transform = transform.rotated(by: angle)
    transform = transform.translatedBy(x: -pivot.x, y: -pivot.y)
    let transformedTip = tip.applying(transform)
    transform.tx += tip.x - transformedTip.x
    transform.ty += tip.y - transformedTip.y
    return transform
}

enum ComputerUseStatusMetrics {
    static let chipHeight: CGFloat = 24
    static let horizontalPadding: CGFloat = 6
    static let iconSize: CGFloat = 16
    static let iconStep: CGFloat = 18
    static let iconCursorSpacing: CGFloat = 5
    static let cursorSlotWidth: CGFloat = 17
    static let cursorSize = CGSize(width: 10, height: 12)
    static let cursorArtworkRotation = 40 * CGFloat.pi / 180

    static func width(appCount: Int) -> CGFloat {
        let count = CGFloat(max(appCount, 1))
        return horizontalPadding
            + iconSize
            + max(0, count - 1) * iconStep
            + iconCursorSpacing
            + cursorSlotWidth
            + horizontalPadding
    }

    static func iconFrame(index: Int, in bounds: CGRect) -> CGRect {
        CGRect(
            x: horizontalPadding + CGFloat(index) * iconStep,
            y: bounds.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
    }

    static func cursorFrame(appCount: Int, in bounds: CGRect) -> CGRect {
        let count = CGFloat(max(appCount, 1))
        let slotMinX = horizontalPadding
            + iconSize
            + max(0, count - 1) * iconStep
            + iconCursorSpacing
        return CGRect(
            x: slotMinX + (cursorSlotWidth - cursorSize.width) / 2,
            y: bounds.midY - cursorSize.height / 2,
            width: cursorSize.width,
            height: cursorSize.height
        )
    }
}

func computerUseTargetIsOnVisibleSpace(
    targetWindowID: CGWindowID?,
    pid: pid_t,
    windowInfo: [[String: Any]]
) -> Bool {
    if let targetWindowID {
        return windowInfo.contains { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else {
                return false
            }
            return number.uint32Value == targetWindowID
        }
    }

    // Window matching can occasionally fail for transient or unusual app
    // windows. Preserve the cursor in that case only when one of the app's
    // windows is actually present on a currently visible Space.
    return windowInfo.contains { info in
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
    }
}

func computerUseCursorShouldBeVisible(
    targetWindowID: CGWindowID?,
    targetPID: pid_t,
    windowInfo: [[String: Any]]
) -> Bool {
    computerUseTargetIsOnVisibleSpace(
        targetWindowID: targetWindowID,
        pid: targetPID,
        windowInfo: windowInfo
    )
}

@MainActor
final class ComputerUsePresentationState: NSObject {
    static let shared = ComputerUsePresentationState()

    private struct SessionPresentation {
        var pid: pid_t
        var targetWindowID: CGWindowID?
        var cursorPanel: ComputerUseCursorPanel
        var cursorView: ComputerUseCursorView
        var colorIndex: Int
        var displayedTip: CGPoint?
        var idleTimer: Timer?
        var idlePhase: CGFloat
    }

    private let cursorSize = ComputerUseCursorMetrics.windowSize
    private let cursorTipAnchor = ComputerUseCursorMetrics.tipAnchor
    private var sessions: [String: SessionPresentation] = [:]
    private var colorIndexBySession: [String: Int] = [:]
    /// When each session last drove the app, for idle release.
    private var lastActivityBySession: [String: Date] = [:]
    private var visibilityTimer: Timer?

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Without this, a controlled app that quits leaves its menu-bar entry,
        // cursor panel, and 4 Hz visibility poll behind forever.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    func activate(
        sessionID: String,
        agentLabel: String?,
        appName: String,
        pid: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect
    ) {
        guard !sessionID.isEmpty else { return }
        lastActivityBySession[sessionID] = Date()
        let targetWindowID = windowID ?? matchingWindow(pid: pid, frame: windowFrame)
        let colorIndex = colorIndex(for: sessionID)

        if var presentation = sessions[sessionID] {
            if presentation.pid != pid {
                // The session re-attached to a different process (a rebuilt
                // dev app is the common case). Retire the old pid's menu-bar
                // entry and sharing key or they would linger as duplicates.
                let staleKey = ComputerUseShareKey(sessionID: sessionID, pid: presentation.pid)
                ComputerUseControlStatusItem.shared.remove(key: staleKey)
                ComputerUseNativeSharing.shared.retire(key: staleKey)
            }
            presentation.pid = pid
            presentation.targetWindowID = targetWindowID
            presentation.colorIndex = colorIndex
            presentation.cursorView.tint = ComputerUseCursorPalette.color(at: colorIndex)
            sessions[sessionID] = presentation
        } else {
            let panel = ComputerUseCursorPanel(
                contentRect: CGRect(origin: .zero, size: cursorSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            configureCursorPanel(panel)
            let view = ComputerUseCursorView(frame: CGRect(origin: .zero, size: cursorSize))
            view.autoresizingMask = [.width, .height]
            view.tint = ComputerUseCursorPalette.color(at: colorIndex)
            panel.contentView = view
            sessions[sessionID] = SessionPresentation(
                pid: pid,
                targetWindowID: targetWindowID,
                cursorPanel: panel,
                cursorView: view,
                colorIndex: colorIndex,
                displayedTip: nil,
                idleTimer: nil,
                idlePhase: 0
            )
        }

        ComputerUseControlStatusItem.shared.activate(
            key: ComputerUseShareKey(sessionID: sessionID, pid: pid),
            appName: appName,
            agentLabel: agentLabel,
            colorIndex: colorIndex
        )

        ComputerUseNativeSharing.shared.activate(
            sessionID: sessionID,
            pid: pid,
            windowID: targetWindowID,
            windowFrame: windowFrame
        )
        startVisibilityMonitoringIfNeeded()
        refreshCursorVisibility()
    }

    func moveCursor(sessionID: String, to screenStatePoint: CGPoint, pulse: Bool) {
        lastActivityBySession[sessionID] = Date()
        guard var presentation = sessions[sessionID] else { return }
        presentation.idleTimer?.invalidate()
        presentation.idleTimer = nil
        let target = appKitPoint(fromScreenStatePoint: screenStatePoint)
        let targetIsVisible = cursorShouldBeVisible(presentation)

        if targetIsVisible {
            order(presentation.cursorPanel, relativeTo: presentation.targetWindowID)
            if pulse {
                if presentation.displayedTip != target {
                    animateMove(presentation: &presentation, sessionID: sessionID, to: target)
                }
                animateClick(presentation: presentation, at: target)
            } else {
                animateMove(presentation: &presentation, sessionID: sessionID, to: target)
            }
        } else {
            presentation.cursorPanel.orderOut(nil)
            presentation.cursorView.clickProgress = 0
            place(presentation: presentation, tip: target, rotation: 0, bodyOffset: .zero)
        }
        // The animations above pump the run loop, so another session's work —
        // or this session's own end/stop — may have run reentrantly. Writing
        // the stale copy back would resurrect a removed session's cursor.
        guard sessions[sessionID] != nil else {
            presentation.idleTimer?.invalidate()
            presentation.cursorPanel.orderOut(nil)
            return
        }
        presentation.displayedTip = target
        sessions[sessionID] = presentation
        if targetIsVisible {
            startIdleAnimation(sessionID: sessionID)
        }
    }

    func systemStopped(key: ComputerUseShareKey) {
        ComputerUseControlStatusItem.shared.remove(key: key)
        if let presentation = sessions[key.sessionID], presentation.pid == key.pid {
            presentation.idleTimer?.invalidate()
            presentation.cursorPanel.orderOut(nil)
            sessions.removeValue(forKey: key.sessionID)
            lastActivityBySession.removeValue(forKey: key.sessionID)
        }
        stopVisibilityMonitoringIfNeeded()
    }

    /// The user chose "Stop Using …" for one agent's control of one app.
    /// Revokes exactly that session/app pairing; other agents keep going.
    func stopUsing(key: ComputerUseShareKey) {
        ComputerUseRevocations.shared.insert(key)
        if let presentation = sessions[key.sessionID], presentation.pid == key.pid {
            presentation.idleTimer?.invalidate()
            presentation.cursorPanel.orderOut(nil)
            sessions.removeValue(forKey: key.sessionID)
            lastActivityBySession.removeValue(forKey: key.sessionID)
        }
        ComputerUseControlStatusItem.shared.remove(key: key)
        ComputerUseNativeSharing.shared.retire(key: key)
        stopVisibilityMonitoringIfNeeded()
    }

    /// The controlled app exited. Unlike `stopUsing`, nothing is revoked: the
    /// quit was not a user decision about Computer Use, and the same session
    /// may legitimately control a relaunched instance.
    func targetTerminated(pid: pid_t) {
        let sessionIDs = sessions.filter { $0.value.pid == pid }.map(\.key)
        for sessionID in sessionIDs {
            if let presentation = sessions.removeValue(forKey: sessionID) {
                presentation.idleTimer?.invalidate()
                presentation.cursorPanel.orderOut(nil)
            }
            lastActivityBySession.removeValue(forKey: sessionID)
        }
        ComputerUseControlStatusItem.shared.remove(pid: pid)
        ComputerUseNativeSharing.shared.targetTerminated(pid: pid)
        stopVisibilityMonitoringIfNeeded()
    }

    /// Drops the share, cursor and menu bar entry of a session that has gone
    /// quiet, without ending it: the next tool call re-attaches implicitly,
    /// keeping the same cursor colour, and any revocation still stands.
    private func releaseIdle(sessionID: String) {
        if let presentation = sessions.removeValue(forKey: sessionID) {
            presentation.idleTimer?.invalidate()
            presentation.cursorPanel.orderOut(nil)
        }
        lastActivityBySession.removeValue(forKey: sessionID)
        ComputerUseControlStatusItem.shared.remove(sessionID: sessionID)
        ComputerUseNativeSharing.shared.release(sessionID: sessionID)
        stopVisibilityMonitoringIfNeeded()
    }

    private func releaseIdleSessions() {
        for sessionID in computerUseIdleSessions(
            lastActivity: lastActivityBySession,
            now: Date()
        ) {
            Log.computerUse.log(
                "Releasing idle Computer Use attachment for session \(sessionID, privacy: .public)"
            )
            releaseIdle(sessionID: sessionID)
        }
    }

    func end(sessionID: String) {
        if let presentation = sessions.removeValue(forKey: sessionID) {
            presentation.idleTimer?.invalidate()
            presentation.cursorPanel.orderOut(nil)
        }
        colorIndexBySession.removeValue(forKey: sessionID)
        lastActivityBySession.removeValue(forKey: sessionID)
        ComputerUseControlStatusItem.shared.remove(sessionID: sessionID)
        ComputerUseNativeSharing.shared.end(sessionID: sessionID)
        stopVisibilityMonitoringIfNeeded()
    }

    func endAll() {
        for presentation in sessions.values {
            presentation.idleTimer?.invalidate()
            presentation.cursorPanel.orderOut(nil)
        }
        sessions.removeAll()
        colorIndexBySession.removeAll()
        lastActivityBySession.removeAll()
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        ComputerUseControlStatusItem.shared.removeAll()
        ComputerUseNativeSharing.shared.endAll()
    }

    /// Keeps the assignment stable for a session's whole lifetime while
    /// steering concurrent sessions away from one another's colors.
    private func colorIndex(for sessionID: String) -> Int {
        if let existing = colorIndexBySession[sessionID] { return existing }
        let taken = Set(sessions.keys.compactMap { colorIndexBySession[$0] })
        let index = computerUseCursorColorIndex(sessionID: sessionID, takenIndices: taken)
        colorIndexBySession[sessionID] = index
        return index
    }

    private func animateMove(
        presentation: inout SessionPresentation,
        sessionID: String,
        to target: CGPoint
    ) {
        let start = presentation.displayedTip ?? constrained(
            CGPoint(x: target.x - 74, y: target.y + 42)
        )
        let distance = hypot(target.x - start.x, target.y - start.y)
        if distance < 1 {
            place(presentation: presentation, tip: target, rotation: 0, bodyOffset: .zero)
            return
        }

        presentation.cursorPanel.alphaValue = presentation.displayedTip == nil ? 0 : 1
        order(presentation.cursorPanel, relativeTo: presentation.targetWindowID)
        let duration = min(0.62, max(0.22, 0.18 + Double(distance / 1_350)))
        let direction = CGVector(dx: target.x - start.x, dy: target.y - start.y)
        let unit = CGVector(dx: direction.dx / distance, dy: direction.dy / distance)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let side: CGFloat = computerUseStableHash(sessionID) & 1 == 0 ? 1 : -1
        let arc = min(86, max(18, distance * 0.16)) * side
        let control1 = CGPoint(
            x: start.x + direction.dx * 0.34 + normal.dx * arc,
            y: start.y + direction.dy * 0.34 + normal.dy * arc
        )
        let control2 = CGPoint(
            x: target.x - direction.dx * 0.26 + normal.dx * arc * 0.42,
            y: target.y - direction.dy * 0.26 + normal.dy * arc * 0.42
        )

        let startTime = CACurrentMediaTime()
        var previous = start
        while true {
            let elapsed = CACurrentMediaTime() - startTime
            let raw = min(1, max(0, elapsed / duration))
            let t = CGFloat(1 - pow(1 - raw, 3))
            let point = cubicBezier(start, control1, control2, target, t: t)
            let velocity = CGVector(dx: point.x - previous.x, dy: point.y - previous.y)
            let rotation = min(0.18, max(-0.18, atan2(velocity.dy, velocity.dx) * 0.08))
            let bodyOffset = CGVector(
                dx: min(3.2, max(-3.2, velocity.dx * -0.13)),
                dy: min(3.2, max(-3.2, velocity.dy * -0.13))
            )
            place(
                presentation: presentation,
                tip: point,
                rotation: rotation,
                bodyOffset: bodyOffset
            )
            presentation.cursorPanel.alphaValue = min(1, presentation.cursorPanel.alphaValue + 0.12)
            previous = point
            if raw >= 1 { break }
            pumpFrame()
        }
        place(presentation: presentation, tip: target, rotation: 0, bodyOffset: .zero)
    }

    private func startIdleAnimation(sessionID: String) {
        guard var presentation = sessions[sessionID], presentation.displayedTip != nil else {
            return
        }
        presentation.idleTimer?.invalidate()
        presentation.idlePhase = 0
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickIdleAnimation(sessionID: sessionID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        presentation.idleTimer = timer
        sessions[sessionID] = presentation
    }

    private func tickIdleAnimation(sessionID: String) {
        guard var presentation = sessions[sessionID], let tip = presentation.displayedTip else {
            return
        }
        presentation.idlePhase += 0.05
        let angle = sin(presentation.idlePhase * 0.8) * 0.09
        place(
            presentation: presentation,
            tip: tip,
            rotation: angle,
            bodyOffset: .zero,
            rotationAroundCenter: true
        )
        sessions[sessionID] = presentation
    }

    private func animateClick(presentation: SessionPresentation, at point: CGPoint) {
        let duration: CFTimeInterval = 0.18
        let start = CACurrentMediaTime()
        while true {
            let progress = min(1, max(0, (CACurrentMediaTime() - start) / duration))
            presentation.cursorView.clickProgress = CGFloat(sin(progress * .pi))
            presentation.cursorView.needsDisplay = true
            if progress >= 1 { break }
            pumpFrame()
        }
        presentation.cursorView.clickProgress = 0
        presentation.cursorView.needsDisplay = true
        place(presentation: presentation, tip: point, rotation: 0, bodyOffset: .zero)
    }

    private func place(
        presentation: SessionPresentation,
        tip: CGPoint,
        rotation: CGFloat,
        bodyOffset: CGVector,
        rotationAroundCenter: Bool = false
    ) {
        presentation.cursorPanel.setFrameOrigin(computerUseCursorPanelOrigin(for: tip))
        presentation.cursorView.rotation = rotation
        presentation.cursorView.rotationAroundCenter = rotationAroundCenter
        presentation.cursorView.bodyOffset = bodyOffset
        presentation.cursorView.needsDisplay = true
    }

    private func configureCursorPanel(_ panel: NSPanel) {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Stay in the normal window band and pin immediately above the target.
        // A floating panel would incorrectly draw over unrelated foreground
        // windows that merely overlap the controlled window.
        panel.level = .normal
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.animationBehavior = .none
    }

    private func startVisibilityMonitoringIfNeeded() {
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

    private func stopVisibilityMonitoringIfNeeded() {
        guard sessions.isEmpty else { return }
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }

    @objc private func visibilityTimerFired(_ timer: Timer) {
        releaseIdleSessions()
        refreshCursorVisibility()
    }

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        refreshCursorVisibility()
    }

    @objc private func frontmostApplicationDidChange(_ notification: Notification) {
        refreshCursorVisibility()
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
        targetTerminated(pid: app.processIdentifier)
    }

    private func refreshCursorVisibility() {
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

    private func cursorShouldBeVisible(_ presentation: SessionPresentation) -> Bool {
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

    private func order(_ panel: NSPanel, relativeTo targetWindowID: CGWindowID?) {
        panel.level = .normal
        if let targetWindowID {
            panel.order(.above, relativeTo: Int(targetWindowID))
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func matchingWindow(pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
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

    private func appKitPoint(fromScreenStatePoint point: CGPoint) -> CGPoint {
        guard let mapping = screenMappings().first(where: { $0.cgFrame.contains(point) }) else {
            return point
        }
        return CGPoint(
            x: mapping.appKitFrame.minX + point.x - mapping.cgFrame.minX,
            y: mapping.appKitFrame.maxY - (point.y - mapping.cgFrame.minY)
        )
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return point }
        let frame = screen.visibleFrame
        return CGPoint(
            x: min(frame.maxX - (cursorSize.width - cursorTipAnchor.x), max(frame.minX + cursorTipAnchor.x, point.x)),
            y: min(frame.maxY - (cursorSize.height - cursorTipAnchor.y), max(frame.minY + cursorTipAnchor.y, point.y))
        )
    }

    private func screenMappings() -> [(cgFrame: CGRect, appKitFrame: CGRect)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return (CGDisplayBounds(CGDirectDisplayID(number.uint32Value)), screen.frame)
        }
    }

    private func cubicBezier(
        _ p0: CGPoint,
        _ p1: CGPoint,
        _ p2: CGPoint,
        _ p3: CGPoint,
        t: CGFloat
    ) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
            y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        )
    }

    private func pumpFrame() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1 / 120))
    }
}

final class ComputerUseCursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The transparent glow may extend beyond a screen edge. Returning the
    /// requested frame prevents AppKit from moving the cursor hotspot away
    /// from the event coordinate when the panel is ordered onscreen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

struct ComputerUsePointerArtwork {
    let cgPath: CGPath
    let tip: CGPoint

    var path: NSBezierPath {
        NSBezierPath(cgPath: cgPath)
    }
}

/// The supplied 24×24 SVG path, converted from SVG's top-left coordinate
/// system to AppKit and rotated left around its real tip. Keeping the tip as a
/// first-class point lets the overlay place it exactly on the click target.
func computerUsePointerArtwork(
    size: CGSize,
    rotation: CGFloat = ComputerUseCursorMetrics.artworkRotation
) -> ComputerUsePointerArtwork {
    let svgPath = CGMutablePath()
    svgPath.move(to: CGPoint(x: 19.8683, y: 18.4886))
    svgPath.addLine(to: CGPoint(x: 13.8696, y: 4.16156))
    svgPath.addCurve(
        to: CGPoint(x: 13.1358, y: 3.31858),
        control1: CGPoint(x: 13.7257, y: 3.82006),
        control2: CGPoint(x: 13.4698, y: 3.52606)
    )
    svgPath.addCurve(
        to: CGPoint(x: 12, y: 3),
        control1: CGPoint(x: 12.8019, y: 3.11111),
        control2: CGPoint(x: 12.4058, y: 3)
    )
    svgPath.addCurve(
        to: CGPoint(x: 10.8642, y: 3.31858),
        control1: CGPoint(x: 11.5942, y: 3),
        control2: CGPoint(x: 11.1981, y: 3.11111)
    )
    svgPath.addCurve(
        to: CGPoint(x: 10.1304, y: 4.16156),
        control1: CGPoint(x: 10.5302, y: 3.52606),
        control2: CGPoint(x: 10.2743, y: 3.82006)
    )
    svgPath.addLine(to: CGPoint(x: 4.13171, y: 18.4886))
    svgPath.addCurve(
        to: CGPoint(x: 4.07537, y: 19.6206),
        control1: CGPoint(x: 3.97804, y: 18.8506),
        control2: CGPoint(x: 3.95828, y: 19.2476)
    )
    svgPath.addCurve(
        to: CGPoint(x: 4.78157, y: 20.5585),
        control1: CGPoint(x: 4.19245, y: 19.9935),
        control2: CGPoint(x: 4.44013, y: 20.3224)
    )
    svgPath.addCurve(
        to: CGPoint(x: 6.17127, y: 20.9995),
        control1: CGPoint(x: 5.1751, y: 20.8443),
        control2: CGPoint(x: 5.66562, y: 20.9999)
    )
    svgPath.addCurve(
        to: CGPoint(x: 7.401, y: 20.6665),
        control1: CGPoint(x: 6.6085, y: 20.9989),
        control2: CGPoint(x: 7.03599, y: 20.8832)
    )
    svgPath.addLine(to: CGPoint(x: 12, y: 17.9127))
    svgPath.addLine(to: CGPoint(x: 16.599, y: 20.6665))
    svgPath.addCurve(
        to: CGPoint(x: 17.9283, y: 20.9979),
        control1: CGPoint(x: 16.9918, y: 20.9012),
        control2: CGPoint(x: 17.4574, y: 21.0173)
    )
    svgPath.addCurve(
        to: CGPoint(x: 19.2184, y: 20.5585),
        control1: CGPoint(x: 18.3993, y: 20.9785),
        control2: CGPoint(x: 18.8512, y: 20.8246)
    )
    svgPath.addCurve(
        to: CGPoint(x: 19.9246, y: 19.6206),
        control1: CGPoint(x: 19.5599, y: 20.3224),
        control2: CGPoint(x: 19.8075, y: 19.9935)
    )
    svgPath.addCurve(
        to: CGPoint(x: 19.8683, y: 18.4886),
        control1: CGPoint(x: 20.0417, y: 19.2476),
        control2: CGPoint(x: 20.022, y: 18.8506)
    )
    svgPath.closeSubpath()

    var svgToAppKit = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 24)
    let appKitPath = svgPath.copy(using: &svgToAppKit) ?? svgPath
    let appKitTip = CGPoint(x: 12, y: 21)

    var artworkRotation = CGAffineTransform.identity
    artworkRotation = artworkRotation.translatedBy(x: appKitTip.x, y: appKitTip.y)
    artworkRotation = artworkRotation.rotated(by: rotation)
    artworkRotation = artworkRotation.translatedBy(x: -appKitTip.x, y: -appKitTip.y)
    let rotatedPath = appKitPath.copy(using: &artworkRotation) ?? appKitPath
    let rotatedTip = appKitTip.applying(artworkRotation)
    let sourceBounds = rotatedPath.boundingBoxOfPath
    let scale = min(
        size.width / max(0.001, sourceBounds.width),
        size.height / max(0.001, sourceBounds.height)
    )
    let xInset = (size.width - sourceBounds.width * scale) / 2
    let yInset = (size.height - sourceBounds.height * scale) / 2
    var normalize = CGAffineTransform(
        a: scale,
        b: 0,
        c: 0,
        d: scale,
        tx: -sourceBounds.minX * scale + xInset,
        ty: -sourceBounds.minY * scale + yInset
    )
    let normalizedPath = rotatedPath.copy(using: &normalize) ?? rotatedPath
    return ComputerUsePointerArtwork(
        cgPath: normalizedPath,
        tip: rotatedTip.applying(normalize)
    )
}

func computerUsePointerPath(tip: CGPoint, size: CGSize) -> NSBezierPath {
    let artwork = computerUsePointerArtwork(size: size)
    var placement = CGAffineTransform(
        translationX: tip.x - artwork.tip.x,
        y: tip.y - artwork.tip.y
    )
    return NSBezierPath(cgPath: artwork.cgPath.copy(using: &placement) ?? artwork.cgPath)
}

func computerUsePointerPath(
    in rect: CGRect,
    rotation: CGFloat = ComputerUseCursorMetrics.artworkRotation
) -> NSBezierPath {
    let artwork = computerUsePointerArtwork(size: rect.size, rotation: rotation)
    let bounds = artwork.cgPath.boundingBoxOfPath
    var placement = CGAffineTransform(
        translationX: rect.midX - bounds.midX,
        y: rect.midY - bounds.midY
    )
    return NSBezierPath(cgPath: artwork.cgPath.copy(using: &placement) ?? artwork.cgPath)
}

/*
 The procedural cursor proportions and general motion approach above and below are
 adapted from open-codex-computer-use (https://github.com/iFurySt/open-codex-computer-use),
 commit 460d281c0597ab83e703d0215affd9d89978c506.

 MIT License

 Copyright (c) 2026 Leo

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
*/
private final class ComputerUseCursorView: NSView {
    var rotation: CGFloat = 0
    var rotationAroundCenter = false
    var bodyOffset: CGVector = .zero
    var clickProgress: CGFloat = 0
    /// Per-agent accent. The pointer body and glow derive from this color so
    /// concurrent sessions are visually distinguishable at a glance.
    var tint: NSColor = .black {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let fogCenter = CGPoint(
            x: bounds.midX + bodyOffset.dx * 0.15,
            y: bounds.midY + bodyOffset.dy * 0.15
        )
        let radius: CGFloat = 28 + clickProgress * 1.0
        // Soften the accent toward the original neutral fog so the glow reads
        // as a subtle halo in the agent's color rather than a saturated blob.
        let fog = tint.blended(withFraction: 0.55, of: NSColor(calibratedWhite: 0.42, alpha: 1))
            ?? tint
        let colors = [
            fog.withAlphaComponent(0.32 + clickProgress * 0.02).cgColor,
            fog.withAlphaComponent(0.20 + clickProgress * 0.015).cgColor,
            fog.withAlphaComponent(0.07).cgColor,
            NSColor.clear.cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.50, 0.82, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: fogCenter,
                startRadius: 0,
                endCenter: fogCenter,
                endRadius: radius,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        let pointerTip = CGPoint(
            x: ComputerUseCursorMetrics.tipAnchor.x + bodyOffset.dx,
            y: ComputerUseCursorMetrics.tipAnchor.y + bodyOffset.dy
        )
        let path = computerUsePointerPath(
            tip: pointerTip,
            size: ComputerUseCursorMetrics.pointerSize
        )
        let rotationPivot = rotationAroundCenter
            ? CGPoint(x: path.bounds.midX, y: path.bounds.midY)
            : pointerTip

        context.saveGState()
        context.concatenate(
            computerUseTipPreservingRotation(
                tip: pointerTip,
                pivot: rotationPivot,
                angle: rotation
            )
        )
        context.translateBy(
            x: pointerTip.x,
            y: pointerTip.y
        )
        context.scaleBy(
            x: 1 - clickProgress * 0.04,
            y: 1 + clickProgress * 0.02
        )
        context.translateBy(
            x: -pointerTip.x,
            y: -pointerTip.y
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3.2 + clickProgress * 1.4
        shadow.shadowOffset = CGSize(width: 0, height: -0.35)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.11)
        shadow.set()
        NSColor.black.withAlphaComponent(0.05).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        tint.withAlphaComponent(0.94).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.90, alpha: 0.92).setStroke()
        path.lineWidth = 1.25
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
        context.restoreGState()
    }

}

/// ChatGPT's app-icons-plus-pointer control is a custom status item owned by
/// its Computer Use helper, not a ScreenCaptureKit-provided view. Keep our
/// native sharing stream for the purple system treatment and present the same
/// compact, actionable status affordance here.
@MainActor
private final class ComputerUseStatusView: NSView {
    var icons: [NSImage] = [] {
        didSet { needsDisplay = true }
    }
    var isActive = false {
        didSet { needsDisplay = true }
    }
    /// Matches the single active agent's cursor color; neutral when several
    /// agents share the chip.
    var cursorColor = NSColor(calibratedWhite: 0.94, alpha: 1) {
        didSet { needsDisplay = true }
    }
    var onActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let chipHeight = min(ComputerUseStatusMetrics.chipHeight, bounds.height)
        let chipRect = CGRect(
            x: bounds.minX,
            y: bounds.midY - chipHeight / 2,
            width: bounds.width,
            height: chipHeight
        )
        let capsule = NSBezierPath(
            roundedRect: chipRect,
            xRadius: chipHeight / 2,
            yRadius: chipHeight / 2
        )
        NSColor.labelColor.withAlphaComponent(isActive ? 0.24 : 0.16).setFill()
        capsule.fill()

        for (index, icon) in icons.enumerated() {
            icon.draw(
                in: ComputerUseStatusMetrics.iconFrame(index: index, in: bounds),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }

        let cursorPath = computerUsePointerPath(
            in: ComputerUseStatusMetrics.cursorFrame(appCount: icons.count, in: bounds),
            rotation: ComputerUseStatusMetrics.cursorArtworkRotation
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 0.8
        shadow.shadowOffset = CGSize(width: 0, height: -0.3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.set()
        cursorColor.setFill()
        cursorPath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class ComputerUseControlStatusItem: NSObject {
    static let shared = ComputerUseControlStatusItem()

    private struct Entry {
        let appName: String
        let icon: NSImage
        let agentLabel: String?
        let colorIndex: Int
    }

    private var entries: [ComputerUseShareKey: Entry] = [:]
    private var statusItem: NSStatusItem?
    private var statusView: ComputerUseStatusView?

    func activate(key: ComputerUseShareKey, appName: String, agentLabel: String?, colorIndex: Int) {
        entries[key] = Entry(
            appName: appName,
            icon: applicationIcon(pid: key.pid),
            agentLabel: agentLabel,
            colorIndex: colorIndex
        )
        refresh()
    }

    func remove(key: ComputerUseShareKey) {
        entries.removeValue(forKey: key)
        refresh()
    }

    func remove(pid: pid_t) {
        entries = entries.filter { $0.key.pid != pid }
        refresh()
    }

    func remove(sessionID: String) {
        entries = entries.filter { $0.key.sessionID != sessionID }
        refresh()
    }

    func removeAll() {
        entries.removeAll()
        refresh()
    }

    /// Backstop against stale rows: a pid with no live process can never be
    /// controlled again, so its entries must not survive in the menu bar.
    private func pruneTerminatedApps() {
        let deadPIDs = Set(entries.keys.map(\.pid)).filter { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
            return app.isTerminated
        }
        guard !deadPIDs.isEmpty else { return }
        entries = entries.filter { !deadPIDs.contains($0.key.pid) }
    }

    private func refresh() {
        pruneTerminatedApps()
        guard !entries.isEmpty else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
                statusView = nil
            }
            return
        }

        let controlledApps = controlledApps()
        let visibleApps = Array(controlledApps.prefix(4)).map(\.1)
        let width = ComputerUseStatusMetrics.width(appCount: visibleApps.count)
        let item: NSStatusItem
        if let statusItem {
            item = statusItem
        } else {
            item = NSStatusBar.system.statusItem(withLength: width)
            let view = ComputerUseStatusView(
                frame: CGRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: NSStatusBar.system.thickness
                )
            )
            view.toolTip = "Computer Use"
            view.onActivate = { [weak self] in
                self?.showMenu()
            }
            item.view = view
            statusItem = item
            statusView = view
        }

        item.length = width
        if let statusView {
            statusView.frame.size = CGSize(width: width, height: NSStatusBar.system.thickness)
            statusView.icons = visibleApps.map(\.icon)
            statusView.cursorColor = entries.count == 1
                ? ComputerUseCursorPalette.color(at: entries.values.first?.colorIndex ?? 0)
                : NSColor(calibratedWhite: 0.94, alpha: 1)
        }
    }

    private func showMenu() {
        pruneTerminatedApps()
        refresh()
        guard let statusView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // One row per agent/app pairing so stopping one agent's control never
        // tears down another agent that shares the same app.
        for (key, entry) in sortedEntries() {
            let title = "Stop Using \(entry.appName)"
                + (entry.agentLabel.map { " — \($0)" } ?? "")
            let menuItem = NSMenuItem(
                title: title,
                action: #selector(stopUsing(_:)),
                keyEquivalent: ""
            )
            let attributedTitle = NSMutableAttributedString(
                string: "● ",
                attributes: [
                    .foregroundColor: ComputerUseCursorPalette.color(at: entry.colorIndex)
                ]
            )
            attributedTitle.append(NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.labelColor]
            ))
            menuItem.attributedTitle = attributedTitle
            menuItem.target = self
            menuItem.representedObject = ComputerUseShareKeyBox(key: key)
            menuItem.image = entry.icon
            menuItem.image?.size = CGSize(width: 18, height: 18)
            menu.addItem(menuItem)
        }
        statusView.isActive = true
        statusView.displayIfNeeded()
        defer { statusView.isActive = false }
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: statusView.bounds.minX, y: statusView.bounds.minY),
            in: statusView
        )
    }

    private func controlledApps() -> [(pid_t, Entry)] {
        let entriesByPID = Dictionary(grouping: entries) { $0.key.pid }
        return entriesByPID.compactMap { pid, keyedEntries -> (pid_t, Entry)? in
            keyedEntries.first.map { (pid, $0.value) }
        }.sorted { lhs, rhs in
            lhs.1.appName.localizedCaseInsensitiveCompare(rhs.1.appName) == .orderedAscending
        }
    }

    private func sortedEntries() -> [(ComputerUseShareKey, Entry)] {
        entries.sorted { lhs, rhs in
            let appOrder = lhs.value.appName.localizedCaseInsensitiveCompare(rhs.value.appName)
            if appOrder != .orderedSame { return appOrder == .orderedAscending }
            return (lhs.value.agentLabel ?? "") < (rhs.value.agentLabel ?? "")
        }
    }

    @objc private func stopUsing(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ComputerUseShareKeyBox else { return }
        ComputerUsePresentationState.shared.stopUsing(key: box.key)
    }

    private func applicationIcon(pid: pid_t) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleURL = app.bundleURL {
            let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            icon.size = CGSize(width: 18, height: 18)
            return icon
        }
        return NSImage(
            systemSymbolName: "app.fill",
            accessibilityDescription: "Controlled app"
        ) ?? NSImage(size: CGSize(width: 18, height: 18))
    }

}

/// NSMenuItem.representedObject round-trips through Objective-C, so the value
/// key is carried in a small reference box rather than a bare Swift struct.
private final class ComputerUseShareKeyBox: NSObject {
    let key: ComputerUseShareKey
    init(key: ComputerUseShareKey) { self.key = key }
}

private struct ComputerUsePresentationError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}
