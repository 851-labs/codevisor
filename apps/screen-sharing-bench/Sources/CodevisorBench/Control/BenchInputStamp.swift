import AppKit
import ScreenSharing

struct BenchInputStamp: Encodable {
  enum Kind: String, Encodable {
    case key, click, move, scroll, text
  }

  let kind: Kind
  let down: Bool?
  let ns: Int64
  let eventAgeMs: Double?
  var mouseCoalescing: Bool?

  init(_ event: ScreenSharingInputEvent, ns: Int64, source: NSEvent?) {
    let (kind, down): (Kind, Bool?) =
      switch event {
      case .key(_, let down, _, _): (.key, down)
      case .button(_, _, let down, _, _): (.click, down)
      case .move: (.move, nil)
      case .scroll: (.scroll, nil)
      case .text: (.text, nil)
      }
    self.kind = kind
    self.down = down
    self.ns = ns
    eventAgeMs = source.flatMap { Self.ageMs(of: $0, matching: kind) }
  }

  init?(_ event: NSEvent, ns: Int64) {
    let kind: Kind
    switch event.type {
    case .keyDown: kind = .key
    case .leftMouseDown: kind = .click
    default: return nil
    }
    self.kind = kind
    down = true
    self.ns = ns
    eventAgeMs = Self.ageMs(of: event, matching: kind)
  }

  private static func ageMs(of event: NSEvent, matching kind: Kind) -> Double? {
    let matches =
      switch kind {
      case .key: [.keyDown, .keyUp].contains(event.type)
      case .click: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type)
      default: false
      }
    guard matches else { return nil }

    return (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
  }
}
