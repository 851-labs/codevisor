import AppKit
import Darwin
import ScreenSharingBench

@MainActor
struct QuietMachine: Encodable {
  private static let busyIndexerPercent = 5.0
  private static let loadPoll = Duration.seconds(5)
  private static let quietSamplesInARow = 3
  private static let finder = "com.apple.finder"
  private static let wiredGigabit = "1000baseT"

  let load1: Double
  let settledSeconds: Int
  let reachedSettleLimit: Bool
  let busyIndexers: [String]
  let timeMachinePhase: String
  let softwareUpdateRunning: Bool
  let ethernet: String
  let foregroundApps: [String]
  let problems: [String]

  static func measure(settle: Duration, limit: Duration) async throws -> QuietMachine {
    let clock = ContinuousClock()
    let started = clock.now
    let settled = try await settledActivity(after: settle, until: started + limit, clock: clock)
    return QuietMachine(
      settled, settledSeconds: Int((clock.now - started).components.seconds), limit: limit,
      timeMachinePhase: try await timeMachinePhase(), ethernet: try await ethernet())
  }

  private init(
    _ settled: SettledActivity, settledSeconds: Int, limit: Duration, timeMachinePhase: String, ethernet: String
  ) {
    load1 = settled.last.load1
    self.settledSeconds = settledSeconds
    reachedSettleLimit = !settled.isSettled
    busyIndexers = settled.last.busyIndexers
    self.timeMachinePhase = timeMachinePhase
    softwareUpdateRunning = !BenchProcesses.pids(named: "softwareupdate").isEmpty
    self.ethernet = ethernet
    foregroundApps = Self.foregroundApps()
    problems =
      Self.settleProblems(settled, limit: limit)
      + Self.problems(
        timeMachinePhase: timeMachinePhase, softwareUpdateRunning: softwareUpdateRunning, ethernet: ethernet,
        foregroundApps: foregroundApps)
  }

  private struct SettledActivity {
    let last: QuietActivity
    let isSettled: Bool
  }

  private static func settleProblems(_ settled: SettledActivity, limit: Duration) -> [String] {
    var problems: [String] = []
    let activity = settled.last
    if activity.load1 > QuietActivity.maximumLoad {
      problems.append("the 1-minute load is \(activity.load1), above \(QuietActivity.maximumLoad)")
    }
    if !activity.busyIndexers.isEmpty {
      problems.append("Spotlight is indexing: \(activity.busyIndexers.joined(separator: ", "))")
    }
    if !settled.isSettled, activity.isQuiet {
      problems.append(
        "load and Spotlight weren't quiet for \(quietSamplesInARow) samples in a row within \(limit.components.seconds) s"
      )
    }
    return problems
  }

  private static func problems(
    timeMachinePhase: String, softwareUpdateRunning: Bool, ethernet: String, foregroundApps: [String]
  ) -> [String] {
    var problems: [String] = []
    if timeMachinePhase != "BackupNotRunning" { problems.append("Time Machine is in \(timeMachinePhase)") }
    if softwareUpdateRunning { problems.append("softwareupdate is running") }
    if !ethernet.contains(wiredGigabit) { problems.append("en0 is not up at \(wiredGigabit): \(ethernet)") }
    if !foregroundApps.isEmpty { problems.append("other apps are open: \(foregroundApps.joined(separator: ", "))") }
    return problems
  }

  private static func settledActivity(
    after settle: Duration, until deadline: ContinuousClock.Instant, clock: ContinuousClock
  ) async throws -> SettledActivity {
    try await clock.sleep(for: settle)
    var activity = QuietActivity(load1: loadAverage(), busyIndexers: try await busyIndexers())
    var quietInARow = activity.isQuiet ? 1 : 0
    while quietInARow < quietSamplesInARow, clock.now + loadPoll <= deadline {
      try await clock.sleep(for: loadPoll)
      activity = QuietActivity(load1: loadAverage(), busyIndexers: try await busyIndexers())
      quietInARow = activity.isQuiet ? quietInARow + 1 : 0
    }
    return SettledActivity(last: activity, isSettled: quietInARow >= quietSamplesInARow)
  }

  private static func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 1)
    return getloadavg(&loads, 1) == 1 ? loads[0] : -1
  }

  static func busyIndexers() async throws -> [String] {
    let output = try await CommandOutput.of("/bin/ps", ["-Ao", "pcpu=,comm="])
    return output.split(separator: "\n").compactMap(busyIndexer)
  }

  private static func busyIndexer(_ line: Substring) -> String? {
    let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard fields.count == 2, let percent = Double(fields[0]), percent > busyIndexerPercent else { return nil }

    let name = fields[1].split(separator: "/").last.map(String.init) ?? ""
    guard name == "mds_stores" || name.hasPrefix("mdworker") else { return nil }

    return "\(name) \(percent)%"
  }

  private static func timeMachinePhase() async throws -> String {
    try await CommandOutput.of("/usr/bin/tmutil", ["currentphase"]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func ethernet() async throws -> String {
    let output = try await CommandOutput.of("/sbin/ifconfig", ["en0"])
    let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    return lines.filter { $0.hasPrefix("media:") || $0.hasPrefix("status:") }.joined(separator: "; ")
  }

  private static func foregroundApps() -> [String] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != finder && $0 != .current }
      .compactMap(\.localizedName)
      .sorted()
  }
}
