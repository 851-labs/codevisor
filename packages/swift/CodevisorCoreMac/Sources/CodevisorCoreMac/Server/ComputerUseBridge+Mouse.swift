import AppKit
import ApplicationServices
import Darwin
import Foundation

private typealias CGEventSetWindowLocationFunction = @convention(c) (CGEvent, CGPoint) -> Void
private typealias SLEventPostToPidFunction = @convention(c) (pid_t, CGEvent) -> Void
private typealias SLEventSetIntegerValueFieldFunction = @convention(c) (CGEvent, UInt32, Int64) -> Void

enum ComputerUseClickAddressing: Equatable {
    case semantic
    case pixel
    case ambiguous
    case invalid
}

struct ComputerUseChromiumClickStep: Equatable {
    enum Kind: Equatable {
        case move
        case down
        case up
    }

    let kind: Kind
    let point: CGPoint
    let windowPoint: CGPoint
    let phase: Int64
    let clickState: Int64
    let delayAfterMilliseconds: UInt32
}

func computerUseMouseButton(named name: String) -> String? {
    switch name.lowercased() {
    case "left", "l": "left"
    case "right", "r": "right"
    case "middle", "m": "middle"
    default: nil
    }
}

func computerUseClickAddressing(
    snapshotID: String?,
    elementID: String?,
    x: Double?,
    y: Double?
) -> ComputerUseClickAddressing {
    let hasSemanticTarget = elementID != nil
    let hasPixelTarget = x != nil || y != nil
    if hasSemanticTarget && hasPixelTarget { return .ambiguous }
    if snapshotID != nil, elementID != nil { return .semantic }
    if x != nil, y != nil { return .pixel }
    return .invalid
}

func computerUseUsesChromiumInput(
    appName: String?,
    bundleIdentifier: String?,
    executablePath: String?
) -> Bool {
    let identity = [appName, bundleIdentifier, executablePath]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    let chromiumIdentities = [
        "google chrome", "com.google.chrome", "chromium", "microsoft edge",
        "com.microsoft.edgemac", "brave browser", "com.brave.browser", "vivaldi",
        "com.vivaldi.vivaldi", "opera", "com.operasoftware.opera", "arc.app",
        "company.thebrowser.browser", "electron framework",
    ]
    return chromiumIdentities.contains(where: identity.contains)
}

func computerUseChromiumClickPlan(
    point: CGPoint,
    windowPoint: CGPoint,
    count: Int
) -> [ComputerUseChromiumClickStep] {
    var steps = [
        ComputerUseChromiumClickStep(
            kind: .move,
            point: point,
            windowPoint: windowPoint,
            phase: 2,
            clickState: 0,
            delayAfterMilliseconds: 15
        ),
        ComputerUseChromiumClickStep(
            kind: .down,
            point: CGPoint(x: -1, y: -1),
            windowPoint: CGPoint(x: -1, y: -1),
            phase: 1,
            clickState: 1,
            delayAfterMilliseconds: 1
        ),
        ComputerUseChromiumClickStep(
            kind: .up,
            point: CGPoint(x: -1, y: -1),
            windowPoint: CGPoint(x: -1, y: -1),
            phase: 2,
            clickState: 1,
            delayAfterMilliseconds: 100
        ),
    ]
    let clickPairs = min(2, max(1, count))
    for clickState in 1...clickPairs {
        steps.append(
            ComputerUseChromiumClickStep(
                kind: .down,
                point: point,
                windowPoint: windowPoint,
                phase: 3,
                clickState: Int64(clickState),
                delayAfterMilliseconds: 1
            ))
        steps.append(
            ComputerUseChromiumClickStep(
                kind: .up,
                point: point,
                windowPoint: windowPoint,
                phase: 3,
                clickState: Int64(clickState),
                delayAfterMilliseconds: clickState < clickPairs ? 80 : 0
            ))
    }
    return steps
}

