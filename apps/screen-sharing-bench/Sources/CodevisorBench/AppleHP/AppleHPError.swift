enum AppleHPError: Error, CustomStringConvertible {
  case alreadyRunning
  case notInstalled
  case noSessionWindow([WindowDescription])
  case notFullScreen(WindowDescription)
  case notTrusted
  case notHighPerformance([WindowDescription])

  var description: String {
    switch self {
    case .alreadyRunning: "Screen Sharing.app is already running; quit it so the bench owns the session"
    case .notInstalled: "Screen Sharing.app is not installed"
    case .noSessionWindow(let windows): "no session window appeared; windows: \(Self.describe(windows))"
    case .notFullScreen(let window): "the session window did not go full screen: \(Self.describe([window]))"
    case .notTrusted: "CodevisorBench needs Accessibility to drive Screen Sharing.app"
    case .notHighPerformance(let windows):
      "could not select High Performance in the connection type sheet: \(Self.describe(windows))"
    }
  }

  private static func describe(_ windows: [WindowDescription]) -> String {
    windows.map { "\($0.title ?? "untitled") [\($0.subrole ?? "?")] \($0.frame ?? "") \($0.texts)" }
      .joined(separator: "; ")
  }
}
