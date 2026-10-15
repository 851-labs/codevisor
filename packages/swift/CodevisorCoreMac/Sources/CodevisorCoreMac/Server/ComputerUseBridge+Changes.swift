import AppKit
import ApplicationServices
import Foundation

let computerUseChangeNotifications = [
  kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
  kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
  kAXUIElementDestroyedNotification, kAXCreatedNotification, kAXValueChangedNotification,
  kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
  kAXSelectedTextChangedNotification, kAXRowCountChangedNotification, kAXRowExpandedNotification,
  kAXRowCollapsedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXLayoutChangedNotification,
  "AXSheetCreated",
]

private final class ComputerUseChangeSignal {
  var notification: String?
}

extension ComputerUseBridge {
  func awaitChange(pid: pid_t, timeout: TimeInterval) -> [String: Any] {
    let timeout = min(max(timeout, 0), 5)
    guard pid != ProcessInfo.processInfo.processIdentifier else {
      Thread.sleep(forTimeInterval: min(timeout, 0.2))
      return ["changed": false, "supported": false]
    }
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, notification, refcon in
      guard let refcon else { return }
      let signal = Unmanaged<ComputerUseChangeSignal>.fromOpaque(refcon).takeUnretainedValue()
      if signal.notification == nil { signal.notification = notification as String }
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
      Thread.sleep(forTimeInterval: min(timeout, 0.2))
      return ["changed": false, "supported": false]
    }
    let signal = ComputerUseChangeSignal()
    let refcon = Unmanaged.passUnretained(signal).toOpaque()
    let application = AXUIElementCreateApplication(pid)
    let registered = computerUseChangeNotifications.filter {
      AXObserverAddNotification(observer, application, $0 as CFString, refcon) == .success
    }
    let source = AXObserverGetRunLoopSource(observer)
    let runLoop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(runLoop, source, .defaultMode)
    defer {
      CFRunLoopRemoveSource(runLoop, source, .defaultMode)
      for notification in registered {
        AXObserverRemoveNotification(observer, application, notification as CFString)
      }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while signal.notification == nil, !registered.isEmpty {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { break }
      CFRunLoopRunInMode(.defaultMode, remaining, true)
    }
    if registered.isEmpty { Thread.sleep(forTimeInterval: min(timeout, 0.2)) }
    var result: [String: Any] = ["changed": signal.notification != nil, "supported": !registered.isEmpty]
    if let notification = signal.notification { result["notification"] = notification }
    return withExtendedLifetime(signal) { result }
  }
}