/*
 The Chromium WindowServer event sequence above is adapted from Cua
 (https://github.com/trycua/cua), commit
 b8a0f32a06c75225ba24ebb5ab14f6507fa90d15.

 MIT License

 Copyright (c) 2025 Cua AI, Inc.

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

/// Small, dynamically-linked wrapper around the WindowServer event entry points
/// used by Chromium-class apps. Every caller retains the public CGEvent post as
/// a fallback, so an OS update that removes these symbols degrades cleanly.
private final class SkyLightEventBridge: @unchecked Sendable {
    static let shared = SkyLightEventBridge()

    private let postToPid: SLEventPostToPidFunction?
    private let setIntegerValueField: SLEventSetIntegerValueFieldFunction?
    private let setWindowLocation: CGEventSetWindowLocationFunction?

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL)
        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            let symbol = name.withCString { dlsym(handle, $0) }
            guard let symbol else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        postToPid = resolve("SLEventPostToPid", as: SLEventPostToPidFunction.self)
        setIntegerValueField = resolve(
            "SLEventSetIntegerValueField",
            as: SLEventSetIntegerValueFieldFunction.self
        )
        setWindowLocation = resolve(
            "CGEventSetWindowLocation",
            as: CGEventSetWindowLocationFunction.self
        )
    }

    var supportsTargetedPost: Bool { postToPid != nil }

    func setInteger(_ event: CGEvent, field: UInt32, value: Int64) {
        setIntegerValueField?(event, field, value)
    }

    func setWindowPoint(_ event: CGEvent, point: CGPoint) {
        setWindowLocation?(event, point)
    }

    func post(_ event: CGEvent, to pid: pid_t) {
        // The SkyLight post reaches Chromium's WindowServer path. The public
        // post remains necessary for AppKit/Catalyst targets that ignore it.
        postToPid?(pid, event)
        event.postToPid(pid)
    }
}

extension ComputerUseBridge {
    func mouseClick(
        _ point: CGPoint,
        count: Int,
        button: String,
        pid: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect?,
        chromium: Bool
    ) throws -> String {
        if chromium, button.caseInsensitiveCompare("left") == .orderedSame {
            guard let windowID, let windowFrame else {
                throw BridgeError(
                    "Chromium pixel delivery needs a visible target window. Restore the window and call get_app_state again."
                )
            }
            return try chromiumMouseClick(
                point,
                count: count,
                pid: pid,
                windowID: windowID,
                windowFrame: windowFrame
            )
        }
        let eventTypes: (down: CGEventType, up: CGEventType, button: CGMouseButton)
        switch button.lowercased() {
        case "right": eventTypes = (.rightMouseDown, .rightMouseUp, .right)
        case "middle": eventTypes = (.otherMouseDown, .otherMouseUp, .center)
        default: eventTypes = (.leftMouseDown, .leftMouseUp, .left)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw BridgeError("Unable to create targeted mouse event source")
        }
        let groupID = Int64(DispatchTime.now().uptimeNanoseconds & UInt64(Int64.max))
        for clickIndex in 1...max(1, count) {
            guard
                let moved = CGEvent(
                    mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                    mouseButton: eventTypes.button),
                let down = CGEvent(
                    mouseEventSource: source, mouseType: eventTypes.down, mouseCursorPosition: point,
                    mouseButton: eventTypes.button),
                let up = CGEvent(
                    mouseEventSource: source, mouseType: eventTypes.up, mouseCursorPosition: point,
                    mouseButton: eventTypes.button)
            else { throw BridgeError("Unable to create mouse event") }
            for (event, clickState, phase) in [
                (moved, 0, 2),
                (down, clickIndex, 3),
                (up, clickIndex, 3),
            ] {
                configureTargetedMouseEvent(
                    event,
                    point: point,
                    button: eventTypes.button,
                    clickState: clickState,
                    windowID: windowID,
                    windowFrame: windowFrame,
                    pid: pid,
                    groupID: groupID,
                    phase: Int64(phase)
                )
                SkyLightEventBridge.shared.post(event, to: pid)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        return SkyLightEventBridge.shared.supportsTargetedPost
            ? "skylight_pid"
            : "cgevent_pid"
    }

    private func configureTargetedMouseEvent(
        _ event: CGEvent,
        point: CGPoint,
        button: CGMouseButton,
        clickState: Int,
        windowID: CGWindowID?,
        windowFrame: CGRect?,
        pid: pid_t,
        groupID: Int64,
        phase: Int64 = 3,
        windowPoint: CGPoint? = nil
    ) {
        let skyLight = SkyLightEventBridge.shared
        event.location = point
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        skyLight.setInteger(event, field: 0, value: phase)
        skyLight.setInteger(event, field: 1, value: Int64(clickState))
        skyLight.setInteger(event, field: 3, value: Int64(button.rawValue))
        skyLight.setInteger(event, field: 7, value: 3)
        skyLight.setInteger(event, field: 40, value: Int64(pid))
        skyLight.setInteger(event, field: 58, value: groupID)
        guard let windowID else { return }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: Int64(windowID)
        )
        skyLight.setInteger(event, field: 51, value: Int64(windowID))
        skyLight.setInteger(event, field: 91, value: Int64(windowID))
        skyLight.setInteger(event, field: 92, value: Int64(windowID))
        guard let windowFrame else { return }
        skyLight.setWindowPoint(
            event,
            point: windowPoint
                ?? CGPoint(x: point.x - windowFrame.minX, y: point.y - windowFrame.minY)
        )
    }

    private func chromiumMouseClick(
        _ point: CGPoint,
        count: Int,
        pid: pid_t,
        windowID: CGWindowID,
        windowFrame: CGRect
    ) throws -> String {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw BridgeError("Unable to create Chromium mouse event source")
        }
        let windowPoint = CGPoint(
            x: point.x - windowFrame.minX,
            y: point.y - windowFrame.minY
        )
        let groupID = Int64(DispatchTime.now().uptimeNanoseconds & UInt64(Int64.max))
        for step in computerUseChromiumClickPlan(
            point: point,
            windowPoint: windowPoint,
            count: count
        ) {
            let type: CGEventType
            switch step.kind {
            case .move: type = .mouseMoved
            case .down: type = .leftMouseDown
            case .up: type = .leftMouseUp
            }
            guard
                let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: step.point,
                    mouseButton: .left
                )
            else { throw BridgeError("Unable to create Chromium mouse event") }
            configureTargetedMouseEvent(
                event,
                point: step.point,
                button: .left,
                clickState: Int(step.clickState),
                windowID: windowID,
                windowFrame: windowFrame,
                pid: pid,
                groupID: groupID,
                phase: step.phase,
                windowPoint: step.windowPoint
            )
            SkyLightEventBridge.shared.post(event, to: pid)
            if step.delayAfterMilliseconds > 0 {
                usleep(step.delayAfterMilliseconds * 1_000)
            }
        }
        return SkyLightEventBridge.shared.supportsTargetedPost
            ? "skylight_chromium"
            : "cgevent_chromium_fallback"
    }

    func withAppFronted<T>(
        app: NSRunningApplication,
        window: AXUIElement,
        windowID: CGWindowID?,
        operation: () throws -> T
    ) throws -> T {
        let previous = NSWorkspace.shared.frontmostApplication
        let shouldRestore = previous?.processIdentifier != app.processIdentifier
        defer {
            if shouldRestore, let previous, !previous.isTerminated {
                Thread.sleep(forTimeInterval: 0.12)
                _ = previous.activate(options: [.activateAllWindows])
            }
        }
        _ = app.activate(options: [.activateAllWindows])
        _ = axPerformAction(window, kAXRaiseAction as CFString, pid: app.processIdentifier)
        for _ in 0..<8 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
            let url = app.bundleURL
        {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let opened = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                opened.signal()
            }
            _ = opened.wait(timeout: .now() + 2)
            for _ in 0..<8 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw BridgeError("Unable to bring the target app forward for foreground delivery")
        }
        if let windowID {
            for _ in 0..<12 where !windowIsOnVisibleSpace(windowID) {
                _ = axPerformAction(window, kAXRaiseAction as CFString, pid: app.processIdentifier)
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard windowIsOnVisibleSpace(windowID) else {
                throw BridgeError(
                    "The target window is on another Space and macOS did not bring that Space forward"
                )
            }
        }
        return try operation()
    }

    func drag(from: CGPoint, to: CGPoint, pid: pid_t, global: Bool = false) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw BridgeError("Unable to create targeted drag event source")
        }
        try postMouseEvent(type: .mouseMoved, source: source, point: from, button: .left, pid: pid, global: global)
        try postMouseEvent(type: .leftMouseDown, source: source, point: from, button: .left, pid: pid, global: global)
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            try postMouseEvent(
                type: .leftMouseDragged,
                source: source,
                point: CGPoint(
                    x: from.x + (to.x - from.x) * progress,
                    y: from.y + (to.y - from.y) * progress
                ),
                button: .left,
                pid: pid,
                global: global
            )
        }
        try postMouseEvent(type: .leftMouseUp, source: source, point: to, button: .left, pid: pid, global: global)
    }

    private func postMouseEvent(
        type: CGEventType,
        source: CGEventSource,
        point: CGPoint,
        button: CGMouseButton,
        pid: pid_t,
        global: Bool
    ) throws {
        guard
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button
            )
        else { throw BridgeError("Unable to create mouse event") }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        if global { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
        Thread.sleep(forTimeInterval: 0.02)
    }

    func scroll(
        at point: CGPoint,
        direction: String,
        pages: Double,
        pid: pid_t,
        global: Bool = false
    ) throws {
        let magnitude = Int32(min(Double(Int32.max), max(1, (12 * pages).rounded())))
        let vertical: Int32 = direction == "up" ? magnitude : direction == "down" ? -magnitude : 0
        let horizontal: Int32 = direction == "left" ? magnitude : direction == "right" ? -magnitude : 0
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
            )
        else { throw BridgeError("Unable to create scroll event") }
        event.location = point
        if global { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
    }
}
