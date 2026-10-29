import Darwin
import Foundation
import ScreenSharingBench

enum UsageSeconds {
  static func write(
    counters: [BenchInterfaceCounters], groups: [ProcessGroup], snapshots: [[[pid_t: BenchProcessUsage]]],
    to path: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines = try lines(counters: counters, groups: groups, snapshots: snapshots).map { try encoder.encode($0) }
    try Data(lines.joined(separator: Data("\n".utf8)) + Data("\n".utf8)).write(to: URL(fileURLWithPath: path))
  }

  private static func lines(
    counters: [BenchInterfaceCounters], groups: [ProcessGroup], snapshots: [[[pid_t: BenchProcessUsage]]]
  ) -> [BenchUsageSecond] {
    counters.indices.dropFirst().map { index in
      let rate = BenchInterfaceRate(from: counters[index - 1], to: counters[index])
      return BenchUsageSecond(
        endNs: counters[index].sampledNs, intervalNs: counters[index].sampledNs - counters[index - 1].sampledNs,
        receivedMbps: rate?.receivedMbps, sentMbps: rate?.sentMbps,
        processes: processes(groups, snapshots, second: index))
    }
  }

  private static func processes(
    _ groups: [ProcessGroup], _ snapshots: [[[pid_t: BenchProcessUsage]]], second index: Int
  ) -> [String: BenchUsageSecond.Process] {
    var processes: [String: BenchUsageSecond.Process] = [:]
    for (group, samples) in zip(groups, snapshots) {
      guard let load = ProcessGroup.load(from: samples[index - 1], to: samples[index]) else { continue }

      processes[group.name] = BenchUsageSecond.Process(cpuPct: load.cpuPercent, powerMw: load.powerMw)
    }
    return processes
  }
}
