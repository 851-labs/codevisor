import AppKit
import ApplicationServices
import Foundation

/// Shared across bridge instances in this native app, rather than per agent.
final class ComputerUseForeground: @unchecked Sendable {
  static let shared = ComputerUseForeground()
  static let eventTag: Int64 = 0x434F44455649534F
  private let ownership = ComputerUseForegroundLock()
  private let monitorLock = NSLock()
  private var monitoring = false
  private var monitors: [Any] = []

  private struct Focus: @unchecked Sendable {
    let app: NSRunningApplication?
    let window: AXUIElement?
    let element: AXUIElement?
    let cursor: CGPoint?
  }

  func startMonitoring() {
    let shouldStart = monitorLock.withLock {
      guard !monitoring else { return false }
      monitoring = true
      return true
    }
    guard shouldStart else { return }
    DispatchQueue.main.async { [self] in
      let mask: NSEvent.EventTypeMask = [
        .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
      ]
      if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [self] in observe($0) }) {
        monitors.append(global)
      }
      if let local = NSEvent.addLocalMonitorForEvents(
        matching: mask,
        handler: { [self] in
          observe($0)
          return $0
        })
      {
        monitors.append(local)
      }
    }
  }

  private func observe(_ event: NSEvent) {
    guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return }
    ownership.humanInput()
  }

  func cancel(sessionID: String) { ownership.cancel(sessionID: sessionID) }

  func perform<Value>(
    sessionID: String, pid: pid_t, hasOpenMenu: () -> Bool, operation: () throws -> Value
  ) throws -> Value {
    startMonitoring()
    return try ownership.perform(sessionID: sessionID, pid: pid) {
      try check(pid: pid, requireFocus: false)
      let focus = captureFocus()
      defer {
        // An open menu may need another action, but never retains the lock
        // between calls. Re-observe before continuing a multi-call sequence.
        if (try? check(pid: pid)) != nil, !hasOpenMenu() { restore(focus, pid: pid) }
      }
      try check(pid: pid, requireFocus: false)
      let result = try operation()
      try check(pid: pid)
      return result
    }
  }

  func check(pid: pid_t, requireFocus: Bool = true) throws {
    try ownership.check(ownership.currentToken, pid: pid)
    if requireFocus, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
      throw BridgeError(
        "Foreground focus changed, possibly because the human switched apps. Input stopped. Observe and continue in background; do not take focus back."
      )
    }
  }

  /// Preserve authorization across self-targeted AX work dispatched to main.
  /// A main-queue callback may run after the originating request has expired.
  func authorization(pid: pid_t) -> (@Sendable () -> Bool)? {
    guard let token = ownership.currentToken else { return nil }
    return { [ownership] in (try? ownership.check(token, pid: pid)) != nil }
  }

  func post(_ event: CGEvent, pid: pid_t, releasingInput: Bool = false) throws {
    event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
    do {
      try check(pid: pid)
      try ownership.withInput(ownership.currentToken, pid: pid) { event.post(tap: .cghidEventTap) }
    } catch {
      guard releasingInput else { throw error }
      // Finish a key/button release in the original process without moving
      // the human's pointer or sending more input to the global foreground.
      ownership.withCleanup(ownership.currentToken, pid: pid) { event.postToPid(pid) }
    }
  }

  private func captureFocus() -> Focus {
    let app = NSWorkspace.shared.frontmostApplication
    let application = app.map { AXUIElementCreateApplication($0.processIdentifier) }
    if let application { AXUIElementSetMessagingTimeout(application, 1) }
    return Focus(
      app: app, window: application.flatMap { elementAttribute($0, kAXFocusedWindowAttribute) },
      element: application.flatMap { elementAttribute($0, kAXFocusedUIElementAttribute) },
      cursor: CGEvent(source: nil)?.location)
  }

  private func restore(_ focus: Focus, pid: pid_t) {
    guard (try? check(pid: pid)) != nil, let authorized = authorization(pid: pid) else { return }
    if let cursor = focus.cursor, authorized() {
      // WindowServer cursor restoration is outside the mutex, just like AX
      // restoration: a stalled OS call cannot prevent ownership expiring.
      CGWarpMouseCursorPosition(cursor)
    }
    guard let app = focus.app, !app.isTerminated else { return }
    // Restoration is part of this bounded ownership. It cannot leave a
    // separate "restoring" flag stuck, or run after a new agent takes over.
    computerUsePerformAccessibilityRead(targetPID: app.processIdentifier) {
      let application = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(application, 1)
      guard authorized() else { return }
      _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
      if let window = focus.window, authorized() {
        AXUIElementSetMessagingTimeout(window, 1)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
      }
      if let element = focus.element, authorized() {
        AXUIElementSetMessagingTimeout(element, 1)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedUIElementAttribute as CFString, element)
      }
    }
  }
}
