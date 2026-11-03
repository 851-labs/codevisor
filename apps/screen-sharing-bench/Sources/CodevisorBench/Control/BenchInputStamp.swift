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

  init(_ event: ScreenSharingInputEvent, ns: Int64) {
    (kind, down) =
      switch event {
      case .key(_, let down, _, _): (.key, down)
      case .button(_, _, let down, _, _): (.click, down)
      case .move: (.move, nil)
      case .scroll: (.scroll, nil)
      case .text: (.text, nil)
      }
    self.ns = ns
    eventAgeMs = nil
  }

  init?(_ event: NSEvent, ns: Int64) {
    switch event.type {
    case .keyDown: kind = .key
    case .leftMouseDown: kind = .click
    default: return nil
    }
    down = true
    self.ns = ns
    eventAgeMs = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
  }
}
