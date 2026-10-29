import Darwin
import ScreenSharingBench

struct SampleResult: Encodable {
  struct Process: Encodable {
    let name: String
    let pidsSeen: [Int32]
    let cpuPct: BenchDistribution?
    let powerMw: BenchDistribution?

    init(name: String, snapshots: [[pid_t: ProcessReading]]) {
      let loads = zip(snapshots, snapshots.dropFirst()).compactMap(ProcessGroup.load(from:to:))
      self.name = name
      pidsSeen = Set(snapshots.flatMap(\.keys)).sorted()
      cpuPct = BenchDistribution(loads.map(\.cpuPercent))
      powerMw = loads.contains { $0.powerMw == nil } ? nil : BenchDistribution(loads.compactMap(\.powerMw))
    }
  }

  let intervalMs = 1_000
  let interface: String
  let receivedMbps: BenchDistribution?
  let sentMbps: BenchDistribution?
  let processes: [Process]

  init(
    interface: String, counters: [BenchInterfaceCounters], groups: [ProcessGroup],
    snapshots: [[[pid_t: ProcessReading]]]
  ) {
    let rates = zip(counters, counters.dropFirst()).compactMap(BenchInterfaceRate.init(from:to:))
    self.interface = interface
    receivedMbps = BenchDistribution(rates.map(\.receivedMbps))
    sentMbps = BenchDistribution(rates.map(\.sentMbps))
    processes = zip(groups, snapshots).map { Process(name: $0.name, snapshots: $1) }
  }
}
