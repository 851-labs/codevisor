import ScreenSharing

@MainActor
enum FloorViewer {
  static func run(
    in window: ViewerWindow, port: UInt16, until deadline: ContinuousClock.Instant, signals: BenchSignalFiles
  ) async throws -> FloorViewResult {
    let mailbox = ScreenSharingFrameMailbox()
    mailbox.retainsLatest = true
    window.show(try ScreenSharingVideoSurface(mailbox: mailbox, metrics: ScreenSharingMetrics()))
    let source = try FloorSource(port: port, mailbox: mailbox, pixelSize: window.pixelSize)
    source.start()
    defer { source.stop() }

    try signals.markReady("listening")
    await signals.waitForStop(until: deadline)
    return FloorViewResult(source)
  }
}
