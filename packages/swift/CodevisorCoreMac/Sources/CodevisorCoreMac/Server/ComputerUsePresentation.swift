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
        NSColor(calibratedRed: 0.35, green: 0.34, blue: 0.84, alpha: 1),  // indigo
        NSColor(calibratedRed: 0.83, green: 0.32, blue: 0.31, alpha: 1),  // coral
        NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.45, alpha: 1),  // teal
        NSColor(calibratedRed: 0.80, green: 0.47, blue: 0.13, alpha: 1),  // amber
        NSColor(calibratedRed: 0.61, green: 0.31, blue: 0.73, alpha: 1),  // purple
        NSColor(calibratedRed: 0.17, green: 0.47, blue: 0.82, alpha: 1),  // blue
        NSColor(calibratedRed: 0.78, green: 0.31, blue: 0.60, alpha: 1),  // magenta
        NSColor(calibratedRed: 0.42, green: 0.56, blue: 0.14, alpha: 1),  // olive
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
        let slotMinX =
            horizontalPadding
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

private struct ComputerUsePresentationError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}
