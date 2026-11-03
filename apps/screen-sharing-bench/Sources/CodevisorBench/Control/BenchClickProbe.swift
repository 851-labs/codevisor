import AppKit
import ScreenSharingBench
import Synchronization

final class BenchClickProbe: @unchecked Sendable {
  struct Summary: Encodable {
    let installed: Bool
    let accessibilityTrusted: Bool
    let listenEventAccess: Bool
    let postEventAccess: Bool
    let tappedNs: [Int64]
    let tapMainNs: [Int64]
  }

  private static let callback: CGEventTapCallBack = { _, type, event, context in
    if type == .leftMouseDown, let context {
      Unmanaged<BenchClickProbe>.fromOpaque(context).takeUnretainedValue().saw()
    }
    return Unmanaged.passUnretained(event)
  }

  private let tapped = Mutex<[Int64]>([])
  private var tapMain: [Int64] = []
  private var port: CFMachPort?
  private var runLoop: CFRunLoop?

  @MainActor
  func start() -> Bool {
    let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
        callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    else { return false }

    self.port = port
    let ready = DispatchSemaphore(value: 0)
    nonisolated(unsafe) let tap = (port: port, source: source)
    let thread = Thread { [self] in
      runLoop = CFRunLoopGetCurrent()
      CFRunLoopAddSource(runLoop, tap.source, .commonModes)
      CGEvent.tapEnable(tap: tap.port, enable: true)
      ready.signal()
      CFRunLoopRun()
    }
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    return true
  }

  @MainActor
  func stop() {
    if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
    if let runLoop { CFRunLoopStop(runLoop) }
    port = nil
    runLoop = nil
  }

  @MainActor
  func summary(installed: Bool) -> Summary {
    Summary(
      installed: installed, accessibilityTrusted: AXIsProcessTrusted(),
      listenEventAccess: CGPreflightListenEventAccess(),
      postEventAccess: CGPreflightPostEventAccess(), tappedNs: tapped.withLock { $0 }, tapMainNs: tapMain)
  }

  private func saw() {
    tapped.withLock { $0.append(BenchMachClock.nowNs()) }
    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated { tapMain.append(BenchMachClock.nowNs()) }
    }
  }
}
