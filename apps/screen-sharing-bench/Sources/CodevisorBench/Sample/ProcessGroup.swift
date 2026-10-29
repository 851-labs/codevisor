import Darwin
import ScreenSharingBench

struct ProcessGroup {
  private static let commandSeparator: Character = ":"

  let name: String

  func sample() -> [pid_t: BenchProcessUsage] {
    var usages: [pid_t: BenchProcessUsage] = [:]
    for pid in pids() {
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

  private func pids() -> [pid_t] {
    let parts = name.split(separator: Self.commandSeparator, maxSplits: 1).map(String.init)
    let named = BenchProcesses.pids(named: parts[0])
    guard parts.count == 2 else { return named }

    return named.filter { ProcessArguments.of($0).dropFirst().first == parts[1] }
  }
}
