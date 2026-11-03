import Foundation

final class HostLabChild: @unchecked Sendable {
  private let process: Process

  private init(process: Process) {
    self.process = process
  }

  static func launch(_ arguments: [String]) throws -> HostLabChild {
    guard let executable = Bundle.main.executableURL else {
      throw BenchUsageError(message: "no bench executable to launch")
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.filter {
      $0.key != BenchProcessFiles.pidFileVariable && $0.key != BenchProcessFiles.statusFileVariable
    }
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    return HostLabChild(process: process)
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { [process] in
        process.waitUntilExit()
        continuation.resume(returning: process.terminationStatus)
      }
    }
  }

  func stop(after delay: Duration) {
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(delay.components.seconds))) { [self] in stop() }
  }

  func stop() {
    guard process.isRunning else { return }

    process.terminate()
  }
}
