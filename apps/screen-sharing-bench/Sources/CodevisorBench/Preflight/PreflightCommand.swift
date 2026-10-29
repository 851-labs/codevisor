struct PreflightCommand: BenchCommand {
  static let name = "preflight"
  static let summary = "Check that nobody is sharing into this Mac and record its load, thermal state and CI jobs"
  static let usage = "[--allow-screen-sharing-from <address or Bonjour name>,…]"

  let presentsWindows = false
  private let allowedPeers: Set<String>

  init(options: BenchOptions) throws {
    let allowed = try options.string("allow-screen-sharing-from")?.split(separator: ",").map(String.init) ?? []
    allowedPeers = PeerAddress.resolve(allowed)
  }

  func run() async throws {
    let report = PreflightReport(allowedPeers: allowedPeers, peers: try await ScreenSharingPeers.established())
    try BenchOutput.print(report)
    guard report.problems.isEmpty else { throw PreflightFailed(problems: report.problems) }
  }
}

struct PreflightFailed: Error, CustomStringConvertible {
  let problems: [String]

  var description: String {
    "not measuring: \(problems.joined(separator: "; "))"
  }
}
