import AppKit
import ApplicationServices
import CodevisorCore
import Foundation

struct ComputerUseNoWindow: Error, CustomStringConvertible {
  var description: String { "The app has no accessible window" }
}

struct ComputerUseWindowReadError: Error, CustomStringConvertible {
  let code: AXError
  var description: String {
    let detail =
      code == .cannotComplete
      ? "The app did not respond. Observe again when it is ready."
      : "Check Accessibility access and observe again."
    return "Could not read the app's windows (AXError \(code.rawValue)). \(detail)"
  }
}

func computerUseReadReadyWindow<T>(
  timeout: TimeInterval,
  retryDelay: TimeInterval = 0.1,
  now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
  sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
  read: () throws -> T
) throws -> T {
  let deadline = now() + timeout
  while true {
    do {
      return try read()
    } catch {
      let isStarting =
        error is ComputerUseNoWindow
        || (error as? ComputerUseWindowReadError)?.code == .cannotComplete
      let remaining = deadline - now()
      guard isStarting, remaining > 0 else { throw error }
      sleep(min(retryDelay, remaining))
    }
  }
}

@_silgen_name("_AXUIElementGetWindow")
private func AXUIElementGetWindowID(
  _ element: AXUIElement,
  _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

func computerUseWindowID(for element: AXUIElement) -> CGWindowID? {
  var pid: pid_t = 0
  let targetPID = AXUIElementGetPid(element, &pid) == .success ? pid : nil
  return computerUsePerformAccessibilityRead(targetPID: targetPID) {
    var windowID: CGWindowID = 0
    guard AXUIElementGetWindowID(element, &windowID) == .success, windowID != 0 else {
      return nil
    }
    return windowID
  }
}

func computerUseWindowIsOnVisibleSpace(
  _ windowID: CGWindowID,
  windowInfo: [[String: Any]]
) -> Bool {
  windowInfo.contains { info in
    (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
  }
}

func computerUseIsDialogWindow(role: String?, subrole: String?, modal: Bool) -> Bool {
  role == "AXSheet" || modal || ["AXDialog", "AXSystemDialog"].contains(subrole ?? "")
}

extension ComputerUseBridge {
  private func mainWindow(_ application: AXUIElement) throws -> AXUIElement {
    AXUIElementSetMessagingTimeout(application, 1)
    let candidates =
      [
        elementAttribute(application, kAXFocusedWindowAttribute),
        elementAttribute(application, kAXMainWindowAttribute),
      ].compactMap { $0 } + elementsAttribute(application, kAXWindowsAttribute)
    if let window = candidates.first(where: { candidate in
      stringAttribute(candidate, kAXRoleAttribute) == (kAXWindowRole as String)
    }) {
      return window
    }
    var value: CFTypeRef?
    AXUIElementSetMessagingTimeout(application, 1)
    let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
    guard [.success, .noValue, .attributeUnsupported].contains(error) else {
      throw ComputerUseWindowReadError(code: error)
    }
    throw ComputerUseNoWindow()
  }

  func accessibleWindows(_ application: AXUIElement) -> [AXUIElement] {
    var seen = Set<CGWindowID>()
    return
      (elementsAttribute(application, kAXWindowsAttribute)
      + [
        elementAttribute(application, kAXFocusedWindowAttribute),
        elementAttribute(application, kAXMainWindowAttribute),
      ].compactMap { $0 })
      .filter { window in computerUseWindowID(for: window).map { seen.insert($0).inserted } ?? true }
  }

  func selectSessionWindow(
    sessionID: String,
    application: AXUIElement,
    requestedWindowID: CGWindowID
  ) throws {
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    guard accessibleWindows(application).contains(where: { computerUseWindowID(for: $0) == requestedWindowID })
    else {
      throw BridgeError(
        "That window does not belong to this app. Use a windowId from the app state's windows list."
      )
    }
    lock.withLock { windowIDBySession[computerUseAppScope(sessionID, pid)] = requestedWindowID }
  }

  func sessionWindow(
    sessionID: String,
    application: AXUIElement,
    pid: pid_t,
    waitForLaunch: Bool = false
  ) throws -> (element: AXUIElement, windowID: CGWindowID?) {
    return try computerUseReadReadyWindow(timeout: waitForLaunch ? 5 : 0) {
      try availableSessionWindow(
        sessionID: sessionID,
        application: application,
        pid: pid
      )
    }
  }

  private func availableSessionWindow(
    sessionID: String,
    application: AXUIElement,
    pid: pid_t
  ) throws -> (element: AXUIElement, windowID: CGWindowID?) {
    let scope = computerUseAppScope(sessionID, pid)
    let pinnedID = lock.withLock { windowIDBySession[scope] }
    if let pinnedID {
      if let pinned = accessibleWindows(application).first(where: { computerUseWindowID(for: $0) == pinnedID }) {
        return (pinned, pinnedID)
      }
    }

    let window = try mainWindow(application)
    let windowID =
      computerUseWindowID(for: window)
      ?? frame(of: window).flatMap { matchingWindowID(pid: pid, frame: $0) }
    lock.withLock {
      if let windowID {
        windowIDBySession[scope] = windowID
      } else {
        windowIDBySession.removeValue(forKey: scope)
      }
    }
    return (window, windowID)
  }

  private func elementAtPosition(
    application: AXUIElement,
    point: CGPoint
  ) -> AXUIElement? {
    var pid: pid_t = 0
    let targetPID = AXUIElementGetPid(application, &pid) == .success ? pid : nil
    return computerUsePerformAccessibilityRead(targetPID: targetPID) {
      var hit: AXUIElement?
      guard
        AXUIElementCopyElementAtPosition(
          application,
          Float(point.x),
          Float(point.y),
          &hit
        ) == .success
      else { return nil }
      return hit
    }
  }

  private func leafElements(
    of element: AXUIElement,
    limit: Int,
    depth: Int = 0,
    found: inout [AXUIElement]
  ) {
    guard found.count < limit, depth <= 8 else { return }
    let children = elementsAttribute(element, kAXChildrenAttribute)
    guard !children.isEmpty else {
      if let box = frame(of: element), box.width > 8, box.height > 8 {
        found.append(element)
      }
      return
    }
    for child in children {
      leafElements(of: child, limit: limit, depth: depth + 1, found: &found)
    }
  }

  func windowContentIsFlipped(
    application: AXUIElement,
    window: AXUIElement,
    windowID: CGWindowID?,
    windowFrame: CGRect
  ) -> Bool {
    if let windowID, let cached = lock.withLock({ flippedContentWindows[windowID] }) {
      return cached
    }
    var samples: [AXUIElement] = []
    leafElements(of: window, limit: 12, found: &samples)
    var direct = 0
    var mirrored = 0
    for sample in samples {
      guard let box = frame(of: sample) else { continue }
      if let hit = elementAtPosition(
        application: application,
        point: CGPoint(x: box.midX, y: box.midY)
      ), CFEqual(hit, sample) {
        direct += 1
        continue
      }
      let mirroredBox = computerUseMirroredFrame(box, in: windowFrame)
      if let hit = elementAtPosition(
        application: application,
        point: CGPoint(x: mirroredBox.midX, y: mirroredBox.midY)
      ), CFEqual(hit, sample) {
        mirrored += 1
      }
    }
    let flipped = computerUseFramesAreFlipped(
      directHits: direct,
      mirroredHits: mirrored,
      samples: samples.count
    )
    if flipped {
      Log.computerUse.log(
        "Window \(windowID.map(String.init) ?? "?", privacy: .public) publishes flipped element frames (\(mirrored, privacy: .public)/\(samples.count, privacy: .public) samples); correcting"
      )
    }
    if let windowID { lock.withLock { flippedContentWindows[windowID] = flipped } }
    return flipped
  }

  func correctedFrame(
    of element: AXUIElement,
    reported: CGRect,
    application: AXUIElement,
    windowFrame: CGRect
  ) -> CGRect {
    if let hit = elementAtPosition(
      application: application,
      point: CGPoint(x: reported.midX, y: reported.midY)
    ), CFEqual(hit, element) {
      return reported
    }
    let mirrored = computerUseMirroredFrame(reported, in: windowFrame)
    if let hit = elementAtPosition(
      application: application,
      point: CGPoint(x: mirrored.midX, y: mirrored.midY)
    ), CFEqual(hit, element) {
      return mirrored
    }
    return reported
  }

  func windowInventory(
    application: AXUIElement,
    pinnedWindowID: CGWindowID?
  ) -> [[String: Any]] {
    let focusedID = elementAttribute(application, kAXFocusedWindowAttribute)
      .flatMap { computerUseWindowID(for: $0) }
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    return accessibleWindows(application).compactMap { candidate in
      guard let id = computerUseWindowID(for: candidate) else { return nil }
      let isMinimized = copyAttribute(candidate, kAXMinimizedAttribute) as? Bool == true
      var entry: [String: Any] = [
        "windowId": Int(id),
        "isSessionWindow": id == pinnedWindowID,
        "isFocused": id == focusedID,
        "hasModalSheet": !sheetElements(of: candidate).isEmpty,
        "visibility": ComputerUseWindowVisibility.read(windowID: id, pid: pid) { isMinimized }.rawValue,
        "isMinimized": isMinimized,
      ]
      if let title = stringAttribute(candidate, kAXTitleAttribute), !title.isEmpty {
        entry["title"] = title
      }
      if let frame = frame(of: candidate) { entry["screenBounds"] = frameObject(frame) }
      return entry
    }
  }

  func windowAction(
    _ action: String, window: AXUIElement, application: AXUIElement, pid: pid_t
  ) throws -> [String: Any] {
    switch action {
    case "raise":
      let error = axPerformAction(window, kAXRaiseAction as CFString, pid: pid)
      if isSettable(window, attribute: kAXMainAttribute) {
        _ = axSetAttribute(window, kAXMainAttribute as CFString, kCFBooleanTrue, pid: pid)
      }
      return try accessibilityMutationResult(
        error: error, kind: "window_action", verified: copyAttribute(window, kAXMainAttribute) as? Bool == true,
        detail: ["action": action])
    case "minimize", "restore":
      let minimized = action == "minimize"
      let error = axSetAttribute(
        window, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse, pid: pid)
      let verified = computerUseSettles { copyAttribute(window, kAXMinimizedAttribute) as? Bool == minimized }
      return try accessibilityMutationResult(
        error: error, kind: "window_action", verified: verified, detail: ["action": action])
    case "close":
      guard let button = elementAttribute(window, kAXCloseButtonAttribute),
        actionNames(of: button).contains(kAXPressAction as String)
      else { throw BridgeError("This window has no close button.") }
      let error = axPerformAction(button, kAXPressAction as CFString, pid: pid)
      let closed = computerUseSettles {
        !elementsAttribute(application, kAXWindowsAttribute).contains { CFEqual($0, window) }
      }
      var result = try accessibilityMutationResult(
        error: error, kind: "window_action", verified: closed, detail: ["action": action])
      if !closed {
        result["next"] = "The window is still open. Observe it; the app may be asking whether to save."
      }
      return result
    default:
      throw BridgeError("action must be raise, minimize, restore, or close")
    }
  }

  func sheetElements(of window: AXUIElement) -> [AXUIElement] {
    let declared = elementsAttribute(window, "AXSheets")
    if !declared.isEmpty { return declared }
    return elementsAttribute(window, kAXChildrenAttribute).filter {
      stringAttribute($0, kAXRoleAttribute) == "AXSheet"
    }
  }

  func deliveryTarget(
    point: CGPoint,
    window: AXUIElement,
    windowID: CGWindowID?,
    windowFrame: CGRect?
  ) -> (windowID: CGWindowID?, windowFrame: CGRect?) {
    for sheet in sheetElements(of: window) {
      guard let sheetFrame = frame(of: sheet), sheetFrame.contains(point) else { continue }
      return (computerUseWindowID(for: sheet) ?? windowID, sheetFrame)
    }
    return (windowID, windowFrame)
  }

  private func matchingWindowID(pid: pid_t, frame: CGRect) -> CGWindowID? {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.excludeDesktopElements],
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
    .max(by: { $0.overlap < $1.overlap })?.id
  }

  func windowIsOnVisibleSpace(_ windowID: CGWindowID) -> Bool {
    let info =
      CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]] ?? []
    return computerUseWindowIsOnVisibleSpace(windowID, windowInfo: info)
  }
}

func computerUseSettles(
  attempts: Int = 10, interval: TimeInterval = 0.1,
  sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, _ condition: () -> Bool
) -> Bool {
  for attempt in 0..<attempts {
    if condition() { return true }
    if attempt < attempts - 1 { sleep(interval) }
  }
  return false
}
