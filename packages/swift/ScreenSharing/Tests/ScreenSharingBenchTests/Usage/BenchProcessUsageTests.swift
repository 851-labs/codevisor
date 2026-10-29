import Darwin
import ScreenSharingBench
import Testing

struct BenchProcessUsageTests {
  @Test func cpuTimeIsInNanosecondsLikeTheKernelsOwnAccounting() throws {
    let before = Self.ownCPUNs()
    let usage = try BenchProcessUsage.sample(pid: getpid())
    let after = Self.ownCPUNs()

    let roundingNs: Int64 = 1_000
    #expect(usage.cpuNs >= before - roundingNs)
    #expect(usage.cpuNs <= after + roundingNs)
  }

  @Test(arguments: [
    (cpuNs: 500_000_000, energyNj: 2_000_000_000, elapsedNs: 1_000_000_000, cpuPercent: 50.0, powerMw: 2_000.0),
    (cpuNs: 3_000_000_000, energyNj: 250_000_000, elapsedNs: 2_000_000_000, cpuPercent: 150.0, powerMw: 125.0),
  ])
  func loadIsPercentOfOneCoreAndMilliwatts(
    _ case: (cpuNs: Int64, energyNj: Int64, elapsedNs: Int64, cpuPercent: Double, powerMw: Double)
  ) throws {
    let earlier = BenchProcessUsage(sampledNs: 10_000, cpuNs: 7, energyNj: 9)
    let later = BenchProcessUsage(
      sampledNs: 10_000 + `case`.elapsedNs, cpuNs: 7 + `case`.cpuNs, energyNj: 9 + `case`.energyNj)

    let load = try #require(BenchProcessLoad(from: earlier, to: later))

    #expect(load.cpuPercent == `case`.cpuPercent)
    #expect(load.powerMw == `case`.powerMw)
  }

  private static func ownCPUNs() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime)
  }

  private static func nanoseconds(_ time: timeval) -> Int64 {
    Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_usec) * 1_000
  }
}
