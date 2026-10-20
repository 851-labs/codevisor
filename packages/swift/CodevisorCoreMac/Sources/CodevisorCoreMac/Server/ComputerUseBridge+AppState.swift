import AppKit
import ApplicationServices
import Foundation

extension ComputerUseBridge {
  func appState(
    sessionID: String,
    agentLabel: String?,
    app name: String,
    requestedWindowID: CGWindowID? = nil,
    options: [String: Any] = [:],
    budget: ComputerUseReadBudget = .unlimited
  ) throws -> [String: Any] {
    try requireAccessibility(prompt: true)
    let app = try resolveApp(name)
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
      return try windowlessAppState(
        app: app,
        name: name,
        detail: String(describing: error)
      )
    }
    var (window, windowID) = resolved
    ComputerUseSyntheticActivation.shared.hold(app: app, sessionID: sessionID, windowID: windowID)
    settleAfterAction(sessionID: sessionID, pid: app.processIdentifier, budget: budget)
    var followedFrom: CGWindowID?
    if requestedWindowID == nil, options["view"] as? String ?? "auto" == "auto",
      let dialog = elementAttribute(application, kAXFocusedWindowAttribute),
      let dialogID = computerUseWindowID(for: dialog), dialogID != windowID,
      computerUseIsDialogWindow(
        role: stringAttribute(dialog, kAXRoleAttribute), subrole: stringAttribute(dialog, kAXSubroleAttribute),
        modal: copyAttribute(dialog, kAXModalAttribute) as? Bool == true)
    {
      try selectSessionWindow(sessionID: sessionID, application: application, requestedWindowID: dialogID)
      followedFrom = windowID
      (window, windowID) = (dialog, dialogID)
    }
    activatePresentation(
      sessionID: sessionID,
      agentLabel: agentLabel,
      app: app,
      window: window,
      windowID: windowID
    )
    let snapshotID = UUID().uuidString
    let accessibilityWindowFrame = frame(of: window)
    let wantsScreenshot = options["screenshot"] as? Bool ?? true
    let visibility = windowID.map { id in
      ComputerUseWindowVisibility.read(windowID: id, pid: app.processIdentifier) {
        copyAttribute(window, kAXMinimizedAttribute) as? Bool == true
      }
    }
    let appName = app.localizedName ?? name
    let uncapturable = visibility.flatMap { computerUseUncapturableReason($0, appName: appName) }
    let outcome: ScreenshotOutcome =
      if !wantsScreenshot {
        .unavailable("Screenshot not requested.")
      } else if let reason = uncapturable {
        .unavailable(reason)
      } else {
        screenshot(windowID: windowID, fallbackFrame: accessibilityWindowFrame)
      }
    let capture = outcome.capture
    let windowFrame = frame(of: window) ?? accessibilityWindowFrame
    if let capture, let windowFrame, !computerUseFramesMatch(capture.windowFrame, windowFrame) {
      throw BridgeError("The window moved during capture. Call get_app_state again.")
    }
    let scope = computerUseSnapshotScope(sessionID, app.processIdentifier, windowID)
    let previous = lock.withLock { latestSnapshotIDs[scope].flatMap { snapshots[sessionID]?[$0] } }
    var nextIndex = lock.withLock { nextElementIndices[sessionID] ?? 0 }
    let requestedView = options["view"] as? String ?? "auto"
    guard ["auto", "window", "menu", "dialog", "menubar"].contains(requestedView) else {
      throw BridgeError("view must be auto, window, menu, dialog, or menubar")
    }
    let subtreeRoot = try targetElement(
      sessionID: sessionID, pid: app.processIdentifier, windowID: windowID, arguments: options)
    let accessibility = computerUsePerformAccessibilityRead(
      targetPID: app.processIdentifier
    ) {
      let contentIsFlipped =
        windowFrame.map {
          self.windowContentIsFlipped(
            application: application,
            window: window,
            windowID: windowID,
            windowFrame: $0
          )
        } ?? false
      let previousByHash = Dictionary(grouping: previous?.elements ?? [:]) { CFHash($0.value.element) }
      let firstIndex = nextIndex
      let walk = { (roots: (elements: [AXUIElement], view: String)) in
        nextIndex = firstIndex
        var records: [String: ElementRecord] = [:]
        var lines: [String] = []
        var limits = ComputerUseSnapshotLimits(budget: budget)
        var redundant: [Int: String] = [:]
        let buttons = self.dialogButtons(
          of: roots.elements + (roots.view == "window" ? self.sheetElements(of: window) : []))
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
            includeClosedMenus: roots.view == "menubar", dialogButtons: buttons,
            previous: previousByHash, nextIndex: &nextIndex, limits: &limits,
            records: &records, lines: &lines, redundant: &redundant
          )
        }
        return (records: records, lines: lines.filter { !$0.isEmpty }, limits: limits)
      }
      var roots =
        subtreeRoot.map { (elements: [$0.element], view: "element") }
        ?? self.observationRoots(
          application: application, window: window, view: requestedView,
          searchWindowForMenus: requestedView != "auto")
      var (records, lines, limits) = walk(roots)
      if requestedView == "auto", subtreeRoot == nil, roots.view != "menu", let menu = limits.openMenu {
        roots = (elements: [menu], view: "menu")
        (records, lines, limits) = walk(roots)
      }
      var waitedForLoading = false
      while limits.sawBusyIndicator {
        let wait = min(
          computerUseLoadingWindow(
            sinceAction: self.secondsSinceAction(sessionID: sessionID, pid: app.processIdentifier)),
          budget.deadline.map { max(0, $0 - ProcessInfo.processInfo.systemUptime - 1) } ?? .infinity, 1)
        guard wait > 0 else { break }
        self.awaitQuiet(pid: app.processIdentifier, quietPeriod: 0.25, maxWait: wait)
        waitedForLoading = true
        (records, lines, limits) = walk(roots)
      }
      if let note = limits.truncationNote { lines.append(note) }
      if waitedForLoading, limits.sawBusyIndicator {
        lines.append("A loading indicator is still showing; observe again or use waitFor before relying on this view.")
      }
      if let focused = elementAttribute(application, kAXFocusedUIElementAttribute),
        stringAttribute(focused, kAXRoleAttribute) != kAXWindowRole as String,
        let id = records.first(where: { CFEqual($0.value.element, focused) })?.key,
        let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(id) ") })
      {
        lines.append("Focused element: \(line.trimmingCharacters(in: .whitespaces))")
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
    storeSnapshot(
      sessionID: sessionID, scope: scope, snapshotID: snapshotID, nextIndex: nextIndex,
      record: SnapshotRecord(
        elements: computerUseCarriedRecords(previous?.elements ?? [:]).merging(accessibility.records) { $1 },
        pid: app.processIdentifier,
        windowID: windowID,
        windowFrame: windowFrame,
        screenshotPixelSize: capture?.pixelSize,
        createdAt: DispatchTime.now().uptimeNanoseconds,
        text: subtreeRoot == nil ? accessibility.text : previous?.text ?? "",
        view: subtreeRoot == nil ? accessibility.view : previous?.view ?? accessibility.view
      ))
    let screenshotMetadata: [String: Any] =
      if capture == nil {
        ["available": false, "reason": outcome.reason ?? "No screenshot was produced."]
      } else {
        ["available": true]
      }
    let diff = options["disableDiff"] as? Bool != true && previous?.view == accessibility.view
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
    if accessibility.contentIsFlipped {
      metadata["frameOrientationCorrected"] = true
    }
    if let followedFrom {
      metadata["followedDialogFrom"] = Int(followedFrom)
      metadata["next"] =
        "A dialog opened in its own window, so this observation shows it; click its elements directly. The window it came from is windowId \(followedFrom)."
    }
    if accessibility.hasModalSheet {
      metadata["modalSheetPresent"] = true
      metadata["next"] = "A modal dialog is open; dismiss or complete it before using other controls."
    }
    let windows = accessibility.windows
    metadata["windows"] = windows
    if windows.count > 1, accessibility.view != "dialog",
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
    }
    if let visibility {
      metadata["windowVisibility"] = visibility.rawValue
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

  func secondsSinceAction(sessionID: String, pid: pid_t) -> TimeInterval? {
    let now = ProcessInfo.processInfo.systemUptime
    return lock.withLock { lastActionUptimes[computerUseAppScope(sessionID, pid)] }.map { now - $0 }
  }

  func settleAfterAction(sessionID: String, pid: pid_t, budget: ComputerUseReadBudget) {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = secondsSinceAction(sessionID: sessionID, pid: pid)
    let remaining = budget.deadline.map { max(0, $0 - now - 1) } ?? .infinity
    let wait = min(computerUseSettleWindow(sinceAction: elapsed), remaining)
    if wait > 0 { awaitQuiet(pid: pid, maxWait: wait) }
  }

  func storeSnapshot(
    sessionID: String, scope: String, snapshotID: String, nextIndex: Int, record: SnapshotRecord
  ) {
    lock.withLock {
      var session = snapshots[sessionID] ?? [:]
      session[snapshotID] = record
      if session.count > 8,
        let oldest = session.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
      {
        session.removeValue(forKey: oldest)
      }
      snapshots[sessionID] = session
      latestSnapshotIDs[scope] = snapshotID
      nextElementIndices[sessionID] = nextIndex
    }
  }

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
