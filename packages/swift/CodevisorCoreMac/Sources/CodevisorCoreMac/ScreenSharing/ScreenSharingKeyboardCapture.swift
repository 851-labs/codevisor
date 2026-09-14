import AppKit

@MainActor
protocol ScreenSharingKeyboardCapture: AnyObject {
  func start(
    handle: @escaping (CGEventType, CGEvent) -> Bool,
    interrupted: @escaping () -> Void
  ) -> Bool
  func stop()
}

/// Filters shortcuts before macOS or the app menu handles them. The input
/// surface decides synchronously whether its focused video owns each event.
@MainActor
final class ScreenSharingSystemKeyboardCapture: ScreenSharingKeyboardCapture {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var handle: ((CGEventType, CGEvent) -> Bool)?
  private var interrupted: (() -> Void)?

  func start(
    handle: @escaping (CGEventType, CGEvent) -> Bool,
    interrupted: @escaping () -> Void
  ) -> Bool {
    stop()
    let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, context in
          guard let context else { return Unmanaged.passUnretained(event) }
          // This tap's source is installed only on the main run loop.
          let consumed = MainActor.assumeIsolated {
            let capture = Unmanaged<ScreenSharingSystemKeyboardCapture>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
              capture.interrupted?()
              return false
            }
            return capture.handle?(type, event) == true
          }
          return consumed ? nil : Unmanaged.passUnretained(event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else { return false }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      return false
    }
    self.handle = handle; self.interrupted = interrupted
    self.tap = tap; self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  func stop() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil; source = nil; handle = nil; interrupted = nil
  }

  isolated deinit { stop() }
}
