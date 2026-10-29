import Darwin
import ScreenSharingBench

struct SampleCommand: BenchCommand {
  static let name = "sample"
  static let summary = "Sample processes' CPU and power and an interface's bitrate once a second"
  static let usage =
    "[--duration <seconds>] [--interface en0] [--processes <name>|<name>:<bench command>,…] [--output <file.jsonl>]"

  private static let durations = 1...7200
  private static let interval = Duration.seconds(1)

  let presentsWindows = false
  private let duration: Int
  private let interface: String
  private let processNames: [String]
  private let output: String?

  init(options: BenchOptions) throws {
    duration = try options.integer("duration", default: 10, in: Self.durations)
    interface = try options.string("interface", default: "en0")
    processNames = try options.string("processes")?.split(separator: ",").map(String.init) ?? []
    output = try options.string("output")
  }

  func run() async throws {
    let groups = processNames.map(ProcessGroup.init(name:))
    var counters: [BenchInterfaceCounters] = []
    var snapshots = [[[pid_t: BenchProcessUsage]]](repeating: [], count: groups.count)
    let clock = ContinuousClock()
    var next = clock.now
    for _ in 0...duration {
      counters.append(try BenchInterfaceCounters.sample(interface: interface))
      for (index, group) in groups.enumerated() { snapshots[index].append(group.sample()) }
      next += Self.interval
      try await clock.sleep(until: next)
    }
    if let output { try UsageSeconds.write(counters: counters, groups: groups, snapshots: snapshots, to: output) }
    try BenchOutput.print(SampleResult(interface: interface, counters: counters, groups: groups, snapshots: snapshots))
  }
}
