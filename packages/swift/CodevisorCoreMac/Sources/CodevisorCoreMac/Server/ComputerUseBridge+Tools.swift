import AppKit
import ApplicationServices
import Foundation

extension ComputerUseBridge {
    func handleWindowedTool(
        tool: String,
        arguments: [String: Any],
        sessionID: String,
        agentLabel: String?,
        appName: String,
        app: NSRunningApplication,
        application: AXUIElement,
        window: AXUIElement,
        windowID: CGWindowID?
    ) throws -> [String: Any] {
        let target = try targetElement(sessionID: sessionID, arguments: arguments)
        activatePresentation(
            sessionID: sessionID,
            agentLabel: agentLabel,
            app: app,
            window: window,
            windowID: windowID
        )

        var actionMetadata: [String: Any]?
        switch tool {
        case "click":
            let clickCount = int(arguments["clickCount"] ?? arguments["click_count"]) ?? 1
            guard (1...2).contains(clickCount) else {
                throw BridgeError("clickCount must be 1 or 2")
            }
            let requestedButton = (arguments["button"] ?? arguments["mouse_button"]) as? String ?? "left"
            guard let button = computerUseMouseButton(named: requestedButton) else {
                throw BridgeError("button must be left, right, or middle")
            }
            let addressing = computerUseClickAddressing(
                snapshotID: ((arguments["snapshotId"] ?? arguments["snapshot_id"]) as? String)
                    ?? lock.withLock({ latestSnapshotIDs[sessionID] }),
                elementID: (arguments["elementId"] ?? arguments["element_index"]).map {
                    String(describing: $0)
                },
                x: double(arguments["x"]),
                y: double(arguments["y"])
            )
            switch addressing {
            case .semantic:
                guard let target else {
                    throw BridgeError("Unknown or expired element; call get_app_state again")
                }
                if let targetFrame = target.frame {
                    ComputerUsePresentation.moveCursor(
                        sessionID: sessionID,
                        to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                    )
                }
                let accessibilityAction = try performAccessibilityClick(
                    target: target,
                    button: button,
                    clickCount: clickCount,
                    pid: app.processIdentifier
                )
                let path: String
                if accessibilityAction != nil {
                    path = "accessibility"
                } else if let targetFrame = target.frame {
                    let point = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                    let delivery = deliveryTarget(
                        point: point,
                        window: window,
                        windowID: windowID,
                        windowFrame: frame(of: window)
                    )
                    let deliveryMode = try deliveryMode(arguments, windowID: windowID)
                    let performClick = {
                        try self.mouseClick(
                            point,
                            count: clickCount,
                            button: button,
                            pid: app.processIdentifier,
                            windowID: delivery.windowID,
                            windowFrame: delivery.windowFrame,
                            chromium: computerUseUsesChromiumInput(
                                appName: app.localizedName,
                                bundleIdentifier: app.bundleIdentifier,
                                executablePath: app.executableURL?.path
                            )
                        )
                    }
                    path =
                        deliveryMode == "foreground"
                        ? try withAppFronted(
                            app: app,
                            window: window,
                            windowID: windowID,
                            operation: performClick
                        )
                        : try performClick()
                } else {
                    throw BridgeError(
                        "The selected element has no accessibility click action or onscreen frame"
                    )
                }
                if let targetFrame = target.frame {
                    ComputerUsePresentation.moveCursor(
                        sessionID: sessionID,
                        to: CGPoint(x: targetFrame.midX, y: targetFrame.midY),
                        pulse: true
                    )
                }
                var semanticMetadata: [String: Any] = [
                    "kind": "click",
                    "addressing": "element",
                    "path": path,
                    "delivered": true,
                    "verified": false,
                    "effect": "unverifiable",
                    "next": "Confirm the effect in the returned app state. Re-snapshot before another action.",
                ]
                if let accessibilityAction {
                    semanticMetadata["accessibilityAction"] = accessibilityAction
                }
                actionMetadata = semanticMetadata
            case .pixel:
                let point = try screenPoint(
                    window: window,
                    windowID: windowID,
                    target: nil,
                    sessionID: sessionID,
                    arguments: arguments
                )
                let delivery = deliveryTarget(
                    point: point,
                    window: window,
                    windowID: windowID,
                    windowFrame: frame(of: window)
                )
                let deliveryMode = try deliveryMode(arguments, windowID: windowID)
                ComputerUsePresentation.moveCursor(sessionID: sessionID, to: point)
                let performClick = {
                    try self.mouseClick(
                        point,
                        count: clickCount,
                        button: button,
                        pid: app.processIdentifier,
                        windowID: delivery.windowID,
                        windowFrame: delivery.windowFrame,
                        chromium: computerUseUsesChromiumInput(
                            appName: app.localizedName,
                            bundleIdentifier: app.bundleIdentifier,
                            executablePath: app.executableURL?.path
                        )
                    )
                }
                let path: String
                if deliveryMode == "foreground" {
                    path = try withAppFronted(
                        app: app,
                        window: window,
                        windowID: windowID,
                        operation: performClick
                    )
                } else {
                    path = try performClick()
                }
                var pixelMetadata: [String: Any] = [
                    "kind": "click",
                    "addressing": "pixel",
                    "path": path,
                    "deliveryMode": deliveryMode,
                    "delivered": true,
                    "verified": false,
                    "effect": "unverifiable",
                    "screenshotPoint": [
                        "x": double(arguments["x"]) ?? 0,
                        "y": double(arguments["y"]) ?? 0,
                    ],
                    "next":
                        "Confirm the effect in the returned screenshot. If unchanged, re-snapshot and retry once with deliveryMode foreground or use Browser Use for web-page content.",
                ]
                if let windowID { pixelMetadata["windowId"] = Int(windowID) }
                actionMetadata = pixelMetadata
                ComputerUsePresentation.moveCursor(sessionID: sessionID, to: point, pulse: true)
            case .ambiguous:
                throw BridgeError(
                    "Choose one click addressing mode: snapshotId + elementId, or screenshot x + y"
                )
            case .invalid:
                throw BridgeError(
                    "Click requires snapshotId + elementId, or both screenshot x and y coordinates"
                )
            }
        case "drag":
            let start = try dragPoint(
                prefix: "from",
                window: window,
                windowID: windowID,
                sessionID: sessionID,
                arguments: arguments
            )
            let end = try dragPoint(
                prefix: "to",
                window: window,
                windowID: windowID,
                sessionID: sessionID,
                arguments: arguments
            )
            ComputerUsePresentation.moveCursor(sessionID: sessionID, to: start)
            let mode = try deliveryMode(arguments, windowID: windowID)
            let path = try performWithDelivery(
                app: app,
                window: window,
                windowID: windowID,
                mode: mode
            ) {
                try self.drag(
                    from: start,
                    to: end,
                    pid: app.processIdentifier,
                    global: mode == "foreground"
                )
                return mode == "foreground" ? "cgevent_global" : "cgevent_pid"
            }
            ComputerUsePresentation.moveCursor(sessionID: sessionID, to: end, pulse: true)
            actionMetadata = actionResultMetadata(
                kind: "drag",
                path: path,
                deliveryMode: mode
            )
        case "perform_secondary_action":
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            guard let element = target?.element, let action = arguments["action"] as? String,
                axPerformAction(element, action as CFString, pid: app.processIdentifier) == .success
            else { throw BridgeError("That accessibility action is unavailable") }
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY),
                    pulse: true
                )
            }
            actionMetadata = actionResultMetadata(
                kind: "perform_secondary_action",
                path: "accessibility",
                detail: ["accessibilityAction": action]
            )
        case "press_key":
            guard let key = arguments["key"] as? String else { throw BridgeError("key is required") }
            let mode = try deliveryMode(arguments, windowID: windowID)
            let path = try performWithDelivery(
                app: app,
                window: window,
                windowID: windowID,
                mode: mode
            ) {
                try self.keyPress(key, pid: app.processIdentifier, global: mode == "foreground")
                return mode == "foreground" ? "cgevent_global" : "cgevent_pid"
            }
            actionMetadata = actionResultMetadata(
                kind: "press_key",
                path: path,
                deliveryMode: mode,
                detail: ["key": key]
            )
        case "scroll":
            let direction = arguments["direction"] as? String ?? "down"
            let pages = max(1, double(arguments["pages"]) ?? 1)
            let point =
                target?.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? frame(of: window).map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? .zero
            ComputerUsePresentation.moveCursor(sessionID: sessionID, to: point)
            let mode = try deliveryMode(arguments, windowID: windowID)
            let path = try performWithDelivery(
                app: app,
                window: window,
                windowID: windowID,
                mode: mode
            ) {
                try self.scroll(
                    at: point,
                    direction: direction,
                    pages: pages,
                    pid: app.processIdentifier,
                    global: mode == "foreground"
                )
                return mode == "foreground" ? "cgevent_global" : "cgevent_pid"
            }
            actionMetadata = actionResultMetadata(
                kind: "scroll",
                path: path,
                deliveryMode: mode,
                detail: ["direction": direction, "pages": pages]
            )
        case "set_value":
            guard let element = target?.element, let value = arguments["value"] else {
                throw BridgeError("A current element and value are required")
            }
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            guard
                axSetAttribute(
                    element,
                    kAXValueAttribute as CFString,
                    value as CFTypeRef,
                    pid: app.processIdentifier
                ) == .success
            else { throw BridgeError("The element is not settable") }
            let verified =
                copyAttribute(element, kAXValueAttribute).map {
                    String(describing: $0)
                } == String(describing: value)
            actionMetadata = actionResultMetadata(
                kind: "set_value",
                path: "accessibility",
                verified: verified
            )
        case "type_text":
            if let element = target?.element {
                try focus(element: element, application: application, pid: app.processIdentifier)
            }
            guard let text = arguments["text"] as? String else { throw BridgeError("text is required") }
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            let mode = try deliveryMode(arguments, windowID: windowID)
            let path = try performWithDelivery(
                app: app,
                window: window,
                windowID: windowID,
                mode: mode
            ) {
                try self.typeText(text, pid: app.processIdentifier, global: mode == "foreground")
                return mode == "foreground" ? "cgevent_global" : "cgevent_pid"
            }
            actionMetadata = actionResultMetadata(
                kind: "type_text",
                path: path,
                deliveryMode: mode,
                detail: ["utf16Length": text.utf16.count]
            )
        case "select_text":
            guard let element = target?.element else { throw BridgeError("A current element is required") }
            if let targetFrame = target?.frame {
                ComputerUsePresentation.moveCursor(
                    sessionID: sessionID,
                    to: CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                )
            }
            let selectedRange = try textSelectionRange(element: element, arguments: arguments)
            var range = selectedRange
            guard let value = AXValueCreate(.cfRange, &range),
                axSetAttribute(
                    element,
                    kAXSelectedTextRangeAttribute as CFString,
                    value,
                    pid: app.processIdentifier
                ) == .success
            else { throw BridgeError("The element does not support text selection") }
            let actualRange = selectedTextRange(element)
            let verified =
                actualRange?.location == selectedRange.location
                && actualRange?.length == selectedRange.length
            actionMetadata = actionResultMetadata(
                kind: "select_text",
                path: "accessibility",
                verified: verified,
                detail: ["start": selectedRange.location, "length": selectedRange.length]
            )
        default:
            throw BridgeError("Unsupported Computer Use tool: \(tool)")
        }
        Thread.sleep(forTimeInterval: 0.12)
        return try appState(
            sessionID: sessionID,
            agentLabel: agentLabel,
            app: appName,
            action: actionMetadata
        )
    }
}
