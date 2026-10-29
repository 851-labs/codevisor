import AppKit

struct PlayerCommand: BenchCommand {
  static let name = "player"
  static let summary = "Draw a scripted scene full screen (stub: a blank window)"
  static let usage = "[--duration <seconds>]"

  private static let durations = 1...3600

  private let duration: Int

  init(options: BenchOptions) throws {
    duration = try options.integer("duration", default: 5, in: Self.durations)
  }

  func run() async throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.activate()
    application.presentationOptions = [.hideDock, .hideMenuBar]
    let window = PlayerStubWindow(screen: NSScreen.main)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    try await Task.sleep(for: .seconds(duration))
    print("player stub ran for \(duration) s on a \(window.frame.size.width)×\(window.frame.size.height) pt window")
  }
}
