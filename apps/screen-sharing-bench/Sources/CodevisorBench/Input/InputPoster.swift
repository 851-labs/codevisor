import CoreGraphics
import ScreenSharingBench

enum InputPoster {
  private static let spaceKey: CGKeyCode = 0x31

  static func requireAccess() throws {
    guard CGPreflightPostEventAccess() else { throw InputPosterError.accessibilityNotGranted }
  }

  static func pressSpace() throws -> Int64 {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: spaceKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: spaceKey, keyDown: false)
    else { throw InputPosterError.eventUnavailable }

    return post(down, up)
  }

  static func click(at point: CGPoint) throws -> Int64 {
    guard
      let down = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw InputPosterError.eventUnavailable }

    return post(down, up)
  }

  private static func post(_ down: CGEvent, _ up: CGEvent) -> Int64 {
    let postedNs = BenchMachClock.nowNs()
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return postedNs
  }
}

enum InputPosterError: Error {
  case accessibilityNotGranted
  case eventUnavailable
}
