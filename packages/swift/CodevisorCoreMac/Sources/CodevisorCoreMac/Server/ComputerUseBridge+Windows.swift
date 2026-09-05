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
  read: () throws -> T
) throws -> T {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  while true {
    do {
      return try read()
    } catch {
      let isStarting =
        error is ComputerUseNoWindow
        || (error as? ComputerUseWindowReadError)?.code == .cannotComplete
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard isStarting, remaining > 0 else { throw error }
      Thread.sleep(forTimeInterval: min(retryDelay, remaining))
    }
  }
}

// Stable AX-window to WindowServer identity. This SPI has remained available
// since macOS 10.9 and lets us avoid guessing by frame, which is especially
// important when the window lives on another Space. The same bridge is used by
// CUA's macOS driver (trycua/cua, b8a0f32a0).
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

  /// Keep a session attached to one composited window even if another Space
  /// changes the app's focused/main window. If that window closes, fall back
  /// to the app's current main window and establish a new identity.
  /// Re-pins the session to a caller-chosen window from the inventory, so a
  /// multi-window app can actually be navigated.
  func selectSessionWindow(
    sessionID: String,
    application: AXUIElement,
    requestedWindowID: CGWindowID
  ) throws {
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    guard
      elementsAttribute(application, kAXWindowsAttribute).contains(where: {
        computerUseWindowID(for: $0) == requestedWindowID
      })
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
    // A successful LaunchServices completion only means the process is
    // running. Allow normal app startup to expose its first window.
    // Windows on another Space are still published, so this never needs to
    // activate the app to find them.
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
      // AXWindows comes back empty while the app's windows are on
      // another Space, which would silently drop the pin and re-resolve
      // to whatever is focused. The focused/main windows still resolve
      // then, so search those too.
      let candidates =
        elementsAttribute(application, kAXWindowsAttribute)
        + [
          elementAttribute(application, kAXFocusedWindowAttribute),
          elementAttribute(application, kAXMainWindowAttribute),
        ].compactMap { $0 }
      if let pinned = candidates.first(where: { computerUseWindowID(for: $0) == pinnedID }) {
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

  /// Modal sheets attached to a window. Apps are inconsistent about the
  /// `AXSheets` attribute — Chess leaves it empty and exposes the sheet as
  /// a plain child — so fall back to a role scan of the children.
  /// The element the system reports at a screen point, which is the only
  /// authority on where a control really is.
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

  /// Whether this window publishes upside-down content, established once per
  /// window by hit-testing a sample of its controls. Chess is the case in
  /// the wild: its SceneKit board reports view-space coordinates, so every
  /// piece resolves to its mirror image.
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

  /// Corrects one element's frame in a flipped window. Per element, because
  /// the flip is not window-wide: Chess reports its title bar correctly and
  /// only its board upside down, so anything that already resolves to
  /// itself is left untouched.
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
    // Neither position resolves to this element (occluded, or a container
    // whose hit-test lands on a child). Reporting the app's own value
    // beats inventing one.
    return reported
  }

  /// Every window the app currently exposes, so a caller can see that an
  /// action opened a new one (⌘N in a document app) instead of silently
  /// staring at the window the session happens to be pinned to.
  func windowInventory(
    application: AXUIElement,
    pinnedWindowID: CGWindowID?
  ) -> [[String: Any]] {
    let focusedID = elementAttribute(application, kAXFocusedWindowAttribute)
      .flatMap { computerUseWindowID(for: $0) }
    return elementsAttribute(application, kAXWindowsAttribute).compactMap { candidate in
      guard let id = computerUseWindowID(for: candidate) else { return nil }
      var entry: [String: Any] = [
        "windowId": Int(id),
        "isSessionWindow": id == pinnedWindowID,
        "isFocused": id == focusedID,
        "hasModalSheet": !sheetElements(of: candidate).isEmpty,
        "isOnActiveSpace": windowIsOnVisibleSpace(id),
      ]
      if let title = stringAttribute(candidate, kAXTitleAttribute), !title.isEmpty {
        entry["title"] = title
      }
      if let frame = frame(of: candidate) { entry["screenBounds"] = frameObject(frame) }
      return entry
    }
  }

  func sheetElements(of window: AXUIElement) -> [AXUIElement] {
    let declared = elementsAttribute(window, "AXSheets")
    if !declared.isEmpty { return declared }
    return elementsAttribute(window, kAXChildrenAttribute).filter {
      stringAttribute($0, kAXRoleAttribute) == "AXSheet"
    }
  }

  /// A sheet is its own WindowServer window sitting inside its parent's
  /// bounds, and it is app-modal: events stamped with the parent's window
  /// id are refused while it is up. Resolve the window that actually owns
  /// the point so pointer events reach the dialog.
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
