#if os(macOS)
  import ScreenSharing
  import Foundation

  /// The session owns this controller and closes it before stopping media.
  /// No input is accepted until the active peer explicitly acquires control.
  @MainActor
  public final class ScreenSharingHostControl {
    public private(set) var lease: UUID?
    public private(set) var heldKeys = Set<UInt16>()
    public private(set) var heldButtons = Set<UInt8>()
    private var pointer = ScreenSharingPointer(x: 0.5, y: 0.5)
    private var modifiers: UInt8 = 0
    private var sequence: UInt64 = 0
    private var deadline: TimeInterval = 0
    private let now: () -> TimeInterval
    private let availability: () -> String?
    private let inject: (ScreenSharingInputEvent) -> Void
    private let send: (ScreenSharingControlMessage) -> Bool
    public var onChanged: ((Bool) -> Void)?

    public init(
      now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
      availability: @escaping () -> String?, inject: @escaping (ScreenSharingInputEvent) -> Void,
      send: @escaping (ScreenSharingControlMessage) -> Bool
    ) {
      self.now = now; self.availability = availability; self.inject = inject; self.send = send
    }

    public func receive(_ message: ScreenSharingControlMessage) {
      checkDeadline()
      switch message {
      case .request(let request):
        if let reason = availability() { _ = send(.denied(request: request, reason: reason)); return }
        guard lease == nil else {
          _ = send(.denied(request: request, reason: "Control is already active.")); return
        }
        let id = UUID()
        lease = id; deadline = now() + 3; sequence = 0
        onChanged?(true)
        if !send(.grant(request: request, lease: id)) { revoke("The control channel closed.") }
      case .release(let id):
        if lease == id { revoke("Control released.") }
      case .heartbeat(let id):
        guard lease == id else { return }
        if let reason = availability() { revoke(reason); return }
        deadline = now() + 3
      case .input(let id, let next, let event):
        guard lease == id, next > sequence else { return }
        if let reason = availability() { revoke(reason); return }
        guard event.isValid else { revoke("Invalid input received."); return }
        sequence = next
        apply(event)
      default: break
      }
    }

    public func checkDeadline() {
      if lease != nil, now() >= deadline { revoke("Control timed out. Request control again.") }
    }

    public func revoke(_ reason: String) {
      guard let previous = lease else { return }
      // Invalidate first: reentrant callbacks and queued packets cannot inject.
      lease = nil
      // Release ordinary keys before modifiers; each source tracks only its own input.
      let modifierCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
      let keys = heldKeys.sorted { a, b in
        if modifierCodes.contains(a) != modifierCodes.contains(b) { return !modifierCodes.contains(a) }
        return a < b
      }
      for key in keys {
        modifiers &= ~Self.modifier(for: key)
        inject(.key(code: key, down: false, repeatKey: false, modifiers: modifiers))
      }
      for button in heldButtons.sorted() {
        inject(.button(pointer, button: button, down: false, clicks: 1, modifiers: 0))
      }
      heldKeys = []; heldButtons = []; modifiers = 0
      onChanged?(false)
      _ = send(.revoked(lease: previous, reason: reason))
    }

    private func apply(_ event: ScreenSharingInputEvent) {
      switch event {
      case .key(let code, let down, let repeated, let flags):
        if down {
          guard repeated ? heldKeys.contains(code) : !heldKeys.contains(code) else { return }
          heldKeys.insert(code)
        } else {
          guard heldKeys.remove(code) != nil else { return }
        }
        modifiers = flags
      case .button(let point, let button, let down, _, let flags):
        if down {
          guard heldButtons.insert(button).inserted else { return }
        } else {
          guard heldButtons.remove(button) != nil else { return }
        }
        pointer = point; modifiers = flags
      case .move(let point, let flags), .scroll(let point, _, _, let flags):
        pointer = point; modifiers = flags
      case .text:
        guard heldKeys.isEmpty, heldButtons.isEmpty else { return }
      }
      inject(event)
    }

    private static func modifier(for key: UInt16) -> UInt8 {
      switch key {
      case 56, 60: 1
      case 59, 62: 2
      case 58, 61: 4
      case 54, 55: 8
      case 63: 32
      default: 0
      }
    }
  }
#endif
