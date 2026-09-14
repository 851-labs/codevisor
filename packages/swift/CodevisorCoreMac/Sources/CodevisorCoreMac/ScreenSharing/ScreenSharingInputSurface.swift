import AppKit
import CodevisorScreenSharing

/// Responder and event routing for the native surface. AppKit delivers ordinary
/// physical key events; the host's keyboard layout and input method interpret them.
@MainActor
final class ScreenSharingInputSurface {
  private weak var view: ScreenSharingVideoSurface?
  var onInput: ((ScreenSharingInputEvent) -> Void)?
  var onRelease: (() -> Void)?
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var motionTask: Task<Void, Never>?
  private var pendingMotion: ScreenSharingInputEvent?
  private var buttons = Set<UInt8>()
  private var modifiers: UInt8 = 0
  private var keys = Set<UInt16>()
  private var scroll = ScreenSharingScrollAccumulator()
  private(set) var active = false

  init(view: ScreenSharingVideoSurface) { self.view = view }

  func begin() -> Bool {
    guard let view, let window = view.window, window.isKeyWindow,
      window.makeFirstResponder(view)
    else { return false }
    active = true
    view.controlCursorChanged()
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      guard let self else { return event }
      return self.route(event)
    }
    let release: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.onRelease?() }
    }
    observers = [
      NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: release),
      NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: release),
    ]
    motionTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        self?.flushMotion()
      }
    }
    return true
  }

  func end() {
    active = false
    view?.controlCursorChanged()
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []; motionTask?.cancel(); motionTask = nil
    pendingMotion = nil; buttons = []; keys = []; modifiers = 0; scroll = .init()
  }

  private func route(_ event: NSEvent) -> NSEvent? {
    guard active, let view else { return event }
    if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ScreenSharingInputInjector.eventTag { return event }
    guard view.window?.isKeyWindow == true, view.window?.firstResponder === view else {
      onRelease?(); return event
    }
    if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
      if event.window !== view.window || !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
        onRelease?()
      }
      return event
    }
    if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.contains([.control, .option]) {
      onRelease?(); return nil
    }
    flushMotion()
    syncModifiers(event.modifierFlags)
    guard active else { return nil }
    if event.type == .flagsChanged { return nil }
    let down = event.type == .keyDown
    if down { keys.insert(event.keyCode) } else if keys.remove(event.keyCode) == nil { return nil }
    onInput?(.key(code: event.keyCode, down: down, repeatKey: event.isARepeat, modifiers: modifiers))
    return nil
  }

  func mouse(_ event: NSEvent) {
    guard active,
      event.cgEvent?.getIntegerValueField(.eventSourceUserData) != ScreenSharingInputInjector.eventTag,
      let point = view?.pointer(event, clamp: !buttons.isEmpty)
    else { return }
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
