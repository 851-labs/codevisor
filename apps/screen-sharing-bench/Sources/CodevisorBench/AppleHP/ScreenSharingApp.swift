import AppKit

@MainActor
struct ScreenSharingApp {
  static let bundleIdentifier = "com.apple.ScreenSharing"
  private static let fullScreenAttribute = "AXFullScreen"
  private static let pollInterval = Duration.milliseconds(250)

  let application: NSRunningApplication
  private var accessibility: AccessibilityElement { .application(application.processIdentifier) }

  static func connect(to host: String) async throws -> ScreenSharingApp {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
      throw AppleHPError.alreadyRunning
    }
    guard let url = URL(string: "vnc://\(host)"),
      let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { throw AppleHPError.notInstalled }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    return ScreenSharingApp(
      application: try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration))
  }

  func sessionWindow(showing host: String, timeout: Duration) async throws -> AppleHPSession {
    let limit = ContinuousClock.now + timeout
    var choseHighPerformance: Bool?
    while ContinuousClock.now < limit {
      if let window = windows.first(where: { Self.isSession($0, host: host) }) {
        return AppleHPSession(window: window, choseHighPerformance: choseHighPerformance)
      }
      if choseHighPerformance == nil, let chooser = ConnectionTypeChooser.find(in: windows) {
        choseHighPerformance = await chooser.chooseHighPerformance()
        guard choseHighPerformance == true else {
          throw AppleHPError.notHighPerformance(windows.map(WindowDescription.init))
        }
      }

      try await Task.sleep(for: Self.pollInterval)
    }
    throw AppleHPError.noSessionWindow(windows.map(WindowDescription.init))
  }

  func makeFullScreen(_ window: AccessibilityElement, screen: CGRect, timeout: Duration) async throws {
    window.set(Self.fullScreenAttribute, to: true)
    let limit = ContinuousClock.now + timeout
    while window.frame?.size != screen.size || window.bool(Self.fullScreenAttribute) != true {
      guard ContinuousClock.now < limit else { throw AppleHPError.notFullScreen(WindowDescription(window)) }

      try await Task.sleep(for: Self.pollInterval)
    }
  }

  var windows: [AccessibilityElement] {
    accessibility.children(kAXWindowsAttribute)
  }

  var checkedMenuItems: [String] {
    MenuMarks.checked(in: accessibility)
  }

  func quit(timeout: Duration) async {
    application.terminate()
    let limit = ContinuousClock.now + timeout
    while !application.isTerminated, ContinuousClock.now < limit {
      try? await Task.sleep(for: Self.pollInterval)
    }
    if !application.isTerminated { application.forceTerminate() }
  }

  private static func isSession(_ window: AccessibilityElement, host: String) -> Bool {
    let title = letters(window.string(kAXTitleAttribute) ?? "")
    let name = letters(host.split(separator: ".").first.map(String.init) ?? host)
    let sheets = window.children().filter { $0.string(kAXRoleAttribute) == kAXSheetRole }
    return sheets.isEmpty && !name.isEmpty && title.contains(name)
  }

  private static func letters(_ text: String) -> String {
    String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
  }
}
