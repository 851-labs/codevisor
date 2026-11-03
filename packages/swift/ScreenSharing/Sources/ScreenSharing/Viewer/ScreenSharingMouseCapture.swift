#if os(macOS)
  import AppKit

  @MainActor
  protocol ScreenSharingMouseCapture: AnyObject {
    func start(handle: @escaping @MainActor (CGEventType, CGEvent) -> Void) -> Bool
    func setWindow(_ windowNumber: Int?)
    func stop()
  }

  enum ScreenSharingMouseTypes {
    static let buttons: [CGEventType] = [
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
    ]
    static let motion: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    static let all = buttons + motion
    static let downs: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
  }

  final class ScreenSharingMouseTapFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var window: Int?
    private var port: CFMachPort?
    private let deliver: @Sendable (CGEventType, CGEvent) -> Void

    init(window: Int?, deliver: @escaping @Sendable (CGEventType, CGEvent) -> Void) {
      self.window = window
      self.deliver = deliver
    }

    func set(window: Int?) { lock.withLock { self.window = window } }
    func set(port: CFMachPort?) { lock.withLock { self.port = port } }

    func observe(_ type: CGEventType, _ event: CGEvent) {
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
        return
      }
      guard ScreenSharingMouseTypes.all.contains(type),
        event.getIntegerValueField(.eventSourceUserData) != ScreenSharingInputInjector.eventTag,
        let window = lock.withLock({ window }),
        Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer)) == window,
        let copy = event.copy()
      else { return }

      deliver(type, copy)
    }
  }

  @MainActor
  final class ScreenSharingSystemMouseCapture: ScreenSharingMouseCapture {
    private static let callback: CGEventTapCallBack = { _, type, event, info in
      if let info { Unmanaged<ScreenSharingMouseTapFilter>.fromOpaque(info).takeUnretainedValue().observe(type, event) }
      return Unmanaged.passUnretained(event)
    }

    private var filter: ScreenSharingMouseTapFilter?
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var window: Int?

    func start(handle: @escaping @MainActor (CGEventType, CGEvent) -> Void) -> Bool {
      stop()
      let filter = ScreenSharingMouseTapFilter(window: window) { [weak self] type, event in
        nonisolated(unsafe) let event = event
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, self.filter != nil else { return }
            handle(type, event)
          }
        }
      }
      let mask = ScreenSharingMouseTypes.all.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
      guard
        let port = CGEvent.tapCreate(
          tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
          eventsOfInterest: mask, callback: Self.callback, userInfo: Unmanaged.passUnretained(filter).toOpaque()),
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
      else { return false }

      filter.set(port: port)
      self.filter = filter
      self.port = port
      runLoop = Self.run(port: port, source: source, retaining: filter)
      return true
    }

    func setWindow(_ windowNumber: Int?) {
      window = windowNumber
      filter?.set(window: windowNumber)
    }

    func stop() {
      filter?.set(window: nil)
      filter?.set(port: nil)
      if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
      if let runLoop { CFRunLoopStop(runLoop) }
      filter = nil; port = nil; runLoop = nil
    }

    isolated deinit { stop() }

    private static func run(
      port: CFMachPort, source: CFRunLoopSource, retaining filter: ScreenSharingMouseTapFilter
    )
      -> CFRunLoop?
    {
      nonisolated(unsafe) let tap = (port: port, source: source)
      nonisolated(unsafe) var loop: CFRunLoop?
      let ready = DispatchSemaphore(value: 0)
      let thread = Thread {
        loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, tap.source, .commonModes)
        CGEvent.tapEnable(tap: tap.port, enable: true)
        ready.signal()
        CFRunLoopRun()
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tap.source, .commonModes)
        withExtendedLifetime(filter) {}
      }
      thread.name = "codevisor.screen-sharing.mouse-tap"
      thread.qualityOfService = .userInteractive
      thread.start()
      ready.wait()
      return loop
    }
  }
#endif
