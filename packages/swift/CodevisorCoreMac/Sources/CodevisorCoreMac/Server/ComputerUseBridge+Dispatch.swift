import AppKit
import ApplicationServices
import Foundation

extension ComputerUseBridge {
    func handle(_ message: [String: Any]) throws -> [String: Any] {
        let type = message["type"] as? String
        let sessionID = message["sessionId"] as? String ?? ""
        let agentLabel = message["agentLabel"] as? String
        if type == "closeSession" {
            _ = lock.withLock { snapshots.removeValue(forKey: sessionID) }
            _ = lock.withLock { latestSnapshotIDs.removeValue(forKey: sessionID) }
            _ = lock.withLock { windowIDBySession.removeValue(forKey: sessionID) }
            ComputerUsePresentation.end(sessionID: sessionID)
            return textResult("closed")
        }
        guard type == "tool", let tool = message["tool"] as? String else {
            throw BridgeError("Unsupported helper request")
        }
        let arguments = message["arguments"] as? [String: Any] ?? [:]
        if tool == "list_apps" { return try listApps() }
        guard let appName = arguments["app"] as? String else {
            throw BridgeError("app is required")
        }
        let requestedWindowID = (arguments["windowId"] ?? arguments["window_id"])
            .flatMap { int($0) }
            .map { CGWindowID($0) }
        if tool == "get_app_state" {
            return try appState(
                sessionID: sessionID,
                agentLabel: agentLabel,
                app: appName,
                requestedWindowID: requestedWindowID
            )
        }
        try requireAccessibility(prompt: true)
        let app = try resolveApp(appName)
        try ComputerUsePresentation.requireControlAllowed(
            sessionID: sessionID,
            pid: app.processIdentifier
        )
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if let requestedWindowID {
            try selectSessionWindow(
                sessionID: sessionID,
                application: application,
                requestedWindowID: requestedWindowID
            )
        }
        // Keyboard input addresses the process, so it stays available when the
        // app has no window — which is the only way to reopen one (⌘N).
        let addressesProcess = tool == "press_key" || tool == "type_text"
        let resolvedWindow: (element: AXUIElement, windowID: CGWindowID?)?
        do {
            resolvedWindow = try sessionWindow(
                sessionID: sessionID,
                application: application,
                pid: app.processIdentifier
            )
        } catch {
            guard addressesProcess else { throw error }
            resolvedWindow = nil
        }
        if let resolvedWindow {
            return try handleWindowedTool(
                tool: tool,
                arguments: arguments,
                sessionID: sessionID,
                agentLabel: agentLabel,
                appName: appName,
                app: app,
                application: application,
                window: resolvedWindow.element,
                windowID: resolvedWindow.windowID
            )
        }
        return try handleWindowlessKeyboardTool(
            tool: tool,
            arguments: arguments,
            sessionID: sessionID,
            agentLabel: agentLabel,
            appName: appName,
            app: app
        )
    }

    /// Keyboard-only path for an app with no window: activate it so the keys
    /// land, post them to the process, then report the (still windowless or
    /// now recovered) state.
    private func handleWindowlessKeyboardTool(
        tool: String,
        arguments: [String: Any],
        sessionID: String,
        agentLabel: String?,
        appName: String,
        app: NSRunningApplication
    ) throws -> [String: Any] {
        _ = app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.2)
        switch tool {
        case "press_key":
            guard let key = arguments["key"] as? String else { throw BridgeError("key is required") }
            try keyPress(key, pid: app.processIdentifier, global: true)
        case "type_text":
            guard let text = arguments["text"] as? String else { throw BridgeError("text is required") }
            try typeText(text, pid: app.processIdentifier, global: true)
        default:
            throw BridgeError("The app has no accessible window")
        }
        Thread.sleep(forTimeInterval: 0.4)
        return try appState(
            sessionID: sessionID,
            agentLabel: agentLabel,
            app: appName,
            action: actionResultMetadata(
                kind: tool,
                path: "cgevent_global_windowless",
                deliveryMode: "foreground"
            )
        )
    }
}
