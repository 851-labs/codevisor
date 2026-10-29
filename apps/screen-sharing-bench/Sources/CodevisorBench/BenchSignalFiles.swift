import Foundation

struct BenchSignalFiles: Sendable {
  static let usage = "[--ready-file <path>] [--stop-file <path>]"
  private static let pollInterval = Duration.milliseconds(250)

  let ready: String?
  let stop: String?

  @MainActor
  init(options: BenchOptions) throws {
    ready = try options.string("ready-file")
    stop = try options.string("stop-file")
  }

  func markReady(_ state: String) throws {
    guard let ready else { return }

    try "\(state)\n".write(toFile: ready, atomically: true, encoding: .utf8)
  }

  func waitForStop(until deadline: ContinuousClock.Instant) async {
    while !Task.isCancelled, ContinuousClock.now < deadline, !stopRequested {
      try? await Task.sleep(for: Self.pollInterval)
    }
  }

  private var stopRequested: Bool {
    stop.map(FileManager.default.fileExists(atPath:)) ?? false
  }
}
