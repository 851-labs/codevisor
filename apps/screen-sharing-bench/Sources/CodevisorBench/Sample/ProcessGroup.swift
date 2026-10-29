import Darwin
import ScreenSharingBench

struct ProcessGroup {
  struct Load {
    let cpuPercent: Double
    let powerMw: Double?
  }

  private static let commandSeparator: Character = ":"
  private static let percent = 100.0
  private static let milliwattsPerNanojoulePerNs = 1_000.0

  let name: String

  func sample(_ listing: ProcessListing) -> [pid_t: ProcessReading] {
    var readings: [pid_t: ProcessReading] = [:]
    for pid in pids(listing) {
      readings[pid] = Self.reading(pid, listing: listing)
    }
    return readings
  }

  static func load(from earlier: [pid_t: ProcessReading], to later: [pid_t: ProcessReading]) -> Load? {
    let pairs = later.compactMap { pid, reading in earlier[pid].map { (earlier: $0, later: reading) } }
      .filter { $0.later.sampledNs > $0.earlier.sampledNs }
    guard !pairs.isEmpty else { return nil }

    let cpu = pairs.map { Double($0.later.cpuNs - $0.earlier.cpuNs) / elapsedNs($0) * percent }
    let power = pairs.map { pair in
      pair.later.energyNj.flatMap { later in
        pair.earlier.energyNj.map { Double(later - $0) / elapsedNs(pair) * milliwattsPerNanojoulePerNs }
      }
    }
    return Load(
      cpuPercent: cpu.reduce(0, +), powerMw: power.contains(nil) ? nil : power.compactMap { $0 }.reduce(0, +))
  }

  private static func elapsedNs(_ pair: (earlier: ProcessReading, later: ProcessReading)) -> Double {
    Double(pair.later.sampledNs - pair.earlier.sampledNs)
  }

  private static func reading(_ pid: pid_t, listing: ProcessListing) -> ProcessReading? {
    if let usage = try? BenchProcessUsage.sample(pid: pid) {
      return ProcessReading(sampledNs: usage.sampledNs, cpuNs: usage.cpuNs, energyNj: usage.energyNj)
    }
    return listing.cpuNs(of: pid).map { ProcessReading(sampledNs: listing.sampledNs, cpuNs: $0, energyNj: nil) }
  }

  private func pids(_ listing: ProcessListing) -> [pid_t] {
    let parts = name.split(separator: Self.commandSeparator, maxSplits: 1).map(String.init)
    let named = listing.pids(named: parts[0])
    guard parts.count == 2 else { return named }

    return named.filter { ProcessArguments.of($0).dropFirst().first == parts[1] }
  }
}
