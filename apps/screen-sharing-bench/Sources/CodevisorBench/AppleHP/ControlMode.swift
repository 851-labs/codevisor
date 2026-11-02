import ApplicationServices

enum ControlMode: String, Encodable {
  case control
  case observe
  case unknown

  private static let leaveControlTitle = "Switch to Observe Mode"
  private static let enterControlTitle = "Switch to Control Mode"
  private static let pollInterval = Duration.milliseconds(250)

  static func read(in application: AccessibilityElement) -> ControlMode {
    if menuItem(titled: leaveControlTitle, in: application) != nil { return .control }
    if menuItem(titled: enterControlTitle, in: application) != nil { return .observe }

    return .unknown
  }

  static func enter(in application: AccessibilityElement, timeout: Duration) async -> ControlMode {
    menuItem(titled: enterControlTitle, in: application)?.press()
    let limit = ContinuousClock.now + timeout
    while read(in: application) != .control, ContinuousClock.now < limit {
      try? await Task.sleep(for: pollInterval)
    }
    return read(in: application)
  }

  private static func menuItem(titled title: String, in application: AccessibilityElement) -> AccessibilityElement? {
    guard let bar = application.element(kAXMenuBarAttribute) else { return nil }

    return bar.children().lazy.flatMap { $0.children() }.flatMap { $0.children() }
      .first { $0.string(kAXTitleAttribute) == title }
  }
}
