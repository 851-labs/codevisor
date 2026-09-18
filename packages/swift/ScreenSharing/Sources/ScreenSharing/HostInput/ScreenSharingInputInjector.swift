#if os(macOS)
  import AppKit
  import ScreenSharing

  /// Public Quartz events only, without automation's waits or app activation.
  /// Display bounds are Quartz global points, including negative display origins.
  @MainActor
  public final class ScreenSharingInputInjector {
    public static let eventTag: Int64 = 0x435653435245454E
    private let source = CGEventSource(stateID: .privateState)
    private let displayBounds: CGRect
    private var buttons = Set<UInt8>()
    private let deliver: (CGEvent) -> Void
    public var isAvailable: Bool { source != nil }

    public init(displayBounds: CGRect, deliver: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
      self.deliver = deliver
      self.displayBounds = displayBounds
      source?.userData = Self.eventTag
      source?.localEventsSuppressionInterval = 0
    }

    public func post(_ input: ScreenSharingInputEvent) {
      guard let source else { return }
      switch input {
      case .move(let pointer, let modifiers):
        let button = buttons.sorted().first
        let type: CGEventType =
          button == 0
          ? .leftMouseDragged
          : button == 1
            ? .rightMouseDragged
            : button == 2 ? .otherMouseDragged : .mouseMoved
        emit(
          CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: location(pointer),
            mouseButton: CGMouseButton(rawValue: UInt32(button ?? 0)) ?? .left), modifiers: modifiers)
      case .button(let pointer, let button, let down, let clicks, let modifiers):
        if down { buttons.insert(button) } else { buttons.remove(button) }
        let type: CGEventType =
          button == 0
          ? (down ? .leftMouseDown : .leftMouseUp)
          : button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        let event = CGEvent(
          mouseEventSource: source, mouseType: type, mouseCursorPosition: location(pointer),
          mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        emit(event, modifiers: modifiers)
      case .scroll(let pointer, let x, let y, let modifiers):
        let event = CGEvent(
          scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        event?.location = location(pointer)
        emit(event, modifiers: modifiers)
      case .key(let code, let down, let repeated, let modifiers):
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        emit(event, modifiers: modifiers)
      case .text(let text):
        let units = Array(text.utf16)
        for down in [true, false] {
          let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
          units.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
              event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
          }
          emit(event, modifiers: 0)
        }
      }
    }

    public func location(_ pointer: ScreenSharingPointer) -> CGPoint {
      CGPoint(
        x: displayBounds.minX + min(displayBounds.width - 0.001, pointer.x * displayBounds.width),
        y: displayBounds.minY + min(displayBounds.height - 0.001, pointer.y * displayBounds.height))
    }

    private func emit(_ event: CGEvent?, modifiers: UInt8) {
      let masks: [CGEventFlags] = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn,
      ]
      var flags: CGEventFlags = []
      for (index, mask) in masks.enumerated() where modifiers & (1 << index) != 0 { flags.insert(mask) }
      event?.flags = flags
      event?.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
      if let event { deliver(event) }
    }
  }
#endif
