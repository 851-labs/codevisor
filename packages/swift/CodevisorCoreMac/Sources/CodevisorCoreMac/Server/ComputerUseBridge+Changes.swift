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
  var count = 0
}

func computerUseSettleWindow(sinceAction elapsed: TimeInterval?) -> TimeInterval {
  guard let elapsed, elapsed >= 0 else { return 0 }
  return max(0, 1.5 - elapsed)
}

func computerUseLoadingWindow(sinceAction elapsed: TimeInterval?) -> TimeInterval {
  guard let elapsed, elapsed >= 0 else { return 0 }
  return max(0, 5 - elapsed)
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
      signal.count += 1
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

  func awaitQuiet(pid: pid_t, quietPeriod: TimeInterval = 0.15, maxWait: TimeInterval) {
    guard maxWait > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      Unmanaged<ComputerUseChangeSignal>.fromOpaque(refcon).takeUnretainedValue().count += 1
    }
    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
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
    guard !registered.isEmpty else { return }
    let deadline = ProcessInfo.processInfo.systemUptime + maxWait
    while true {
      let before = signal.count
      let slice = min(quietPeriod, deadline - ProcessInfo.processInfo.systemUptime)
      guard slice > 0 else { break }
      CFRunLoopRunInMode(.defaultMode, slice, false)
      if signal.count == before { break }
    }
    withExtendedLifetime(signal) {}
  }
}
