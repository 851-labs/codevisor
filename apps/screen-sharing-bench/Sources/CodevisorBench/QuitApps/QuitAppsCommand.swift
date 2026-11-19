import AppKit

struct QuitAppsCommand: BenchCommand {
  static let name = "quit-apps"
  static let summary =
    "Ask the apps with these bundle IDs to quit as their Quit menu item does, wait for them, and note which to reopen"
  static let usage = "--bundle-ids <id>,<id>… --record <file> [--timeout 60]"

  private static let timeouts = 1...600
  private static let poll = Duration.milliseconds(200)

  let presentsWindows = false
  private let bundleIDs: [String]
  private let record: ReopenRecord
  private let timeout: Duration

  init(options: BenchOptions) throws {
    bundleIDs = try options.requiredString("bundle-ids").split(separator: ",").map(String.init)
    record = ReopenRecord(path: try options.requiredString("record"))
    timeout = .seconds(try options.integer("timeout", default: 60, in: Self.timeouts))
  }

  func run() async throws {
    let apps = bundleIDs.flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
    try record.add(apps.compactMap { $0.bundleURL?.path })

    let asked = apps.map { QuitApp($0, asked: $0.terminate()) }
    let stillRunning = try await running(asked, after: timeout)
    try BenchOutput.print(QuitAppsResult(quit: asked.filter { !stillRunning.contains($0) }, stillRunning: stillRunning))
    guard stillRunning.isEmpty else { throw QuitAppsFailed(apps: stillRunning, timeout: timeout) }
  }

  private func running(_ apps: [QuitApp], after timeout: Duration) async throws -> [QuitApp] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while apps.contains(where: \.isRunning), clock.now < deadline {
      try await clock.sleep(for: Self.poll)
    }
    return apps.filter(\.isRunning)
  }
}

struct QuitAppsResult: Encodable {
  let quit: [QuitApp]
  let stillRunning: [QuitApp]
}

struct QuitAppsFailed: Error, CustomStringConvertible {
  let apps: [QuitApp]
  let timeout: Duration

  var description: String {
    "still running \(timeout.components.seconds) s after being asked to quit: \(apps.map(\.name).joined(separator: ", "))"
  }
}
