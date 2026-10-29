public struct BenchUsageSummary: Sendable, Equatable {
  private static let bitsPerByte = 8.0
  private static let nanosecondsPerSecond = 1_000_000_000.0

  public let cpuPct: BenchResult.ProcessUsage?
  public let powerMw: Double?
  public let receivedMbps: BenchResult.Bitrate?

  public init(_ seconds: [BenchUsageSecond], in window: BenchSharingWindow, processes: Set<String>) {
    let inWindow = seconds.filter { window.contains($0.endNs - $0.intervalNs) && window.contains($0.endNs) }
    let sampled = inWindow.filter { !$0.processes.keys.filter(processes.contains).isEmpty }
    let cpu = BenchDistribution(sampled.map { $0.cpuPct(of: processes) })
    cpuPct = cpu.map { BenchResult.ProcessUsage(p50: $0.p50, p95: $0.p95) }
    let powers = sampled.map { $0.powerMw(of: processes) }
    powerMw = powers.contains(nil) ? nil : BenchDistribution(powers.compactMap { $0 })?.p50
    receivedMbps = Self.bitrate(inWindow.filter { $0.receivedMbps != nil })
  }

  private static func bitrate(_ seconds: [BenchUsageSecond]) -> BenchResult.Bitrate? {
    guard let rates = BenchDistribution(seconds.compactMap(\.receivedMbps)) else { return nil }

    let megabits = seconds.map { ($0.receivedMbps ?? 0) * Double($0.intervalNs) / nanosecondsPerSecond }
    return BenchResult.Bitrate(
      p50: rates.p50, p95: rates.p95, max: rates.max, totalMb: megabits.reduce(0, +) / bitsPerByte)
  }
}
