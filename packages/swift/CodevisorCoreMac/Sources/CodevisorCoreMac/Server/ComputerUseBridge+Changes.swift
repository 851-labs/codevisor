import AppKit
import ApplicationServices
import Foundation

nonisolated(unsafe) let computerUseChangeNotifications: [CFString] = [
  kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
  kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
  kAXUIElementDestroyedNotification, kAXCreatedNotification, kAXValueChangedNotification,
  kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
  kAXSelectedTextChangedNotification, kAXRowCountChangedNotification, kAXRowExpandedNotification,
  kAXRowCollapsedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXLayoutChangedNotification,
  "AXSheetCreated",
].map { $0 as CFString }

final class ComputerUseChangeSignal {
  let stopsOnFirstChange: Bool
  var notification: String?
  var count = 0

  init(stopsOnFirstChange: Bool) {
    self.stopsOnFirstChange = stopsOnFirstChange
  }
}

final class ComputerUseChangeSignals: @unchecked Sendable {
  private let lock = NSLock()
  private var signals: [ObjectIdentifier: ComputerUseChangeSignal] = [:]

  subscript(observer: AXObserver) -> ComputerUseChangeSignal? {
    get { lock.withLock { signals[ObjectIdentifier(observer)] } }
    set { lock.withLock { signals[ObjectIdentifier(observer)] = newValue } }
  }
}

let computerUseChangeSignals = ComputerUseChangeSignals()

func computerUseRecordChange(observer: AXObserver, notification: CFString) {
  guard let signal = computerUseChangeSignals[observer] else { return }
  if signal.notification == nil { signal.notification = notification as String }
  signal.count += 1
  if signal.stopsOnFirstChange { CFRunLoopStop(CFRunLoopGetCurrent()) }
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
    let signal = ComputerUseChangeSignal(stopsOnFirstChange: true)
    let supported =
      pid == ProcessInfo.processInfo.processIdentifier
      ? nil
      : observeChanges(pid: pid, signal: signal) { registered in
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while signal.notification == nil, registered {
          let remaining = deadline - ProcessInfo.processInfo.systemUptime
          guard remaining > 0 else { break }
          CFRunLoopRunInMode(.defaultMode, remaining, true)
        }
        return registered
      }
    guard supported == true else {
      Thread.sleep(forTimeInterval: min(timeout, 0.2))
      return ["changed": false, "supported": false]
    }
    var result: [String: Any] = ["changed": signal.notification != nil, "supported": true]
    if let notification = signal.notification { result["notification"] = notification }
    return result
  }

  func awaitQuiet(pid: pid_t, quietPeriod: TimeInterval = 0.15, maxWait: TimeInterval) {
    guard maxWait > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
    let signal = ComputerUseChangeSignal(stopsOnFirstChange: false)
    observeChanges(pid: pid, signal: signal) { registered in
      guard registered else { return }
      let deadline = ProcessInfo.processInfo.systemUptime + maxWait
      while true {
        let before = signal.count
        let slice = min(quietPeriod, deadline - ProcessInfo.processInfo.systemUptime)
        guard slice > 0 else { break }
        CFRunLoopRunInMode(.defaultMode, slice, false)
        if signal.count == before { break }
      }
    }
  }

  @discardableResult
  private func observeChanges<Result>(
    pid: pid_t, signal: ComputerUseChangeSignal, _ body: (_ registered: Bool) -> Result
  ) -> Result? {
    var observer: AXObserver?
    let callback: AXObserverCallback = { observer, _, notification, _ in
      computerUseRecordChange(observer: observer, notification: notification)
    }
    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return nil }
    computerUseChangeSignals[observer] = signal
    let application = AXUIElementCreateApplication(pid)
    let registered = computerUseChangeNotifications.filter {
      AXObserverAddNotification(observer, application, $0, nil) == .success
    }
    let source = AXObserverGetRunLoopSource(observer)
    let runLoop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(runLoop, source, .defaultMode)
    defer {
      CFRunLoopRemoveSource(runLoop, source, .defaultMode)
      for notification in registered {
        AXObserverRemoveNotification(observer, application, notification)
      }
      computerUseChangeSignals[observer] = nil
    }
    return body(!registered.isEmpty)
  }
}
