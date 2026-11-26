import Foundation

@MainActor
final class VNCInputTranslator {
  var width: Int
  var height: Int
  private let keys: VNCKeyTranslator
  private var buttons: UInt8 = 0
  private var x: UInt16 = 0
  private var y: UInt16 = 0
  private var vertical: VNCWheel
  private var horizontal: VNCWheel
  private let now: () -> ContinuousClock.Instant

  init(
    width: Int, height: Int, keys: VNCKeyTranslator, scroll: VNCScrollInput = .wheel,
    now: @escaping () -> ContinuousClock.Instant = { .now }
  ) {
    self.width = width
    self.height = height
    self.keys = keys
    self.now = now
    vertical = VNCWheel(input: scroll)
    horizontal = VNCWheel(input: scroll)
  }

  func translate(_ event: ScreenSharingInputEvent) -> [RFBClientMessage] {
    switch event {
    case .move(let pointer, _):
      locate(pointer)
      return [pointerEvent()]
    case .button(let pointer, let button, let down, _, _):
      locate(pointer)
      let mask: UInt8 = [1, 4, 2][Int(min(button, 2))]
      buttons = down ? buttons | mask : buttons & ~mask
      return [pointerEvent()]
    case .scroll(let pointer, let dx, let dy, _):
      locate(pointer)
      let at = now()
      return turns(vertical.clicks(for: dy, at: at), up: 1 << 3, down: 1 << 4)
        + turns(horizontal.clicks(for: dx, at: at), up: 1 << 5, down: 1 << 6)
    case .key(let code, let down, _, let modifiers):
      guard let keysym = keys.keysym(code: code, modifiers: modifiers) else { return [] }
      return [.keyEvent(keysym: keysym, down: down)]
    case .text(let text):
      return Self.withSingleLineBreaks(text).unicodeScalars.flatMap { scalar -> [RFBClientMessage] in
        let keysym = RFBKeysym.keysym(for: scalar)
        return [.keyEvent(keysym: keysym, down: true), .keyEvent(keysym: keysym, down: false)]
      }
    }
  }

  private static func withSingleLineBreaks(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
  }

  func release() -> [RFBClientMessage] {
    guard buttons != 0 else { return [] }
    buttons = 0
    return [pointerEvent()]
  }

  private func turns(_ clicks: Int, up: UInt8, down: UInt8) -> [RFBClientMessage] {
    let wheel = clicks > 0 ? up : down
    return (0..<abs(clicks)).flatMap { _ in
      [RFBClientMessage.pointerEvent(buttons: buttons | wheel, x: x, y: y), pointerEvent()]
    }
  }

  private func locate(_ pointer: ScreenSharingPointer) {
    x = UInt16(clamping: min(width - 1, Int(pointer.x * Double(width))))
    y = UInt16(clamping: min(height - 1, Int(pointer.y * Double(height))))
  }

  private func pointerEvent() -> RFBClientMessage { .pointerEvent(buttons: buttons, x: x, y: y) }
}
