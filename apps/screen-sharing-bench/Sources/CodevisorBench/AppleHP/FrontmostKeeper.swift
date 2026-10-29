import AppKit

@MainActor
enum FrontmostKeeper {
  private static let pollInterval = Duration.milliseconds(250)

  static func hold(
    _ application: NSRunningApplication, until deadline: ContinuousClock.Instant, signals: BenchSignalFiles
  )
    async -> Int
  {
    let keeper = Task { await keep(application) }
    await signals.waitForStop(until: deadline)
    keeper.cancel()
    return await keeper.value
  }

  private static func keep(_ application: NSRunningApplication) async -> Int {
    var focusLosses = 0
    while !Task.isCancelled {
      if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
        focusLosses += 1
        application.activate()
      }
      try? await Task.sleep(for: pollInterval)
    }
    return focusLosses
  }
}
