#if os(macOS)
  import ScreenSharing
  import Foundation

  /// Viewer input events to RFB PointerEvent/KeyEvent messages: normalized
  /// pointer coordinates scaled to the framebuffer, a running button mask,
  /// scroll deltas as wheel-button clicks, and key codes through the key
  /// translator. Runs at input rate on the main actor.
  @MainActor
  final class VNCInputTranslator {
    /// Pixels of scroll delta per wheel click sent.
    static let pixelsPerWheelClick = 20.0
    var width: Int
    var height: Int
    private let keys: VNCKeyTranslator
    private var buttons: UInt8 = 0
    private var x: UInt16 = 0
    private var y: UInt16 = 0

    init(width: Int, height: Int, keys: VNCKeyTranslator) {
      self.width = width
      self.height = height
      self.keys = keys
    }

    func translate(_ event: ScreenSharingInputEvent) -> [RFBClientMessage] {
      switch event {
      case .move(let pointer, _):
        locate(pointer)
        return [pointerEvent()]
      case .button(let pointer, let button, let down, _, _):
        locate(pointer)
        let mask: UInt8 = [1, 4, 2][Int(min(button, 2))]  // left, right, middle
        buttons = down ? buttons | mask : buttons & ~mask
        return [pointerEvent()]
      case .scroll(let pointer, let dx, let dy, _):
        locate(pointer)
        var messages: [RFBClientMessage] = []
        for (delta, up, down) in [(dy, UInt8(1 << 3), UInt8(1 << 4)), (dx, UInt8(1 << 5), UInt8(1 << 6))]
        where delta != 0 {
          let clicks = max(1, min(8, Int((Double(abs(delta)) / Self.pixelsPerWheelClick).rounded())))
          let wheel = delta > 0 ? up : down
          for _ in 0..<clicks {
            messages.append(.pointerEvent(buttons: buttons | wheel, x: x, y: y))
            messages.append(pointerEvent())
          }
        }
        return messages
      case .key(let code, let down, _, let modifiers):
        guard let keysym = keys.keysym(code: code, modifiers: modifiers) else { return [] }
        return [.keyEvent(keysym: keysym, down: down)]
      case .text(let text):
        return text.unicodeScalars.flatMap { scalar -> [RFBClientMessage] in
          let keysym = RFBKeysym.keysym(for: scalar)
          return [.keyEvent(keysym: keysym, down: true), .keyEvent(keysym: keysym, down: false)]
        }
      }
    }

    /// Control ended: release whatever is held so the server never sees a stuck button.
    func release() -> [RFBClientMessage] {
      guard buttons != 0 else { return [] }
      buttons = 0
      return [pointerEvent()]
    }

    private func locate(_ pointer: ScreenSharingPointer) {
      x = UInt16(clamping: min(width - 1, Int(pointer.x * Double(width))))
      y = UInt16(clamping: min(height - 1, Int(pointer.y * Double(height))))
    }

    private func pointerEvent() -> RFBClientMessage { .pointerEvent(buttons: buttons, x: x, y: y) }
  }
#endif
