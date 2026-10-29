import Darwin
import ScreenSharingBench

struct ProcessGroup {
  let name: String

  func sample() -> [pid_t: BenchProcessUsage] {
    var usages: [pid_t: BenchProcessUsage] = [:]
    for pid in BenchProcesses.pids(named: name) {
      usages[pid] = try? BenchProcessUsage.sample(pid: pid)
    }
    return usages
  }

  static func load(from earlier: [pid_t: BenchProcessUsage], to later: [pid_t: BenchProcessUsage]) -> BenchProcessLoad?
  {
    let loads = later.compactMap { pid, usage in earlier[pid].flatMap { BenchProcessLoad(from: $0, to: usage) } }
    guard !loads.isEmpty else { return nil }

    return BenchProcessLoad(
      cpuPercent: loads.map(\.cpuPercent).reduce(0, +), powerMw: loads.map(\.powerMw).reduce(0, +))
  }
}
