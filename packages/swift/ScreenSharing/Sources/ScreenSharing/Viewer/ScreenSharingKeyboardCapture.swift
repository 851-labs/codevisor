#if os(macOS)
  import AppKit

  @MainActor
  protocol ScreenSharingKeyboardCapture: AnyObject {
    /// `handle` runs on the main actor for each key event the tap claimed, in arrival order; its
    /// result says whether the surface routed it (the tap already consumed it). `interrupted` runs on
    /// the main actor when the system takes the tap away for good.
    func start(
      handle: @escaping (CGEventType, CGEvent) -> Bool,
      interrupted: @escaping () -> Void
    ) -> Bool
    /// Whether the tap claims key events from now on. The tap decides on its own thread from this
    /// snapshot, so a busy main thread never holds up the system's keyboard.
    func setClaimsKeys(_ claims: Bool)
    func stop()
  }

  extension ScreenSharingKeyboardCapture {
    func setClaimsKeys(_ claims: Bool) {}
  }

  /// The system state `ScreenSharingSystemKeyboardCapture.start` installs: a
  /// Quartz session tap serviced by its own thread. Behind a protocol only so
  /// a test can drive the tap callback it registers; installing the real tap in
  /// a test would grab the developer's keyboard for the whole process.
  @MainActor
  protocol ScreenSharingKeyboardTapInstaller {
    /// Returns the teardown of the installed tap, or nil when it cannot be created. The installer
    /// keeps `context` alive for as long as `callback` can run, and gives it the tap's re-enable.
    func install(
      eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, context: ScreenSharingKeyboardTapContext
    ) -> (() -> Void)?
  }

  /// The product installer: the head-inserted session tap, serviced by a dedicated thread's run
  /// loop. On the main run loop every system-wide keystroke waited for Codevisor's main thread
  /// while control was active, and macOS disables a tap whose thread doesn't answer in time.
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

  /// Runs one tap's run-loop source on its own thread until `stop()`. The thread keeps the
  /// callback's context alive while it can still call it.
  final class ScreenSharingKeyboardTapThread: @unchecked Sendable {
    // Immutable after init; CF mach ports and run-loop sources are thread-safe to enable,
    // invalidate and remove.
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
      // Returns on `CFRunLoopStop`, or once the invalidated source leaves the run loop empty.
      CFRunLoopRun()
      CFRunLoopRemoveSource(current, source, .commonModes)
      withExtendedLifetime(context) {}
    }

    /// macOS turned the tap off because an answer came too late: turn it back on, on the tap's thread.
    func reenable() { CGEvent.tapEnable(tap: tap, enable: true) }

    /// Never waits for the thread: invalidating the port removes its source, which ends the run loop.
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

  /// What the tap's callback reads on the tap's thread: whether keys are claimed right now, and
  /// where a claimed key or an interruption goes (the main actor, asynchronously, in order).
  final class ScreenSharingKeyboardTapContext: @unchecked Sendable {
    /// A claimed key, copied so it outlives the callback.
    struct Key: @unchecked Sendable {
      let type: CGEventType
      let event: CGEvent
    }

    private let lock = NSLock()
    private var claims = false
    private var reenable: (@Sendable () -> Void)?
    private let deliver: @Sendable (ScreenSharingKeyboardTapContext, Key) -> Void
    private let interrupt: @Sendable (ScreenSharingKeyboardTapContext) -> Void

    /// `deliver` and `interrupt` are called on the tap's thread and must not wait for anything.
    init(
      deliver: @escaping @Sendable (ScreenSharingKeyboardTapContext, Key) -> Void,
      interrupt: @escaping @Sendable (ScreenSharingKeyboardTapContext) -> Void
    ) {
      self.deliver = deliver; self.interrupt = interrupt
    }

    func setClaims(_ claims: Bool) { lock.withLock { self.claims = claims } }
    func setReenable(_ reenable: @escaping @Sendable () -> Void) { lock.withLock { self.reenable = reenable } }

    /// The callback's decision: nil consumes the event.
    func decide(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
      switch type {
      case .tapDisabledByTimeout:
        // A late answer, not a revocation: keep capturing.
        lock.withLock { reenable }?()
        return Unmanaged.passUnretained(event)
      case .tapDisabledByUserInput:
        interrupt(self)
        return Unmanaged.passUnretained(event)
      case .keyDown, .keyUp, .flagsChanged:
        guard event.getIntegerValueField(.eventSourceUserData) != ScreenSharingInputInjector.eventTag,
          lock.withLock({ claims }), let copy = event.copy()
        else { return Unmanaged.passUnretained(event) }
        deliver(self, Key(type: type, event: copy))
        return nil
      default:
        return Unmanaged.passUnretained(event)
      }
    }
  }

  /// Filters shortcuts before macOS or the app menu handles them. The tap claims keys from a
  /// snapshot of whether the focused video owns the keyboard (`setClaimsKeys`), decided on the
  /// tap's thread; the input surface routes each claimed key on the main actor afterwards.
  @MainActor
  final class ScreenSharingSystemKeyboardCapture: ScreenSharingKeyboardCapture {
    private let installer: any ScreenSharingKeyboardTapInstaller
    private var teardown: (() -> Void)?
    private var context: ScreenSharingKeyboardTapContext?
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
      // A key or interruption already queued for main when the tap stops or restarts is dropped:
      // only the context of the running tap reaches the handlers.
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
      self.handle = handle
      self.interrupted = interrupted
      guard
        let teardown = installer.install(
          eventsOfInterest: mask,
          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // Runs on the tap's thread: decides from the claim snapshot and never waits for main.
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
