import Darwin

public struct BenchProcessUsage: Sendable, Equatable {
  public let sampledNs: Int64
  public let cpuNs: Int64
  public let energyNj: Int64

  public init(sampledNs: Int64, cpuNs: Int64, energyNj: Int64) {
    self.sampledNs = sampledNs
    self.cpuNs = cpuNs
    self.energyNj = energyNj
  }

  public static func sample(pid: pid_t) throws -> BenchProcessUsage {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard result == 0 else { throw BenchProcessUsageError.unavailable(pid: pid, errno: errno) }

    return BenchProcessUsage(
      sampledNs: BenchMachClock.nowNs(),
      cpuNs: BenchMachClock.nanoseconds(fromTicks: info.ri_user_time + info.ri_system_time),
      energyNj: Int64(info.ri_energy_nj))
  }
}

public enum BenchProcessUsageError: Error, Equatable {
  case unavailable(pid: pid_t, errno: Int32)
}
