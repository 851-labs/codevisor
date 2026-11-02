import AppKit
import ScreenSharingBench

@MainActor
struct InputInjection {
  private(set) var events: [BenchInputEvent] = []
  private(set) var frontmostApps: [String: Int] = [:]

  mutating func post(_ kind: BenchInputKind, clickingAt target: CGPoint) throws {
    frontmostApps[Self.frontmostApp, default: 0] += 1
    let postedNs =
      switch kind {
      case .key: try InputPoster.pressSpace()
      case .click: try InputPoster.click(at: target)
      }
    events.append(BenchInputEvent(kind: kind, postedNs: postedNs))
  }

  private static var frontmostApp: String {
    let app = NSWorkspace.shared.frontmostApplication
    return app?.bundleIdentifier ?? app?.localizedName ?? "none"
  }
}
