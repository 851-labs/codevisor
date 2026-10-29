import CoreGraphics
import ScreenSharingBench

enum KeyPoster {
  private static let spaceKey: CGKeyCode = 0x31

  static func requireAccess() throws {
    guard CGPreflightPostEventAccess() else { throw KeyPosterError.accessibilityNotGranted }
  }

  static func pressSpace() throws -> Int64 {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: spaceKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: spaceKey, keyDown: false)
    else { throw KeyPosterError.eventUnavailable }

    let postedNs = BenchMachClock.nowNs()
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return postedNs
  }
}

enum KeyPosterError: Error {
  case accessibilityNotGranted
  case eventUnavailable
}
