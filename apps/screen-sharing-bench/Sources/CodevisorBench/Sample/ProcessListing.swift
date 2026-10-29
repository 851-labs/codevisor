import Foundation
import ScreenSharingBench

struct ProcessListing {
  private struct Entry {
    let pid: pid_t
    let name: String
    let cpuNs: Int64
  }

  private static let nanosecondsPerSecond = 1_000_000_000.0
  private static let secondsPerUnit = [1.0, 60, 3_600]

  let sampledNs: Int64
  private let entries: [Entry]

  static func capture() throws -> ProcessListing {
    let startNs = BenchMachClock.nowNs()
    let output = try ps()
    let endNs = BenchMachClock.nowNs()
    return ProcessListing(
      sampledNs: startNs + (endNs - startNs) / 2, entries: output.split(separator: "\n").compactMap(entry))
  }

  func pids(named name: String) -> [pid_t] {
    entries.filter { $0.name == name }.map(\.pid)
  }

  func cpuNs(of pid: pid_t) -> Int64? {
    entries.first { $0.pid == pid }?.cpuNs
  }

  private static func ps() throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,time=,comm="]
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ProcessListingError.psFailed(process.terminationStatus) }

    return output
  }

  private static func entry(_ line: Substring) -> Entry? {
    let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard fields.count == 3, let pid = pid_t(fields[0]), let seconds = seconds(fields[1]) else { return nil }

    let name = fields[2].split(separator: "/").last.map(String.init) ?? String(fields[2])
    return Entry(pid: pid, name: name, cpuNs: Int64(seconds * nanosecondsPerSecond))
  }

  private static func seconds(_ text: Substring) -> Double? {
    let units = text.split(separator: ":").reversed().compactMap { Double($0) }
    guard !units.isEmpty, units.count <= secondsPerUnit.count, units.count == text.split(separator: ":").count
    else { return nil }

    return zip(units, secondsPerUnit).map(*).reduce(0, +)
  }
}

enum ProcessListingError: Error, CustomStringConvertible {
  case psFailed(Int32)

  var description: String {
    switch self {
    case .psFailed(let status): "/bin/ps exited with \(status)"
    }
  }
}
