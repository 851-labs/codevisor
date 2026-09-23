#if os(macOS)
  import AppKit
  import ScreenSharing

  @MainActor
  protocol ScreenSharingInputTarget: NSView {
    func pointer(_ event: NSEvent, clamp: Bool) -> ScreenSharingPointer?
    func controlCursorChanged()
  }

  /// Responder and event routing for the native surface. The session event tap
  /// captures system shortcuts; the local monitor also handles app-delivered events.
  /// Both send physical keys for the host's keyboard layout to interpret, except
  /// synthesized typing (851-2318): Computer Use `typeText` posts key code 0
  /// carrying the text, which as a physical key would be A. A key-code-0 press
  /// whose characters aren't what that key gives on the local layout is sent as
  /// the text instead (the server receives the character's keysym).
  @MainActor
  final class ScreenSharingInputSurface {
    private weak var view: (any ScreenSharingInputTarget)?
    private let notificationCenter: NotificationCenter
    private let keyboardCapture: any ScreenSharingKeyboardCapture
    private let applicationIsActive: () -> Bool
    /// Paces the motion flush. Injected so a test can hold and release the
    /// coalescing window instead of racing a 16 ms wall-clock timer.
    private let clock: any Clock<Duration>
    var onInput: ((ScreenSharingInputEvent) -> Void)?
    var onRelease: (() -> Void)?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var motionTask: Task<Void, Never>?
    private var pendingMotion: ScreenSharingInputEvent?
    private var buttons = Set<UInt8>()
    private var modifiers: UInt8 = 0
    private var keys = Set<UInt16>()
    /// Key codes whose press went out as text: their release sends nothing.
    private var textKeys = Set<UInt16>()
    private let layout: VNCKeyTranslator.Layout
    private var scroll = ScreenSharingScrollAccumulator()
    private var lastPointer: ScreenSharingPointer?
    private var inputFocused = false
    private(set) var active = false
    /// Input is actually going to the host: the lease is active and the video
    /// has focus. While suspended (another app, a menu, a local control) the
    /// pointer must look and behave as in View mode, not as the host's cursor.
    var isLive: Bool { active && inputFocused }
    private(set) var failureMessage: String?

    init(
      view: any ScreenSharingInputTarget, notificationCenter: NotificationCenter = .default,
      keyboardCapture: any ScreenSharingKeyboardCapture = ScreenSharingSystemKeyboardCapture(),
      applicationIsActive: @escaping () -> Bool = { NSApp.isActive },
      clock: any Clock<Duration> = ContinuousClock(),
      layout: @escaping VNCKeyTranslator.Layout = VNCKeyTranslator.currentLayout
    ) {
      self.layout = layout
      self.view = view
      self.notificationCenter = notificationCenter
      self.keyboardCapture = keyboardCapture
      self.applicationIsActive = applicationIsActive
      self.clock = clock
    }

    func begin() -> Bool {
      guard !active else { return true }
      failureMessage = nil
      guard let view, let window = view.window, window.isKeyWindow,
        window.makeFirstResponder(view)
      else {
        failureMessage = "Focus this window and request control again."
        return false
      }
      guard
        keyboardCapture.start(
          handle: { [weak self] type, event in self?.routeSystemKey(type, event: event) ?? false },
          interrupted: { [weak self] in
            guard let self, self.active else { return }
            self.suspend()
            self.failureMessage = "Keyboard capture stopped. Request control again to resume."
            self.onRelease?()
          }
        )
      else {
        failureMessage =
          "Allow Codevisor in this Mac’s System Settings → Privacy & Security → Accessibility, then request control again."
        return false
      }
      active = true
      inputFocused = true
      view.controlCursorChanged()
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        guard let self else { return event }
        return self.route(event)
      }
      let suspend: @Sendable (Notification) -> Void = { [weak self] _ in
        MainActor.assumeIsolated { self?.suspend() }
      }
      // Coming back (⌘Tab, a closed menu, the window key again) with the video
      // still first responder resumes input: nothing else would, since the view
      // never lost first responder, and the pointer would stay invisible.
      let resume: @Sendable (Notification) -> Void = { [weak self] _ in
        MainActor.assumeIsolated { self?.resumeIfFocused() }
      }
      observers = [
        notificationCenter.addObserver(
          forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: suspend),
        notificationCenter.addObserver(
          forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: suspend),
        notificationCenter.addObserver(
          forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main, using: suspend),
        notificationCenter.addObserver(
          forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: resume),
        notificationCenter.addObserver(
          forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: resume),
        notificationCenter.addObserver(
          forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main, using: resume),
      ]
      motionTask = Task { [weak self, clock] in
        while !Task.isCancelled {
          do { try await clock.sleep(for: .milliseconds(16)) } catch { return }
          self?.flushMotion()
        }
      }
      return true
    }

    func end() {
      active = false
      inputFocused = false
      keyboardCapture.stop()
      view?.controlCursorChanged()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      for observer in observers { notificationCenter.removeObserver(observer) }
      observers = []; motionTask?.cancel(); motionTask = nil
      pendingMotion = nil; buttons = []; keys = []; textKeys = []; modifiers = 0; scroll = .init(); lastPointer = nil
    }

    /// Local controls may own focus while the remote-control lease stays active.
    /// Release held input immediately so a menu cannot strand a remote key or drag.
    func suspend() {
      guard active else { return }
      let wasLive = inputFocused
      inputFocused = false
      if wasLive { view?.controlCursorChanged() }
      pendingMotion = nil
      let heldKeys = keys.sorted()
      let heldButtons = buttons.sorted()
      keys = []; textKeys = []; buttons = []; scroll = .init()
      for code in heldKeys {
        onInput?(.key(code: code, down: false, repeatKey: false, modifiers: modifiers))
      }
      syncModifiers([])
      if let point = lastPointer {
        for button in heldButtons {
          onInput?(.button(point, button: button, down: false, clicks: 1, modifiers: 0))
        }
      }
    }

    func resume() {
      guard active, !inputFocused else { return }
      inputFocused = true
      view?.controlCursorChanged()
    }

    /// Resumes only when the video really has focus again: app active, window
    /// key, video first responder, nothing modal in front.
    func resumeIfFocused() {
      guard active, applicationIsActive(), let view, let window = view.window, window.isKeyWindow,
        window.firstResponder === view, !view.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
        NSApp.modalWindow == nil
      else { return }
      resume()
    }

    func route(_ event: NSEvent) -> NSEvent? {
      guard active, let view else { return event }
      if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ScreenSharingInputInjector.eventTag {
        return event
      }
      if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
        if let window = view.window, window.isKeyWindow, event.window === window,
          view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        {
          if window.makeFirstResponder(view) { resume() }
        } else {
          suspend()
        }
        return event
      }
      guard view.window?.isKeyWindow == true, event.window === view.window else { suspend(); return event }
      return routeFocusedKey(event) ? nil : event
    }

    /// Quartz events have no AppKit window association. Never infer ownership
    /// from event.window; require the live app/window/responder relationship.
    func routeSystemKey(_ type: CGEventType, event: CGEvent) -> Bool {
      guard [.keyDown, .keyUp, .flagsChanged].contains(type),
        event.getIntegerValueField(.eventSourceUserData) != ScreenSharingInputInjector.eventTag,
        let key = NSEvent(cgEvent: event)
      else { return false }
      return routeFocusedKey(key)
    }

    private func routeFocusedKey(_ event: NSEvent) -> Bool {
      guard active, applicationIsActive(), let view, let window = view.window, window.isKeyWindow,
        !view.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil, NSApp.modalWindow == nil
      else { suspend(); return false }
      if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.contains([.control, .option]) {
        onRelease?(); return true
      }
      guard inputFocused, window.firstResponder === view else { suspend(); return false }
      flushMotion()
      syncModifiers(event.modifierFlags)
      guard active else { return true }
      if event.type == .flagsChanged { return true }
      let down = event.type == .keyDown
      if !down, textKeys.remove(event.keyCode) != nil { return true }
      if down, let text = synthesizedText(event) {
        textKeys.insert(event.keyCode)
        onInput?(.text(text))
        return true
      }
      if down { keys.insert(event.keyCode) } else if keys.remove(event.keyCode) == nil { return true }
      onInput?(.key(code: event.keyCode, down: down, repeatKey: event.isARepeat, modifiers: modifiers))
      return true
    }

    /// The text a synthesized key press carries, or nil for a physical key.
    /// Only key code 0 (what `typeText` uses) and never with Control or
    /// Command, whose characters differ from the layout's by design.
    private func synthesizedText(_ event: NSEvent) -> String? {
      guard event.keyCode == 0, modifiers & (2 | 8) == 0, let characters = event.characters, !characters.isEmpty
      else { return nil }
      let physical = layout(0, VNCKeyTranslator.carbonModifiers(modifiers)).map { String(Character($0)) }
      return characters == physical ? nil : characters
    }

    func mouse(_ event: NSEvent) {
      guard active, inputFocused, let view, let window = view.window, window.isKeyWindow, event.window === window,
        window.firstResponder === view,
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) != ScreenSharingInputInjector.eventTag,
        let point = view.pointer(event, clamp: !buttons.isEmpty)
      else { return }
      lastPointer = point
      let flags = Self.flags(event.modifierFlags)
      switch event.type {
      case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        pendingMotion = .move(point, modifiers: flags)
      case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
        guard (0...2).contains(event.buttonNumber) else { return }
        flushMotion(); syncModifiers(event.modifierFlags)
        let button = UInt8(event.buttonNumber)
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        if down { buttons.insert(button) } else { buttons.remove(button) }
        onInput?(
          .button(point, button: button, down: down, clicks: UInt8(min(3, max(1, event.clickCount))), modifiers: flags))
      case .scrollWheel:
        flushMotion(); syncModifiers(event.modifierFlags)
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let delta = scroll.add(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale)
        if delta.x != 0 || delta.y != 0 { onInput?(.scroll(point, x: delta.x, y: delta.y, modifiers: flags)) }
      default: break
      }
    }

    private func flushMotion() {
      guard active, let pending = pendingMotion else { return }
      pendingMotion = nil
      onInput?(pending)
    }

    private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
      let next = Self.flags(flags)
      let codes: [(UInt8, UInt16)] = [(1, 56), (2, 59), (4, 58), (8, 55), (32, 63)]
      for (mask, code) in codes where (next & mask) != (modifiers & mask) {
        let down = next & mask != 0
        if down { modifiers |= mask } else { modifiers &= ~mask }
        onInput?(.key(code: code, down: down, repeatKey: false, modifiers: modifiers))
      }
      modifiers = next
    }

    private static func flags(_ flags: NSEvent.ModifierFlags) -> UInt8 {
      let values: [NSEvent.ModifierFlags] = [.shift, .control, .option, .command, .capsLock, .function]
      return values.enumerated().reduce(UInt8(0)) { result, entry in
        result | (flags.contains(entry.element) ? 1 << entry.offset : 0)
      }
    }
  }
#endif
