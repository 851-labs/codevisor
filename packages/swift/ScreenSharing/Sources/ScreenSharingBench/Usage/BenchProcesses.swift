import Darwin

public enum BenchProcesses {
  public static func pids(named name: String) -> [pid_t] {
    allPids().filter { processName(of: $0) == name }
  }

  private static func allPids() -> [pid_t] {
    let capacity = Int(proc_listallpids(nil, 0)) + headroom
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = pids.withUnsafeMutableBytes { Int(proc_listallpids($0.baseAddress, Int32($0.count))) }
    return Array(pids.prefix(max(count, 0)))
  }

  private static func processName(of pid: pid_t) -> String? {
    var name = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
    guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }

    return String(decoding: name.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }

  private static let headroom = 64
}
