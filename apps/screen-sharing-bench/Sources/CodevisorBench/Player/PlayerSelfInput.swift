import AppKit

@MainActor
enum PlayerSelfInput {
  static func start(hz: Int, window: NSWindow) -> Task<Void, Never>? {
    guard hz > 0 else { return nil }

    return Task {
      while true {
        do {
          try await Task.sleep(for: .seconds(1.0 / Double(hz)))
        } catch {
          return
        }
        post(to: window)
      }
    }
  }

  private static func post(to window: NSWindow) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
        isARepeat: false, keyCode: 0)
    else { return }

    NSApplication.shared.postEvent(event, atStart: false)
  }
}
