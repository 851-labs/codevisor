struct PreflightCommand: BenchCommand {
  static let name = "preflight"
  static let summary =
    "Check that nobody is sharing into this Mac and record its load, thermal state and CI jobs (--quiet: C5)"
  static let usage =
    "[--allow-screen-sharing-from <address or Bonjour name>,…] [--allow-locked] "
    + "[--quiet [--settle <seconds>] [--settle-limit <seconds>]]"

  let presentsWindows = false
  private let allowedPeers: Set<String>
  private let allowsLocked: Bool
  private let quiet: (settle: Duration, limit: Duration)?

  init(options: BenchOptions) throws {
    let allowed = try options.string("allow-screen-sharing-from")?.split(separator: ",").map(String.init) ?? []
    allowedPeers = PeerAddress.resolve(allowed)
    allowsLocked = try options.flag("allow-locked")
    let settle = try options.integer("settle", default: 60, in: 0...600)
    let limit = try options.integer("settle-limit", default: 300, in: settle...1_800)
    quiet = try options.flag("quiet") ? (.seconds(settle), .seconds(limit)) : nil
  }

  func run() async throws {
    let report = PreflightReport(
      allowedPeers: allowedPeers, peers: try await ScreenSharingPeers.established(), allowsLocked: allowsLocked,
      quiet: try await quietMachine())
    try BenchOutput.print(report)
    guard report.problems.isEmpty else { throw PreflightFailed(problems: report.problems) }
  }

  private func quietMachine() async throws -> QuietMachine? {
    guard let quiet else { return nil }

    return try await QuietMachine.measure(settle: quiet.settle, limit: quiet.limit)
  }
}

struct PreflightFailed: Error, CustomStringConvertible {
  let problems: [String]

  var description: String {
    "not measuring: \(problems.joined(separator: "; "))"
  }
}
