#if os(macOS)
  import AppKit

  @MainActor
  protocol ScreenSharingKeyboardCapture: AnyObject {
    func start(
      handle: @escaping (CGEventType, CGEvent) -> Bool,
      interrupted: @escaping () -> Void
    ) -> Bool
    func stop()
  }

  /// The system state `ScreenSharingSystemKeyboardCapture.start` installs: a
  /// Quartz session tap and its main run-loop source. Behind a protocol only so
  /// a test can drive the tap callback it registers; installing the real tap in
  /// a test would grab the developer's keyboard for the whole process.
  @MainActor
  protocol ScreenSharingKeyboardTapInstaller {
    /// Returns the teardown of the installed tap, or nil when it cannot be created.
    func install(
      eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, context: UnsafeMutableRawPointer
    ) -> (() -> Void)?
  }

  /// The product installer: the head-inserted session tap, enabled on the main
  /// run loop, exactly as before.
  @MainActor
  struct ScreenSharingQuartzKeyboardTapInstaller: ScreenSharingKeyboardTapInstaller {
    func install(
      eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, context: UnsafeMutableRawPointer
    ) -> (() -> Void)? {
      guard
        let tap = CGEvent.tapCreate(
          tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
          eventsOfInterest: eventsOfInterest, callback: callback, userInfo: context)
      else { return nil }
      guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        CFMachPortInvalidate(tap)
        return nil
      }
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      return {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      }
    }
  }

  /// Filters shortcuts before macOS or the app menu handles them. The input
  /// surface decides synchronously whether its focused video owns each event.
  @MainActor
  final class ScreenSharingSystemKeyboardCapture: ScreenSharingKeyboardCapture {
    private let installer: any ScreenSharingKeyboardTapInstaller
    private var teardown: (() -> Void)?
    private var handle: ((CGEventType, CGEvent) -> Bool)?
    private var interrupted: (() -> Void)?

    init(installer: any ScreenSharingKeyboardTapInstaller = ScreenSharingQuartzKeyboardTapInstaller()) {
      self.installer = installer
    }

    func start(
      handle: @escaping (CGEventType, CGEvent) -> Bool,
      interrupted: @escaping () -> Void
    ) -> Bool {
      stop()
      let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
      // Installed with the handlers already reachable: the tap is enabled inside
      // `install`, and its callback reads them from this instance.
      self.handle = handle
      self.interrupted = interrupted
      guard
        let teardown = installer.install(
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
          }, context: Unmanaged.passUnretained(self).toOpaque())
      else {
        self.handle = nil
        self.interrupted = nil
        return false
      }
      self.teardown = teardown
      return true
    }

    func stop() {
      teardown?()
      teardown = nil
      handle = nil
      interrupted = nil
    }

    isolated deinit { stop() }
  }
#endif
