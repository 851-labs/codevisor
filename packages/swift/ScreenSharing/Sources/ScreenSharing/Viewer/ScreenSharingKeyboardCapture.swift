#if os(macOS)
  import AppKit

  @MainActor
  protocol ScreenSharingKeyboardCapture: AnyObject {
    func start(
      handle: @escaping (CGEventType, CGEvent) -> Bool,
      interrupted: @escaping () -> Void
    ) -> Bool
    func setClaimsKeys(_ claims: Bool)
    func setClaimsInjectedKeys(_ claims: Bool)
    func stop()
  }

  extension ScreenSharingKeyboardCapture {
    func setClaimsKeys(_ claims: Bool) {}
    func setClaimsInjectedKeys(_ claims: Bool) {}
  }

  @MainActor
  protocol ScreenSharingKeyboardTapInstaller {
    func install(
      eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, context: ScreenSharingKeyboardTapContext
    ) -> (() -> Void)?
  }

  @MainActor
  struct ScreenSharingQuartzKeyboardTapInstaller: ScreenSharingKeyboardTapInstaller {
    func install(
      eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, context: ScreenSharingKeyboardTapContext
    ) -> (() -> Void)? {
      guard
        let tap = CGEvent.tapCreate(
          tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
          eventsOfInterest: eventsOfInterest, callback: callback,
          userInfo: Unmanaged.passUnretained(context).toOpaque())
      else { return nil }
      guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        CFMachPortInvalidate(tap)
        return nil
      }
      let thread = ScreenSharingKeyboardTapThread(tap: tap, source: source, context: context)
      context.setReenable { [thread] in thread.reenable() }
      thread.start()
      return { thread.stop() }
    }
  }

  final class ScreenSharingKeyboardTapThread: @unchecked Sendable {
    private let tap: CFMachPort
    private let source: CFRunLoopSource
    private let context: ScreenSharingKeyboardTapContext
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(tap: CFMachPort, source: CFRunLoopSource, context: ScreenSharingKeyboardTapContext) {
      self.tap = tap; self.source = source; self.context = context
    }

    func start() {
      let thread = Thread { [self] in run() }
      thread.name = "codevisor.screen-sharing.keyboard-tap"
      thread.qualityOfService = .userInteractive
      thread.start()
    }

    private func run() {
      let current = CFRunLoopGetCurrent()
      guard
        lock.withLock({
          guard !stopped else { return false }
          runLoop = current
          return true
        })
      else { return }
      CFRunLoopAddSource(current, source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      CFRunLoopRun()
      CFRunLoopRemoveSource(current, source, .commonModes)
      withExtendedLifetime(context) {}
    }

    func reenable() { CGEvent.tapEnable(tap: tap, enable: true) }

    func stop() {
      let runLoop = lock.withLock {
        stopped = true
        return self.runLoop
      }
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
      if let runLoop { CFRunLoopStop(runLoop) }
    }
  }

  final class ScreenSharingKeyboardTapContext: @unchecked Sendable {
    struct Key: @unchecked Sendable {
      let type: CGEventType
      let event: CGEvent
    }

    private let lock = NSLock()
    private var claims = false
    private var claimsInjected = false
    private var reenable: (@Sendable () -> Void)?
    private let deliver: @Sendable (ScreenSharingKeyboardTapContext, Key) -> Void
    private let interrupt: @Sendable (ScreenSharingKeyboardTapContext) -> Void

    init(
      deliver: @escaping @Sendable (ScreenSharingKeyboardTapContext, Key) -> Void,
      interrupt: @escaping @Sendable (ScreenSharingKeyboardTapContext) -> Void
    ) {
      self.deliver = deliver; self.interrupt = interrupt
    }

    func setClaims(_ claims: Bool) { lock.withLock { self.claims = claims } }
    func setClaimsInjected(_ claims: Bool) { lock.withLock { claimsInjected = claims } }
    func setReenable(_ reenable: @escaping @Sendable () -> Void) { lock.withLock { self.reenable = reenable } }

    func decide(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
      switch type {
      case .tapDisabledByTimeout:
        lock.withLock { reenable }?()
        return Unmanaged.passUnretained(event)
      case .tapDisabledByUserInput:
        interrupt(self)
        return Unmanaged.passUnretained(event)
      case .keyDown, .keyUp, .flagsChanged:
        let injected = event.getIntegerValueField(.eventSourceUserData) == ScreenSharingInputInjector.eventTag
        guard lock.withLock({ claims && (claimsInjected || !injected) }), let copy = event.copy()
        else { return Unmanaged.passUnretained(event) }
        deliver(self, Key(type: type, event: copy))
        return nil
      default:
        return Unmanaged.passUnretained(event)
      }
    }
  }

  @MainActor
  final class ScreenSharingSystemKeyboardCapture: ScreenSharingKeyboardCapture {
    private let installer: any ScreenSharingKeyboardTapInstaller
    private var teardown: (() -> Void)?
    private var context: ScreenSharingKeyboardTapContext?
    private var claimsInjectedKeys = false
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
      let context = ScreenSharingKeyboardTapContext(
        deliver: { [weak self] context, key in
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              guard let self, self.context === context else { return }
              _ = self.handle?(key.type, key.event)
            }
          }
        },
        interrupt: { [weak self] context in
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              guard let self, self.context === context else { return }
              self.interrupted?()
            }
          }
        })
      context.setClaimsInjected(claimsInjectedKeys)
      self.handle = handle
      self.interrupted = interrupted
      guard
        let teardown = installer.install(
          eventsOfInterest: mask,
          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ScreenSharingKeyboardTapContext>.fromOpaque(context).takeUnretainedValue()
              .decide(type, event)
          }, context: context)
      else {
        self.handle = nil
        self.interrupted = nil
        return false
      }
      self.context = context
      self.teardown = teardown
      return true
    }

    func setClaimsKeys(_ claims: Bool) { context?.setClaims(claims) }

    func setClaimsInjectedKeys(_ claims: Bool) {
      claimsInjectedKeys = claims
      context?.setClaimsInjected(claims)
    }

    func stop() {
      context?.setClaims(false)
      context = nil
      teardown?()
      teardown = nil
      handle = nil
      interrupted = nil
    }

    isolated deinit { stop() }
  }
#endif
