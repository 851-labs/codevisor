#if os(macOS)
  import AppKit

  @MainActor
  protocol ScreenSharingMouseCapture: AnyObject {
    func start(handle: @escaping @MainActor (CGEventType, CGEvent) -> Void) -> Bool
    func setWindow(_ windowNumber: Int?)
    func setAcceptsInjected(_ accepts: Bool)
    func stop()
  }

  enum ScreenSharingMouseTypes {
    static let buttons: [CGEventType] = [
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
    ]
    static let motion: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    static let all = buttons + motion
    static let downs: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    static let ups: [CGEventType] = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
  }

  final class ScreenSharingMouseTapFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var window: Int?
    private var acceptsInjected: Bool
    private var pressed = false
    private var port: CFMachPort?
    private let deliver: @Sendable (CGEventType, CGEvent) -> Void

    init(window: Int?, acceptsInjected: Bool = false, deliver: @escaping @Sendable (CGEventType, CGEvent) -> Void) {
      self.window = window
      self.acceptsInjected = acceptsInjected
      self.deliver = deliver
    }

    func set(window: Int?) {
      lock.withLock {
        self.window = window
        if window == nil { pressed = false }
      }
    }
    func set(acceptsInjected: Bool) { lock.withLock { self.acceptsInjected = acceptsInjected } }
    func set(port: CFMachPort?) { lock.withLock { self.port = port } }

    func observe(_ type: CGEventType, _ event: CGEvent) {
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
        return
      }
      guard ScreenSharingMouseTypes.all.contains(type), claims(type, event), let copy = event.copy() else { return }

      deliver(type, copy)
    }

    private func claims(_ type: CGEventType, _ event: CGEvent) -> Bool {
      let injected = event.getIntegerValueField(.eventSourceUserData) == ScreenSharingInputInjector.eventTag
      let under = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
      return lock.withLock {
        guard let window, acceptsInjected || !injected, pressed || under == window else { return false }

        if ScreenSharingMouseTypes.downs.contains(type) { pressed = true }
        if ScreenSharingMouseTypes.ups.contains(type) { pressed = false }
        return true
      }
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
    private var acceptsInjected = false
    private var generation = 0
    private let trusted: () -> Bool

    init(trusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
      self.trusted = trusted
    }

    func start(handle: @escaping @MainActor (CGEventType, CGEvent) -> Void) -> Bool {
      stop()
      guard trusted() else { return false }

      generation += 1
      let started = generation
      let filter = ScreenSharingMouseTapFilter(window: window, acceptsInjected: acceptsInjected) {
        [weak self] type, event in
        nonisolated(unsafe) let event = event
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, self.generation == started, self.filter != nil else { return }
            handle(type, event)
          }
        }
      }
      let mask = ScreenSharingMouseTypes.all.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
      guard
        let port = CGEvent.tapCreate(
          tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
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

    func setAcceptsInjected(_ accepts: Bool) {
      acceptsInjected = accepts
      filter?.set(acceptsInjected: accepts)
    }

    func stop() {
      generation += 1
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
