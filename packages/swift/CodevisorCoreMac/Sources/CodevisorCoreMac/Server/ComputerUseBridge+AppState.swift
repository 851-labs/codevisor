import AppKit
import ApplicationServices
import Foundation

extension ComputerUseBridge {
  func appState(
    sessionID: String,
    agentLabel: String?,
    app name: String,
    requestedWindowID: CGWindowID? = nil,
    options: [String: Any] = [:]
  ) throws -> [String: Any] {
    try requireAccessibility(prompt: true)
    let app = try resolveApp(name)
    // Observing is the deliberate act that resumes an interrupted share.
    try ComputerUsePresentation.requireControlAllowed(
      sessionID: sessionID,
      pid: app.processIdentifier,
      resuming: true
    )
    let application = AXUIElementCreateApplication(app.processIdentifier)
    if let requestedWindowID {
      try selectSessionWindow(
        sessionID: sessionID,
        application: application,
        requestedWindowID: requestedWindowID
      )
    }
    let resolved: (element: AXUIElement, windowID: CGWindowID?)
    do {
      resolved = try sessionWindow(
        sessionID: sessionID,
        application: application,
        pid: app.processIdentifier,
        waitForLaunch: app.launchDate.map { Date().timeIntervalSince($0) < 15 } ?? false
      )
    } catch let error as ComputerUseNoWindow {
      // A running app with every window closed (or on a Space that will
      // not come forward) has nothing to snapshot, but it is still
      // driveable: ⌘N is exactly how a person reopens a window. Report
      // that state instead of failing the call outright.
      return try windowlessAppState(
        app: app,
        name: name,
        detail: String(describing: error)
      )
    }
    let (window, windowID) = resolved
    activatePresentation(
      sessionID: sessionID,
      agentLabel: agentLabel,
      app: app,
      window: window,
      windowID: windowID
    )
    let snapshotID = UUID().uuidString
    let accessibilityWindowFrame = frame(of: window)
    // Never fronts the app: ScreenCaptureKit composites a window on
    // another Space perfectly well, so looking at an app must not steal
    // the user's focus or drag them between desktops.
    let wantsScreenshot = options["screenshot"] as? Bool ?? true
    let outcome: ScreenshotOutcome =
      wantsScreenshot
      ? screenshot(windowID: windowID, fallbackFrame: accessibilityWindowFrame)
      : .unavailable("Screenshot not requested.")
    let capture = outcome.capture
    // Never combine pixels from one window position with AX frames from another.
    let windowFrame = frame(of: window) ?? accessibilityWindowFrame
    if let capture, let windowFrame, !computerUseFramesMatch(capture.windowFrame, windowFrame) {
      throw BridgeError("The window moved during capture. Call get_app_state again.")
    }
    let scope = computerUseSnapshotScope(sessionID, app.processIdentifier, windowID)
    let previous = lock.withLock { latestSnapshotIDs[scope].flatMap { snapshots[sessionID]?[$0] } }
    var nextIndex = lock.withLock { nextElementIndices[sessionID] ?? 0 }
    let requestedView = options["view"] as? String ?? "auto"
    guard ["auto", "window", "menu", "dialog"].contains(requestedView) else {
      throw BridgeError("view must be auto, window, menu, or dialog")
    }
    // For another app these calls are IPC and remain on this worker. For
    // Codevisor itself they synchronously enter AppKit/SwiftUI, so read the
    // complete tree in one main-thread hop. Screenshot capture above stays
    // off main because it waits on asynchronous ScreenCaptureKit work.
    let accessibility = computerUsePerformAccessibilityRead(
      targetPID: app.processIdentifier
    ) {
      var records: [String: ElementRecord] = [:]
      var lines: [String] = []
      // An app that publishes its content upside down would otherwise
      // send every coordinate — tree frames, the cursor, pointer events
      // — to the mirror image of the control that was named.
      let contentIsFlipped =
        windowFrame.map {
          self.windowContentIsFlipped(
            application: application,
            window: window,
            windowID: windowID,
            windowFrame: $0
          )
        } ?? false
      let roots = self.observationRoots(application: application, window: window, view: requestedView)
      let previousByHash = Dictionary(grouping: previous?.elements ?? [:]) { CFHash($0.value.element) }
      var remaining = 2_000
      for root in roots.elements {
        self.snapshotTree(
          root, depth: 0,
          screenshotWindowFrame: (options["include_frames"] as? Bool ?? wantsScreenshot) ? windowFrame : nil,
          screenshotPixelSize: capture?.pixelSize,
          correctFrame: { element, reported in
            guard contentIsFlipped, let windowFrame else { return reported }
            return self.correctedFrame(
              of: element, reported: reported, application: application, windowFrame: windowFrame)
          },
          previous: previousByHash, nextIndex: &nextIndex, remaining: &remaining,
          records: &records, lines: &lines
        )
      }
      if remaining == 0 || records.count >= 1_200 {
        lines.append("Observation truncated; inspect a menu/dialog or scroll to the relevant controls.")
      }
      if roots.elements.isEmpty { lines.append("No open \(requestedView).") }
      return ComputerUseAppAccessibilityState(
        records: records,
        text: lines.joined(separator: "\n"),
        contentIsFlipped: contentIsFlipped,
        hasModalSheet: !self.sheetElements(of: window).isEmpty,
        windows: self.windowInventory(application: application, pinnedWindowID: windowID),
        windowTitle: stringAttribute(window, kAXTitleAttribute),
        view: roots.view
      )
    }
    lock.withLock {
      var session = snapshots[sessionID] ?? [:]
      session[snapshotID] = SnapshotRecord(
        elements: accessibility.records,
        pid: app.processIdentifier,
        windowID: windowID,
        windowFrame: windowFrame,
        screenshotPixelSize: capture?.pixelSize,
        createdAt: DispatchTime.now().uptimeNanoseconds,
        text: accessibility.text,
        view: accessibility.view
      )
      if session.count > 8,
        let oldest = session.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
      {
        session.removeValue(forKey: oldest)
      }
      snapshots[sessionID] = session
      latestSnapshotIDs[scope] = snapshotID
      nextElementIndices[sessionID] = nextIndex
    }
    let screenshotMetadata: [String: Any] =
      if capture == nil {
        ["available": false, "reason": outcome.reason ?? "No screenshot was produced."]
      } else {
        ["available": true]
      }
    let diff = options["disableDiff"] as? Bool == false && previous?.view == accessibility.view
    let rendered = computerUseObservationText(current: accessibility.text, previous: diff ? previous?.text : nil)
    var metadata: [String: Any] = [
      "snapshotId": snapshotID,
      "app": name,
      "resolvedApp": [
        "id": app.bundleIdentifier ?? app.bundleURL?.path ?? name,
        "name": app.localizedName ?? name,
        "path": app.bundleURL?.path ?? "",
        "pid": app.processIdentifier,
        "isRunning": true,
      ],
      "text": rendered,
      "isDiff": diff,
      "view": accessibility.view,
      "coordinateSpace": capture == nil ? "windowPoints" : "screenshotPixels",
      "screenshot": screenshotMetadata,
    ]
    // A modal sheet blocks every other control in the window, so say so
    // rather than leaving the model to infer it from the tree.
    if accessibility.contentIsFlipped {
      // Say so: the coordinates here will not match the app's own
      // accessibility inspector output.
      metadata["frameOrientationCorrected"] = true
    }
    if accessibility.hasModalSheet {
      metadata["modalSheetPresent"] = true
      metadata["next"] = "A modal dialog is open; dismiss or complete it before using other controls."
    }
    // The session follows one window. Publishing the rest is what makes an
    // action that opened a new window (⌘N) visible instead of looking like
    // it did nothing; windowId here can be passed back as window_id.
    let windows = accessibility.windows
    metadata["windows"] = windows
    if windows.count > 1,
      let focused = windows.first(where: { $0["isFocused"] as? Bool == true }),
      focused["isSessionWindow"] as? Bool != true,
      let focusedID = focused["windowId"]
    {
      metadata["focusedWindowId"] = focusedID
      metadata["next"] =
        "This app's focused window is not the one being inspected. Pass window_id \(focusedID) to switch to it."
    }
    if let windowID {
      metadata["windowId"] = Int(windowID)
      metadata["isOnActiveSpace"] = windowIsOnVisibleSpace(windowID)
    }
    if let title = accessibility.windowTitle { metadata["windowTitle"] = title }
    if let windowFrame { metadata["screenWindowBounds"] = frameObject(windowFrame) }
    if let pixelSize = capture?.pixelSize {
      metadata["screenshotSize"] = [
        "width": pixelSize.width,
        "height": pixelSize.height,
      ]
      metadata["windowBounds"] = [
        "x": 0,
        "y": 0,
        "width": pixelSize.width,
        "height": pixelSize.height,
      ]
      // windowBounds/screenshotSize are pixels while screenWindowBounds
      // is display points; publish the ratio so consumers can convert.
      if let windowFrame, windowFrame.width > 0 {
        metadata["scaleFactor"] = Double(pixelSize.width / windowFrame.width)
      }
    }
    var content: [[String: Any]] = [["type": "text", "text": try json(metadata)]]
    if let capture {
      content.append([
        "type": "image",
        "mimeType": "image/png",
        "data": capture.data.base64EncodedString(),
      ])
    }
    return ["content": content]
  }

  /// State for a running app that currently exposes no window. Keyboard
  /// tools still work (they address the process), so this is a recoverable
  /// state rather than an error.
  private func windowlessAppState(
    app: NSRunningApplication,
    name: String,
    detail: String
  ) throws -> [String: Any] {
    let metadata: [String: Any] = [
      "app": name,
      "resolvedApp": [
        "id": app.bundleIdentifier ?? app.bundleURL?.path ?? name,
        "name": app.localizedName ?? name,
        "path": app.bundleURL?.path ?? "",
        "pid": app.processIdentifier,
        "isRunning": true,
      ],
      "text": "",
      "windows": [],
      "screenshot": [
        "available": false,
        "reason": "This app has no open window to capture. \(detail)",
      ],
      "next":
        "The app is running with no window. Press a key such as cmd+n to open one, then call get_app_state again.",
    ]
    return ["content": [["type": "text", "text": try json(metadata)]]]
  }

}

private struct ComputerUseAppAccessibilityState {
  let records: [String: ComputerUseBridge.ElementRecord]
  let text: String
  let contentIsFlipped: Bool
  let hasModalSheet: Bool
  let windows: [[String: Any]]
  let windowTitle: String?
  let view: String
}
