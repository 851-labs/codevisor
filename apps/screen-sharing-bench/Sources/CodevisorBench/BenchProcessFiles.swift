import Foundation

enum BenchProcessFiles {
  static let pidFileVariable = "CODEVISOR_BENCH_PID_FILE"
  static let statusFileVariable = "CODEVISOR_BENCH_STATUS_FILE"

  static func recordStart() {
    write("\(getpid())", toFileIn: pidFileVariable)
  }

  static func finish(with status: BenchExitStatus) -> Never {
    write("\(status.rawValue)", toFileIn: statusFileVariable)
    exit(status.rawValue)
  }

  private static func write(_ value: String, toFileIn variable: String) {
    guard let path = ProcessInfo.processInfo.environment[variable] else { return }

    do {
      try "\(value)\n".write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
      BenchConsole.error("Could not write \(variable) (\(path)): \(error)")
    }
  }
}
