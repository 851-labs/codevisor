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
      lock.withLock {
        latestSnapshotIDs = latestSnapshotIDs.filter { !$0.key.hasPrefix(sessionID + ":app:") }
        windowIDBySession = windowIDBySession.filter { !$0.key.hasPrefix(sessionID + ":app:") }
        nextElementIndices.removeValue(forKey: sessionID)
      }
      ComputerUsePresentation.end(sessionID: sessionID)
      recordings.end(sessionID: sessionID)
      return textResult("closed")
    }
    guard type == "tool", let tool = message["tool"] as? String else {
      throw BridgeError("Unsupported helper request")
    }
    let arguments = message["arguments"] as? [String: Any] ?? [:]
    if tool == "list_apps" { return try listApps() }
    switch tool {
    case "list_recording_targets": return textResult(try json(recordings.targets()))
    case "start_recording":
      return textResult(try json(recordings.start(sessionID: sessionID, agentLabel: agentLabel, arguments: arguments)))
    case "recording_status":
      return textResult(try json(recordings.status(sessionID: sessionID, id: arguments["recording_id"] as? String)))
    case "stop_recording":
      guard let id = arguments["recording_id"] as? String else { throw BridgeError("recording_id is required") }
      return textResult(try json(recordings.stop(sessionID: sessionID, id: id)))
    default: break
    }
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
        requestedWindowID: requestedWindowID,
        options: arguments
      )
    }
    try requireAccessibility(prompt: true)
    let app = try resolveApp(appName, launchIfNeeded: false)
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
    } catch let error as ComputerUseNoWindow {
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

  /// Keyboard input can reopen a window and respects the requested focus mode.
  private func handleWindowlessKeyboardTool(
    tool: String,
    arguments: [String: Any],
    sessionID: String,
    agentLabel: String?,
    appName: String,
    app: NSRunningApplication
  ) throws -> [String: Any] {
    let mode = try deliveryMode(arguments, windowID: nil)
    if mode == "foreground" {
      _ = app.activate(options: [.activateAllWindows])
      for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
        Thread.sleep(forTimeInterval: 0.05)
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
        throw BridgeError("Unable to bring the app forward for keyboard input")
      }
    }
    switch tool {
    case "press_key":
      let keys = (arguments["keys"] as? [String]) ?? (arguments["key"] as? String).map { [$0] } ?? []
      guard !keys.isEmpty, keys.count <= 32, arguments["keys"] == nil || arguments["key"] == nil else {
        throw BridgeError("Supply key or a sequence of 1–32 keys.")
      }
      for key in keys { try validateKey(key) }
      for key in keys { try keyPress(key, pid: app.processIdentifier, global: mode == "foreground") }
    case "type_text":
      guard let text = arguments["text"] as? String else { throw BridgeError("text is required") }
      try typeText(text, pid: app.processIdentifier, global: mode == "foreground")
    default:
      throw BridgeError("The app has no accessible window")
    }
    return textResult(
      try json(
        actionResultMetadata(
          kind: tool, path: mode == "foreground" ? "cgevent_global" : "cgevent_pid", deliveryMode: mode
        )))
  }
}
